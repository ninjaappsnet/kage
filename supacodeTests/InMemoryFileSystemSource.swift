import ConcurrencyExtras
import Foundation

@testable import supacode

/// A `FileSystemSource` over an in-memory tree, so the explorer, viewer and HTML
/// preview are exercised without touching the disk, the way a remote host will
/// drive them. Every mutation advances a private clock by one second, so each
/// write gets a distinct modification date.
nonisolated final class InMemoryFileSystemSource: FileSystemSource {
  /// One scripted watch step: `before` mutates the tree (or anything else), then
  /// `event` is delivered. Steps are pulled one at a time by the consumer, so a
  /// step only runs once the previous event has been handled.
  struct WatchStep: Sendable {
    let before: @Sendable () async -> Void
    let event: FileSystemChangeEvent
  }

  private struct Node {
    /// `nil` for a directory.
    var data: Data?
    var modificationDate: Date
  }

  private struct State {
    var nodes: [String: Node] = [:]
    var clock = Date(timeIntervalSince1970: 1_000_000)
    var failure: FileSystemSourceError?
    var writeFailure: FileSystemSourceError?
    var watchSteps: [WatchStep] = []
    var watchedDirectorySets: [Set<URL>] = []
    var listedPaths: [String] = []
    var readPaths: [String] = []
    var holdsReads = false
    var heldReads: [CheckedContinuation<Void, Never>] = []
    var holdsWrites = false
    var heldWrites: [CheckedContinuation<Void, Never>] = []
    var gitStatus: GitStatusSnapshot?
  }

  let id: FileSystemSourceID
  let isLocal = false
  private let state = LockIsolated(State())

  init(id: FileSystemSourceID = FileSystemSourceID(rawValue: "in-memory")) {
    self.id = id
  }

  // MARK: - Arranging the tree.

  func addFile(_ path: String, _ contents: String) {
    addFile(path, data: Data(contents.utf8))
  }

  func addFile(_ path: String, data: Data) {
    let key = Self.key(path)
    state.withValue { state in
      Self.ensureParents(of: key, in: &state)
      state.clock += 1
      state.nodes[key] = Node(data: data, modificationDate: state.clock)
    }
  }

  func addDirectory(_ path: String) {
    let key = Self.key(path)
    state.withValue { state in
      Self.ensureParents(of: key, in: &state)
      state.clock += 1
      state.nodes[key] = Node(data: nil, modificationDate: state.clock)
    }
  }

  /// Removes `path` and everything under it.
  func remove(_ path: String) {
    let key = Self.key(path)
    state.withValue { state in
      state.nodes = state.nodes.filter { $0.key != key && !$0.key.hasPrefix(key + "/") }
    }
  }

  /// An external writer changing the file after it was opened.
  func modifyExternally(_ path: String, _ contents: String) {
    addFile(path, contents)
  }

  func contents(of path: String) -> String? {
    state.value.nodes[Self.key(path)]?.data.flatMap { String(bytes: $0, encoding: .utf8) }
  }

  /// Every call fails with `error` until cleared (a dropped link).
  func setFailure(_ error: FileSystemSourceError?) {
    state.withValue { $0.failure = error }
  }

  func setWriteFailure(_ error: FileSystemSourceError?) {
    state.withValue { $0.writeFailure = error }
  }

  func scriptWatch(_ steps: [WatchStep]) {
    state.withValue { $0.watchSteps = steps }
  }

  func setGitStatus(_ snapshot: GitStatusSnapshot?) {
    state.withValue { $0.gitStatus = snapshot }
  }

  /// Parks every read until `releaseReads()`.
  func holdReads() {
    state.withValue { $0.holdsReads = true }
  }

  func releaseReads() {
    let held = state.withValue { state in
      state.holdsReads = false
      defer { state.heldReads.removeAll() }
      return state.heldReads
    }
    for continuation in held { continuation.resume() }
  }

  /// Parks every write, before its conflict check, until `releaseWrites()`.
  func holdWrites() {
    state.withValue { $0.holdsWrites = true }
  }

  func releaseWrites() {
    let held = state.withValue { state in
      state.holdsWrites = false
      defer { state.heldWrites.removeAll() }
      return state.heldWrites
    }
    for continuation in held { continuation.resume() }
  }

  var heldWriteCount: Int { state.value.heldWrites.count }
  var heldReadCount: Int { state.value.heldReads.count }
  var watchedDirectorySets: [Set<URL>] { state.value.watchedDirectorySets }
  var listedPaths: [String] { state.value.listedPaths }
  var readPaths: [String] { state.value.readPaths }

  // MARK: - FileSystemSource.

  func list(_ directory: URL, showsHiddenFiles: Bool) throws(FileSystemSourceError) -> [FileSystemEntry] {
    let key = Self.key(directory.path(percentEncoded: false))
    return try locked { state throws(FileSystemSourceError) in
      if let failure = state.failure { throw failure }
      state.listedPaths.append(key)
      guard let node = state.nodes[key] else { throw .notFound("No such directory: \(key)") }
      guard node.data == nil else { throw .notFound("Not a directory: \(key)") }
      let prefix = key == "/" ? "/" : key + "/"
      return state.nodes.compactMap { path, child -> FileSystemEntry? in
        guard path.hasPrefix(prefix), path != key else { return nil }
        let name = String(path.dropFirst(prefix.count))
        guard !name.contains("/") else { return nil }
        guard showsHiddenFiles || !name.hasPrefix(".") else { return nil }
        return FileSystemEntry(
          name: name,
          kind: child.data == nil ? .directory : .file,
          size: child.data?.count,
          modificationDate: child.modificationDate
        )
      }
    }
  }

  func stat(_ url: URL) throws(FileSystemSourceError) -> FileSystemItemInfo {
    let key = Self.key(url.path(percentEncoded: false))
    return try locked { state throws(FileSystemSourceError) in
      if let failure = state.failure { throw failure }
      guard let node = state.nodes[key] else { throw .notFound("No such file: \(key)") }
      return FileSystemItemInfo(
        kind: node.data == nil ? .directory : .file,
        size: node.data?.count ?? 0,
        modificationDate: node.modificationDate
      )
    }
  }

  func read(_ url: URL, maxBytes: Int) async throws(FileSystemSourceError) -> FileSystemReadResult {
    let key = Self.key(url.path(percentEncoded: false))
    await withCheckedContinuation { continuation in
      let parked = state.withValue { state in
        guard state.holdsReads else { return false }
        state.heldReads.append(continuation)
        return true
      }
      if !parked { continuation.resume() }
    }
    return try locked { state throws(FileSystemSourceError) in
      if let failure = state.failure { throw failure }
      guard let node = state.nodes[key], let data = node.data else { throw .notFound("No such file: \(key)") }
      guard data.count <= maxBytes else { throw .tooLarge(size: data.count) }
      state.readPaths.append(key)
      return FileSystemReadResult(data: data, size: data.count, modificationDate: node.modificationDate)
    }
  }

  @discardableResult
  func write(
    _ data: Data,
    to url: URL,
    expectedModificationDate: Date?
  ) async throws(FileSystemSourceError) -> Date? {
    let key = Self.key(url.path(percentEncoded: false))
    await withCheckedContinuation { continuation in
      let parked = state.withValue { state in
        guard state.holdsWrites else { return false }
        state.heldWrites.append(continuation)
        return true
      }
      if !parked { continuation.resume() }
    }
    return try locked { state throws(FileSystemSourceError) in
      if let failure = state.failure ?? state.writeFailure { throw failure }
      if let expectedModificationDate {
        guard let current = state.nodes[key]?.modificationDate else {
          throw .conflict(currentModificationDate: nil)
        }
        guard current <= expectedModificationDate else { throw .conflict(currentModificationDate: current) }
      }
      Self.ensureParents(of: key, in: &state)
      state.clock += 1
      state.nodes[key] = Node(data: data, modificationDate: state.clock)
      return state.clock
    }
  }

  func watch(root: URL) -> FileSystemWatch {
    let state = self.state
    let steps = LockIsolated(state.value.watchSteps)
    let events = AsyncStream<FileSystemChangeEvent> {
      guard let step = steps.withValue({ $0.isEmpty ? nil : $0.removeFirst() }) else { return nil }
      await step.before()
      return step.event
    }
    return FileSystemWatch(
      events: events,
      setWatchedDirectories: { directories in
        state.withValue { $0.watchedDirectorySets.append(directories) }
      }
    )
  }

  func gitStatus(root: URL) throws(FileSystemSourceError) -> GitStatusSnapshot {
    let result = state.value
    if let failure = result.failure { throw failure }
    guard let snapshot = result.gitStatus else { throw .notGit("Not a git repository") }
    return snapshot
  }

  // MARK: - Helpers.

  /// `LockIsolated.withValue` rethrows untyped errors; this keeps the source's
  /// typed throws.
  private func locked<T: Sendable>(
    _ body: @Sendable (inout State) throws(FileSystemSourceError) -> T
  ) throws(FileSystemSourceError) -> T {
    let result: Result<T, FileSystemSourceError> = state.withValue { state in
      do throws(FileSystemSourceError) {
        return .success(try body(&state))
      } catch {
        return .failure(error)
      }
    }
    return try result.get()
  }

  private static func key(_ path: String) -> String {
    var standardized = URL(filePath: path).standardizedFileURL.path(percentEncoded: false)
    while standardized.count > 1, standardized.hasSuffix("/") { standardized.removeLast() }
    return standardized
  }

  private static func parentKey(of key: String) -> String? {
    guard key != "/", let slash = key.lastIndex(of: "/") else { return nil }
    return slash == key.startIndex ? "/" : String(key[..<slash])
  }

  private static func ensureParents(of key: String, in state: inout State) {
    var parent = parentKey(of: key)
    while let current = parent {
      if state.nodes[current] == nil {
        state.nodes[current] = Node(data: nil, modificationDate: state.clock)
      }
      parent = parentKey(of: current)
    }
  }
}
