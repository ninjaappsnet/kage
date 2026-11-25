import Foundation

/// Turns a persisted `FileSystemSourceID` back into a live source. A viewer tab
/// stores only its source's id (`FileViewerContentState.sourceID`), and the
/// layout's content factory rebuilds the tab from that state, so a remote source
/// must be registered here (phase E does it when a host's serve session opens)
/// before a tab naming it can read anything.
@MainActor
enum FileSystemSources {
  private static var registered: [FileSystemSourceID: any FileSystemSource] = [:]

  static func register(_ source: any FileSystemSource) {
    guard !source.isLocal else { return }
    registered[source.id] = source
  }

  static func unregister(_ id: FileSystemSourceID) {
    registered[id] = nil
  }

  /// The local disk for `.local`, the registered source for anything else, and
  /// for an id nobody registered a source that fails every call as a dropped
  /// link: a remote path must never silently resolve against this Mac's disk.
  static func source(for id: FileSystemSourceID) -> any FileSystemSource {
    if id == .local { return LocalFileSystemSource() }
    return registered[id] ?? UnavailableFileSystemSource(id: id)
  }
}

/// Stand-in for a source that is not connected this session. Every call fails
/// with `.connection`, which the viewer shows as a message.
nonisolated struct UnavailableFileSystemSource: FileSystemSource {
  let id: FileSystemSourceID
  var isLocal: Bool { false }

  private var failure: FileSystemSourceError {
    .connection("Not connected to \(id.rawValue).")
  }

  func list(_ directory: URL, showsHiddenFiles: Bool) throws(FileSystemSourceError) -> [FileSystemEntry] {
    throw failure
  }

  func stat(_ url: URL) throws(FileSystemSourceError) -> FileSystemItemInfo {
    throw failure
  }

  func read(_ url: URL, maxBytes: Int) throws(FileSystemSourceError) -> FileSystemReadResult {
    throw failure
  }

  @discardableResult
  func write(
    _ data: Data,
    to url: URL,
    expectedModificationDate: Date?
  ) throws(FileSystemSourceError) -> Date? {
    throw failure
  }

  func watch(root: URL) -> FileSystemWatch {
    FileSystemWatch(events: AsyncStream { $0.finish() }, setWatchedDirectories: { _ in })
  }

  func gitStatus(root: URL) throws(FileSystemSourceError) -> GitStatusSnapshot {
    throw failure
  }
}
