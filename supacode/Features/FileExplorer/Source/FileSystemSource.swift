import Foundation

/// Where the file explorer, the file viewer and the HTML preview read and write
/// files: this Mac's disk (`LocalFileSystemSource`) or, later, a remote Kage host
/// speaking protocol v1 of `kage host serve` (see
/// `docs/plans/remote-files-and-sidebar-groups.md`). The operations map 1:1 onto
/// that protocol's `list` / `stat` / `read` / `write` / `watch` / `gitStatus`.
///
/// Paths: every `URL` passed to or returned from a source is a `file:` URL used
/// purely as a carrier for an absolute POSIX path (`path(percentEncoded: false)`).
/// It may name a file on another machine, so nothing outside a local source may
/// dereference it: no `FileManager`, `Data(contentsOf:)`, `NSWorkspace` or
/// `NSImage(contentsOf:)`. Conveniences that only make sense on this Mac
/// (Reveal in Finder, Open in Default App) gate on `isLocal`.
///
/// Every call is async and may fail. A remote source fails with
/// `FileSystemSourceError.Code.connection` when its link is down; the UI words that
/// as a message instead of treating it as an empty folder or a missing file.
nonisolated protocol FileSystemSource: Sendable {
  /// Identifies the source across a relaunch, so a persisted viewer tab reopens
  /// against the same machine (`FileViewerContentState.sourceID`).
  var id: FileSystemSourceID { get }

  /// True only for this Mac's disk: the one source whose paths Finder and the
  /// default apps can open.
  var isLocal: Bool { get }

  /// The entries of `directory`, non-recursive and unsorted (the caller sorts).
  func list(_ directory: URL, showsHiddenFiles: Bool) async throws(FileSystemSourceError) -> [FileSystemEntry]

  /// What is at `url` right now. Never cached: the viewer's conflict check
  /// depends on a fresh modification date.
  func stat(_ url: URL) async throws(FileSystemSourceError) -> FileSystemItemInfo

  /// The bytes of `url`, refused with `.tooLarge` (carrying the size) above
  /// `maxBytes` without reading the file.
  func read(_ url: URL, maxBytes: Int) async throws(FileSystemSourceError) -> FileSystemReadResult

  /// Replaces `url` with `data`, keeping a symlink at `url` intact. With an
  /// `expectedModificationDate` the write is refused with `.conflict` when the
  /// file changed since then, or no longer exists; `nil` writes unconditionally.
  /// Returns the file's new modification date when the source can tell.
  @discardableResult
  func write(
    _ data: Data,
    to url: URL,
    expectedModificationDate: Date?
  ) async throws(FileSystemSourceError) -> Date?

  /// Starts following changes under `root`. The stream ends when its consumer
  /// is cancelled, which also releases whatever the source holds for it.
  func watch(root: URL) -> FileSystemWatch

  /// The uncommitted git state of the worktree at `root`; `.notGit` when it is
  /// not inside a repository.
  func gitStatus(root: URL) async throws(FileSystemSourceError) -> GitStatusSnapshot
}

/// A source that can also write without suspending. Only this Mac's disk can
/// promise it, and it is what keeps the close confirmation's "Save" synchronous
/// (`TabContent.saveUnsavedWork()` must answer before the close proceeds).
nonisolated protocol ImmediateFileSystemWriting: FileSystemSource {
  @discardableResult
  func writeImmediately(
    _ data: Data,
    to url: URL,
    expectedModificationDate: Date?
  ) throws(FileSystemSourceError) -> Date?
}

/// Stable identity of a source. `local` is this Mac; a remote source names its
/// host (phase E registers those with `FileSystemSources`).
nonisolated struct FileSystemSourceID: Hashable, Codable, Sendable, CustomStringConvertible {
  let rawValue: String

  static let local = FileSystemSourceID(rawValue: "local")

  init(rawValue: String) {
    self.rawValue = rawValue
  }

  init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  var description: String { rawValue }
}

/// One entry of a listed directory, mirroring protocol v1's `list` entries.
nonisolated struct FileSystemEntry: Equatable, Sendable {
  enum Kind: String, Equatable, Sendable {
    case file
    case directory
    case symlink
  }

  let name: String
  let kind: Kind
  /// Byte size when the source reports it.
  var size: Int?
  var modificationDate: Date?
  /// What a `.symlink` points at, when it resolves.
  var symlinkTargetKind: Kind?
}

/// The result of `stat`, mirroring protocol v1's `stat`.
nonisolated struct FileSystemItemInfo: Equatable, Sendable {
  let kind: FileSystemEntry.Kind
  let size: Int
  let modificationDate: Date?
}

/// The result of `read`, mirroring protocol v1's `read`.
nonisolated struct FileSystemReadResult: Equatable, Sendable {
  let data: Data
  let size: Int
  /// Taken before the bytes were read, so a change landing mid-read still
  /// registers as a conflict on the next save.
  let modificationDate: Date?
}

/// Change notifications, mirroring protocol v1's events.
nonisolated enum FileSystemChangeEvent: Equatable, Sendable {
  /// The listings of these watched directories changed.
  case changed(directories: Set<URL>)
  /// Something under the watched root changed (drives a git status refresh).
  case treeChanged(root: URL)
  /// Events were dropped; re-list everything under this path.
  case rescan(URL)
}

/// One live `watch`: the event stream plus the way to tell the source which
/// directories the consumer holds listings for (protocol v1's `watch` op, which
/// replaces the set). A local source watches the whole tree and ignores the set.
nonisolated struct FileSystemWatch: Sendable {
  let events: AsyncStream<FileSystemChangeEvent>
  let setWatchedDirectories: @Sendable (Set<URL>) -> Void
}

/// A failed source call. Shaped like protocol v1's error object
/// (`{code, message, size?, mtime?}`) so a remote source maps it 1:1, plus
/// `connection` for a link that is down. `message` is what the UI shows; a local
/// source carries the underlying Cocoa error's own wording.
nonisolated struct FileSystemSourceError: Error, Equatable, Sendable, LocalizedError {
  enum Code: String, Equatable, Sendable {
    case notFound
    case permission
    case tooLarge
    case conflict
    case notGit
    case badRequest
    case ioFailure = "io"
    case connection
  }

  let code: Code
  let message: String
  /// `tooLarge`: the file's size.
  var size: Int?
  /// `conflict`: the file's current modification date (`nil` once it is gone).
  var modificationDate: Date?

  var errorDescription: String? { message }

  static func notFound(_ message: String) -> Self { Self(code: .notFound, message: message) }
  static func permission(_ message: String) -> Self { Self(code: .permission, message: message) }
  static func ioFailure(_ message: String) -> Self { Self(code: .ioFailure, message: message) }
  static func connection(_ message: String) -> Self { Self(code: .connection, message: message) }
  static func notGit(_ message: String) -> Self { Self(code: .notGit, message: message) }

  static func tooLarge(size: Int) -> Self {
    Self(code: .tooLarge, message: "File is too large (\(size) bytes)", size: size)
  }

  static func conflict(currentModificationDate: Date?) -> Self {
    Self(
      code: .conflict,
      message: "The file changed on disk since it was opened.",
      modificationDate: currentModificationDate
    )
  }
}
