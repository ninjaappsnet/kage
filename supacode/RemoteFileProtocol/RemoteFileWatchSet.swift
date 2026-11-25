import Darwin
import Foundation

/// One FSEvents directory-level event, free of CoreServices types so the
/// classification is testable without a stream.
nonisolated struct RemoteFileFSEvent: Equatable, Sendable {
  nonisolated struct Flags: OptionSet, Hashable, Sendable {
    let rawValue: UInt32

    static let mustScanSubDirs = Flags(rawValue: 1 << 0)
    static let userDropped = Flags(rawValue: 1 << 1)
    static let kernelDropped = Flags(rawValue: 1 << 2)
    static let eventIDsWrapped = Flags(rawValue: 1 << 3)
    static let historyDone = Flags(rawValue: 1 << 4)
    static let rootChanged = Flags(rawValue: 1 << 5)
    static let unmount = Flags(rawValue: 1 << 6)

    /// FSEvents lost events somewhere: everything watched may be stale.
    static let dropped: Flags = [.userDropped, .kernelDropped, .eventIDsWrapped]
  }

  var path: String
  var flags: Flags
  var id: UInt64
}

/// One path of a `watch` request, as the viewer spelled it and as FSEvents
/// reports it (`realpath`: `/tmp` is `/private/tmp`, symlinks resolved).
nonisolated struct RemoteFileWatchEntry: Equatable, Sendable {
  var requested: String
  var canonical: String
  var isDirectory: Bool
  /// The repository's git directory when this directory is a checkout root:
  /// `.git` itself, or where a linked worktree's `.git` file points.
  var gitDirectory: String?

  /// Resolves `path` on disk; `nil` when it does not exist.
  static func resolve(_ path: String) -> RemoteFileWatchEntry? {
    guard path.hasPrefix("/") else { return nil }
    let requested = RemoteFilePOSIX.normalized(path)
    guard let canonical = RemoteFilePOSIX.realPath(requested) else { return nil }
    var info = stat()
    guard stat(canonical, &info) == 0 else { return nil }
    let isDirectory = info.st_mode & S_IFMT == S_IFDIR
    return RemoteFileWatchEntry(
      requested: requested,
      canonical: canonical,
      isDirectory: isDirectory,
      gitDirectory: isDirectory ? gitDirectory(in: canonical) : nil
    )
  }

  private static func gitDirectory(in directory: String) -> String? {
    let dotGit = directory + "/.git"
    var info = stat()
    guard stat(dotGit, &info) == 0 else { return nil }
    if info.st_mode & S_IFMT == S_IFDIR { return RemoteFilePOSIX.realPath(dotGit) }
    // A linked worktree (or submodule): `gitdir: <path>`, maybe relative.
    guard info.st_mode & S_IFMT == S_IFREG, info.st_size < 4096,
      let contents = FileManager.default.contents(atPath: dotGit),
      let line = String(bytes: contents, encoding: .utf8)?.split(whereSeparator: \.isNewline).first,
      line.hasPrefix("gitdir:")
    else { return nil }
    let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
    return RemoteFilePOSIX.realPath(target.hasPrefix("/") ? target : directory + "/" + target)
  }
}

/// What a batch of events means for the viewer. `gitDirectories` are git
/// directories that saw an event; the watcher checks their HEAD and index.
nonisolated struct RemoteFileEventClassification: Equatable, Sendable {
  var changed: Set<String> = []
  var treeRoots: Set<String> = []
  var rescans: Set<String> = []
  var gitDirectories: Set<String> = []

  var isEmpty: Bool { changed.isEmpty && treeRoots.isEmpty && rescans.isEmpty && gitDirectories.isEmpty }

  mutating func formUnion(_ other: Self) {
    changed.formUnion(other.changed)
    treeRoots.formUnion(other.treeRoots)
    rescans.formUnion(other.rescans)
    gitDirectories.formUnion(other.gitDirectories)
  }
}

/// The current `watch` set and the pure mapping from FSEvents directory events
/// to protocol events. A root is a watched path with no watched directory above
/// it; one FSEvents stream covers the roots (a watched file is covered through
/// its folder) plus linked worktrees' git directories.
nonisolated struct RemoteFileWatchSet: Equatable, Sendable {
  let entries: [RemoteFileWatchEntry]
  /// Requested spellings of the roots, sorted.
  let roots: [String]
  /// Canonical paths the stream must cover, sorted and without nesting.
  let streamPaths: [String]
  /// Canonical git directories of the root checkouts, sorted.
  let gitDirectories: [String]

  private let rootEntries: [RemoteFileWatchEntry]
  private let directoriesByCanonical: [String: [String]]
  private let filesByParent: [String: [String]]
  private let rootsByGitDirectory: [String: [String]]

  init(entries: [RemoteFileWatchEntry]) {
    var seen: Set<String> = []
    let entries = entries.filter { seen.insert($0.requested).inserted }
    let directories = entries.filter(\.isDirectory)
    let rootEntries = entries.filter { entry in
      !directories.contains { $0.requested != entry.requested && entry.canonical.hasPrefix($0.canonical + "/") }
    }
    self.entries = entries
    self.rootEntries = rootEntries
    roots = rootEntries.map(\.requested).sorted()
    directoriesByCanonical = Dictionary(grouping: directories, by: \.canonical).mapValues { $0.map(\.requested) }
    filesByParent = Dictionary(grouping: entries.filter { !$0.isDirectory }) {
      RemoteFilePOSIX.parent(of: $0.canonical)
    }
    .mapValues { $0.map(\.requested) }
    var rootsByGitDirectory: [String: [String]] = [:]
    for entry in rootEntries {
      guard let gitDirectory = entry.gitDirectory else { continue }
      rootsByGitDirectory[gitDirectory, default: []].append(entry.requested)
    }
    self.rootsByGitDirectory = rootsByGitDirectory
    gitDirectories = rootsByGitDirectory.keys.sorted()
    let candidates = Set(rootEntries.map(Self.coveredDirectory) + gitDirectories)
    streamPaths = candidates.filter { path in
      !candidates.contains { $0 != path && ($0 == "/" || path.hasPrefix($0 + "/")) }
    }.sorted()
  }

  func roots(forGitDirectory gitDirectory: String) -> [String] {
    rootsByGitDirectory[gitDirectory] ?? []
  }

  func classify(_ events: [RemoteFileFSEvent]) -> RemoteFileEventClassification {
    var result = RemoteFileEventClassification()
    for event in events {
      result.formUnion(classify(event))
    }
    return result
  }

  private func classify(_ event: RemoteFileFSEvent) -> RemoteFileEventClassification {
    var result = RemoteFileEventClassification()
    let path = RemoteFilePOSIX.normalized(event.path)
    if event.flags.contains(.historyDone) { return result }
    if !event.flags.isDisjoint(with: .dropped) {
      result.rescans = Set(roots)
      return result
    }
    if !event.flags.isDisjoint(with: [.rootChanged, .unmount]) {
      let affected = rootEntries.filter { entry in
        let covered = Self.coveredDirectory(entry)
        return covered == path || covered.hasPrefix(path + "/") || path.hasPrefix(covered + "/")
      }
      result.rescans = Set((affected.isEmpty ? rootEntries : affected).map(\.requested))
      return result
    }
    if rootsByGitDirectory[path] != nil {
      result.gitDirectories = [path]
      return result
    }
    // Objects, refs, logs, lock files: git status reads HEAD and index only.
    if path.hasSuffix("/.git") || path.contains("/.git/") { return result }

    let containing = rootEntries.filter { entry in
      entry.isDirectory
        ? path == entry.canonical || path.hasPrefix(entry.canonical + "/")
        : path == RemoteFilePOSIX.parent(of: entry.canonical)
    }
    if event.flags.contains(.mustScanSubDirs) {
      for entry in containing {
        result.rescans.insert(
          entry.isDirectory ? entry.requested + path.dropFirst(entry.canonical.count) : entry.requested)
      }
    }
    result.changed.formUnion(directoriesByCanonical[path] ?? [])
    result.changed.formUnion(filesByParent[path] ?? [])
    result.treeRoots.formUnion(containing.map(\.requested))
    return result
  }

  /// The directory whose subtree a root needs: itself, or a watched file's folder.
  private static func coveredDirectory(_ entry: RemoteFileWatchEntry) -> String {
    entry.isDirectory ? entry.canonical : RemoteFilePOSIX.parent(of: entry.canonical)
  }
}
