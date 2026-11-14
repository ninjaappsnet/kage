import Foundation

/// Builds and repairs a non-main account's config directory so everything except
/// the login is shared with `~/.claude`.
///
/// Each shared entry in the account directory is a symlink to the same name in the
/// hub. What stays private is everything Claude Code keys to the account:
/// `.claude.json` (identity, per-project trust, user MCP servers — those are copied
/// by `ClaudeMCPServerSync` instead), the Keychain login, and `sessions/`.
///
/// Repair never deletes. A real file or directory found where a link belongs is
/// adopted into the hub when the hub has none, merged into it entry by entry when
/// both are directories, and otherwise moved aside under `.kage-unlinked/`.
nonisolated struct ClaudeAccountLayout: Sendable {
  enum EntryKind: Equatable, Sendable {
    case directory
    case file
  }

  struct SharedEntry: Equatable, Sendable {
    var name: String
    var kind: EntryKind
  }

  /// Shared with the hub. Directories are created in the hub when missing so a link
  /// never dangles into a path Claude Code would `mkdir` through; files are left to
  /// be created on first write, which a dangling link tolerates.
  static let sharedEntries: [SharedEntry] = [
    SharedEntry(name: "projects", kind: .directory),
    SharedEntry(name: "skills", kind: .directory),
    SharedEntry(name: "agents", kind: .directory),
    SharedEntry(name: "commands", kind: .directory),
    SharedEntry(name: "output-styles", kind: .directory),
    SharedEntry(name: "plugins", kind: .directory),
    SharedEntry(name: "settings.json", kind: .file),
    SharedEntry(name: "CLAUDE.md", kind: .file),
    SharedEntry(name: "history.jsonl", kind: .file),
    SharedEntry(name: "keybindings.json", kind: .file),
  ]

  static let unlinkedDirectoryName = ".kage-unlinked"

  struct Report: Equatable, Sendable {
    /// Entries that were missing or wrong and are now linked.
    var linked: [String] = []
    /// Real items moved aside because the hub already had its own copy.
    var movedAside: [String] = []

    var changedAnything: Bool { !linked.isEmpty || !movedAside.isEmpty }
  }

  let hubDirectory: URL
  let now: @Sendable () -> Date

  init(hubDirectory: URL = ClaudeAccount.hubDirectory(), now: @escaping @Sendable () -> Date = { Date() }) {
    self.hubDirectory = hubDirectory
    self.now = now
  }

  /// Creates `accountDirectory` if needed and makes every shared entry a link into
  /// the hub. Safe to run repeatedly; a correct layout is left untouched.
  @discardableResult
  func prepare(accountDirectory: URL) throws -> Report {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: hubDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
    var report = Report()
    for entry in Self.sharedEntries {
      try link(entry, in: accountDirectory, report: &report)
    }
    return report
  }

  /// Whether every shared entry is already a link to the right hub path.
  func isPrepared(accountDirectory: URL) -> Bool {
    Self.sharedEntries.allSatisfy { entry in
      let linkURL = accountDirectory.appending(path: entry.name)
      return Self.symlinkDestination(of: linkURL) == hubURL(for: entry).path(percentEncoded: false)
    }
  }

  private func hubURL(for entry: SharedEntry) -> URL {
    hubDirectory.appending(path: entry.name, directoryHint: entry.kind == .directory ? .isDirectory : .notDirectory)
  }

  private func link(_ entry: SharedEntry, in accountDirectory: URL, report: inout Report) throws {
    let fileManager = FileManager.default
    let target = hubURL(for: entry)
    let targetPath = target.path(percentEncoded: false)
    let linkURL = accountDirectory.appending(path: entry.name, directoryHint: .notDirectory)

    if entry.kind == .directory, !fileManager.fileExists(atPath: targetPath) {
      try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
    }

    if let destination = Self.symlinkDestination(of: linkURL) {
      if destination == targetPath { return }
      // A link pointing anywhere else carries no data of its own.
      try fileManager.removeItem(at: linkURL)
    } else if Self.itemExists(at: linkURL) {
      try absorb(linkURL, into: target, entry: entry, accountDirectory: accountDirectory, report: &report)
    }

    try fileManager.createSymbolicLink(atPath: linkURL.path(percentEncoded: false), withDestinationPath: targetPath)
    report.linked.append(entry.name)
  }

  /// Moves a real item out of the way of its link without losing anything.
  private func absorb(
    _ item: URL,
    into target: URL,
    entry: SharedEntry,
    accountDirectory: URL,
    report: inout Report
  ) throws {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    let itemIsDirectory =
      fileManager.fileExists(atPath: item.path(percentEncoded: false), isDirectory: &isDirectory)
      && isDirectory.boolValue

    if !Self.itemExists(at: target) || Self.isEmptyFile(target) {
      if Self.itemExists(at: target) { try fileManager.removeItem(at: target) }
      try fileManager.moveItem(at: item, to: target)
      return
    }

    if itemIsDirectory, entry.kind == .directory {
      // Merge child by child; only true collisions are set aside.
      let children = (try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
      var collisions = false
      for child in children {
        let destination = target.appending(path: child.lastPathComponent)
        if Self.itemExists(at: destination) {
          collisions = true
        } else {
          try fileManager.moveItem(at: child, to: destination)
        }
      }
      if !collisions {
        try fileManager.removeItem(at: item)
        return
      }
    } else if !itemIsDirectory, Self.isEmptyFile(item) {
      try fileManager.removeItem(at: item)
      return
    }

    let aside = try moveAsideDirectory(in: accountDirectory)
    try fileManager.moveItem(at: item, to: aside.appending(path: entry.name))
    report.movedAside.append(entry.name)
  }

  private func moveAsideDirectory(in accountDirectory: URL) throws -> URL {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
    let stamp = formatter.string(from: now()).replacing(":", with: "-")
    let directory =
      accountDirectory
      .appending(path: Self.unlinkedDirectoryName, directoryHint: .isDirectory)
      .appending(path: stamp, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// The raw destination of a symlink, or `nil` when `url` is not one.
  static func symlinkDestination(of url: URL) -> String? {
    try? FileManager.default.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false))
  }

  /// True for anything at the path, including a dangling symlink.
  static func itemExists(at url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
  }

  private static func isEmptyFile(_ url: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
      attributes[.type] as? FileAttributeType == .typeRegular
    else { return false }
    return (attributes[.size] as? NSNumber)?.intValue == 0
  }
}
