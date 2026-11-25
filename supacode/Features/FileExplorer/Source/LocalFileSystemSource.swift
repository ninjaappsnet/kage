import Foundation
import SupacodeSettingsShared

/// This Mac's disk behind the `FileSystemSource` seam: `FileManager` for
/// listing and reading, `SymlinkPreservingFileWriter` for saving,
/// `FileSystemEventWatcher` (FSEvents) for changes and `GitClient` for status.
/// The work runs off the main actor (`@concurrent`); the results are exactly what
/// the explorer and viewer computed when they touched the disk themselves.
nonisolated struct LocalFileSystemSource: ImmediateFileSystemWriting {
  let id = FileSystemSourceID.local
  var isLocal: Bool { true }

  private let gitStatusProvider: @Sendable (URL) async -> GitStatusSnapshot?

  /// `gitStatus` is injectable so tests need not spawn git; `nil` from it means
  /// the probe failed, which almost always means "not a repository".
  init(gitStatus: @escaping @Sendable (URL) async -> GitStatusSnapshot? = { await GitClient().fileStatus(at: $0) }) {
    gitStatusProvider = gitStatus
  }

  @concurrent
  func list(_ directory: URL, showsHiddenFiles: Bool) async throws(FileSystemSourceError) -> [FileSystemEntry] {
    try Self.listNow(directory, showsHiddenFiles: showsHiddenFiles)
  }

  @concurrent
  func stat(_ url: URL) async throws(FileSystemSourceError) -> FileSystemItemInfo {
    try Self.statNow(url)
  }

  @concurrent
  func read(_ url: URL, maxBytes: Int) async throws(FileSystemSourceError) -> FileSystemReadResult {
    // Stat first, as the viewer always did: the size cap is enforced without
    // reading the file, and the modification date predates the bytes.
    let info = try Self.statNow(url)
    guard info.size <= maxBytes else {
      var error = FileSystemSourceError.tooLarge(size: info.size)
      error.modificationDate = info.modificationDate
      throw error
    }
    do {
      let data = try Data(contentsOf: url)
      return FileSystemReadResult(data: data, size: data.count, modificationDate: info.modificationDate)
    } catch {
      throw Self.sourceError(error)
    }
  }

  @discardableResult
  @concurrent
  func write(
    _ data: Data,
    to url: URL,
    expectedModificationDate: Date?
  ) async throws(FileSystemSourceError) -> Date? {
    try writeImmediately(data, to: url, expectedModificationDate: expectedModificationDate)
  }

  /// The conflict rule the viewer has always applied: the file is stale when its
  /// modification date moved past the one it was opened with, or when it is gone
  /// (deleted or moved out from under the buffer).
  @discardableResult
  func writeImmediately(
    _ data: Data,
    to url: URL,
    expectedModificationDate: Date?
  ) throws(FileSystemSourceError) -> Date? {
    if let expectedModificationDate {
      let current = Self.modificationDate(of: url)
      guard let current, current <= expectedModificationDate else {
        throw .conflict(currentModificationDate: current)
      }
    }
    do {
      try SymlinkPreservingFileWriter.write(data, to: url)
    } catch {
      throw Self.sourceError(error)
    }
    return Self.modificationDate(of: url)
  }

  /// Whole-tree FSEvents on `root`. Every batch is reported as a rescan of the
  /// root plus a tree change, which is exactly the full re-list the explorer did
  /// on every FSEvents callback before the seam existed; the watched-directory
  /// set is ignored because the stream already covers the tree.
  func watch(root: URL) -> FileSystemWatch {
    let root = root.standardizedFileURL
    let (events, continuation) = AsyncStream.makeStream(of: FileSystemChangeEvent.self)
    let watcher = FileSystemEventWatcher(url: root) {
      continuation.yield(.rescan(root))
      continuation.yield(.treeChanged(root: root))
    }
    if watcher == nil {
      // FSEvents could not start (the path is gone): degrade to manual refresh,
      // as before.
      continuation.finish()
    }
    continuation.onTermination = { _ in
      // Holding the watcher here ties the FSEvents stream's lifetime to the
      // consumer's; releasing it stops and invalidates the stream.
      withExtendedLifetime(watcher) {}
    }
    return FileSystemWatch(events: events, setWatchedDirectories: { _ in })
  }

  func gitStatus(root: URL) async throws(FileSystemSourceError) -> GitStatusSnapshot {
    guard let snapshot = await gitStatusProvider(root) else {
      throw .notGit("Not a git repository: \(root.path(percentEncoded: false))")
    }
    return snapshot
  }

  // MARK: - Disk access.

  private static func listNow(_ directory: URL, showsHiddenFiles: Bool) throws(FileSystemSourceError)
    -> [FileSystemEntry]
  {
    let options: FileManager.DirectoryEnumerationOptions = showsHiddenFiles ? [] : [.skipsHiddenFiles]
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
    let childURLs: [URL]
    do {
      childURLs = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: keys,
        options: options,
      )
    } catch {
      throw sourceError(error)
    }
    return childURLs.map { childURL in
      let values = try? childURL.resourceValues(forKeys: Set(keys))
      let kind: FileSystemEntry.Kind =
        if values?.isSymbolicLink == true {
          .symlink
        } else if values?.isDirectory == true {
          .directory
        } else {
          .file
        }
      return FileSystemEntry(
        name: childURL.lastPathComponent,
        kind: kind,
        size: values?.fileSize,
        modificationDate: values?.contentModificationDate,
        symlinkTargetKind: kind == .symlink ? symlinkTargetKind(of: childURL) : nil
      )
    }
  }

  private static func symlinkTargetKind(of url: URL) -> FileSystemEntry.Kind? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
      return nil
    }
    return isDirectory.boolValue ? .directory : .file
  }

  private static func statNow(_ url: URL) throws(FileSystemSourceError) -> FileSystemItemInfo {
    // FileManager rather than `URL.resourceValues`: a URL caches its resource
    // values, which would mask a later external change to the same stored URL.
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    } catch {
      throw sourceError(error)
    }
    let kind: FileSystemEntry.Kind =
      switch attributes[.type] as? FileAttributeType {
      case .typeDirectory: .directory
      case .typeSymbolicLink: .symlink
      default: .file
      }
    return FileSystemItemInfo(
      kind: kind,
      size: (attributes[.size] as? Int) ?? 0,
      modificationDate: attributes[.modificationDate] as? Date
    )
  }

  private static func modificationDate(of url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
  }

  /// Narrows a Cocoa / POSIX error to the protocol's codes, keeping the system's
  /// own wording as the message so what the viewer shows is unchanged.
  private static func sourceError(_ error: any Error) -> FileSystemSourceError {
    let message = error.localizedDescription
    let nsError = error as NSError
    switch (nsError.domain, nsError.code) {
    case (NSCocoaErrorDomain, NSFileNoSuchFileError), (NSCocoaErrorDomain, NSFileReadNoSuchFileError),
      (NSPOSIXErrorDomain, Int(ENOENT)), (NSPOSIXErrorDomain, Int(ENOTDIR)):
      return .notFound(message)
    case (NSCocoaErrorDomain, NSFileReadNoPermissionError), (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
      (NSPOSIXErrorDomain, Int(EACCES)), (NSPOSIXErrorDomain, Int(EPERM)):
      return .permission(message)
    default:
      if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
        underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOTDIR)
      {
        return .notFound(message)
      }
      return .ioFailure(message)
    }
  }
}
