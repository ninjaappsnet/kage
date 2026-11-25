import Foundation

/// A remote Kage host's disk behind the `FileSystemSource` seam, spoken over
/// that host's `RemoteKageServeSession` (protocol v1 of `kage host serve`).
/// Paths travel as absolute POSIX strings, times as milliseconds, bytes as
/// base64; errors map 1:1 onto `FileSystemSourceError`, and a channel that is
/// not usable (old host, link down) reads as `.connection` with the reason.
nonisolated struct RemoteFileSystemSource: FileSystemSource {
  let id: FileSystemSourceID
  let session: RemoteKageServeSession
  var isLocal: Bool { false }

  init(hostID: UUID, session: RemoteKageServeSession) {
    id = Self.sourceID(hostID: hostID)
    self.session = session
  }

  /// Stable per host, so a viewer naming it resolves through `FileSystemSources`.
  static func sourceID(hostID: UUID) -> FileSystemSourceID {
    FileSystemSourceID(rawValue: "remote-kage:\(hostID.uuidString)")
  }

  func list(_ directory: URL, showsHiddenFiles: Bool) async throws(FileSystemSourceError) -> [FileSystemEntry] {
    let path = Self.path(directory)
    let result = try await perform(RemoteFileListResult.self) {
      .list(id: $0, path: path, showHidden: showsHiddenFiles)
    }
    return result.entries.map { entry in
      FileSystemEntry(
        name: entry.name,
        kind: Self.kind(entry.kind),
        size: Int(entry.size),
        modificationDate: Self.date(milliseconds: entry.mtime),
        symlinkTargetKind: entry.kind == .symlink ? entry.targetKind.map(Self.kind) : nil
      )
    }
  }

  func stat(_ url: URL) async throws(FileSystemSourceError) -> FileSystemItemInfo {
    let path = Self.path(url)
    let result = try await perform(RemoteFileStatResult.self) { .stat(id: $0, path: path) }
    return FileSystemItemInfo(
      kind: Self.kind(result.kind),
      size: Int(result.size),
      modificationDate: Self.date(milliseconds: result.mtime)
    )
  }

  func read(_ url: URL, maxBytes: Int) async throws(FileSystemSourceError) -> FileSystemReadResult {
    let path = Self.path(url)
    let result = try await perform(RemoteFileReadResult.self) {
      .read(id: $0, path: path, maxBytes: Int64(maxBytes))
    }
    return FileSystemReadResult(
      data: result.data,
      size: Int(result.size),
      modificationDate: Self.date(milliseconds: result.mtime)
    )
  }

  /// The host refuses the write unless the file's modification time is still
  /// exactly the one this buffer was opened (or last saved) with.
  @discardableResult
  func write(
    _ data: Data,
    to url: URL,
    expectedModificationDate: Date?
  ) async throws(FileSystemSourceError) -> Date? {
    let path = Self.path(url)
    let expected = expectedModificationDate.map(Self.milliseconds)
    let result = try await perform(RemoteFileWriteResult.self) {
      .write(id: $0, path: path, data: data, expectedMtime: expected)
    }
    return Self.date(milliseconds: result.mtime)
  }

  /// Subscribes to the host's events for as long as the returned stream is
  /// consumed. The watched-directory set is forwarded latest-first: the host's
  /// `watch` replaces its set, so only the newest one matters.
  func watch(root: URL) -> FileSystemWatch {
    let session = session
    let token = UUID()
    let (events, eventContinuation) = AsyncStream.makeStream(of: FileSystemChangeEvent.self)
    let (sets, setContinuation) = AsyncStream.makeStream(
      of: Set<String>.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    let pump = Task {
      let remoteEvents = await session.subscribe(token)
      let forward = Task {
        for await event in remoteEvents {
          eventContinuation.yield(Self.changeEvent(event))
        }
        eventContinuation.finish()
      }
      for await paths in sets {
        await session.setWatchedPaths(paths, for: token)
      }
      forward.cancel()
      await session.unsubscribe(token)
    }
    // The consumer going away ends the set stream, which ends the pump and
    // unsubscribes (releasing the session).
    eventContinuation.onTermination = { _ in
      setContinuation.finish()
    }
    _ = pump
    return FileSystemWatch(
      events: events,
      setWatchedDirectories: { directories in
        setContinuation.yield(Set(directories.map(Self.path)))
      }
    )
  }

  func gitStatus(root: URL) async throws(FileSystemSourceError) -> GitStatusSnapshot {
    let path = Self.path(root)
    let result = try await perform(RemoteFileGitStatusResult.self) { .gitStatus(id: $0, root: path) }
    return GitStatusSnapshot.parse(porcelainV2: result.porcelain)
  }

  // MARK: - Mapping.

  private func perform<Result: Codable & Sendable>(
    _ type: Result.Type,
    _ makeRequest: @escaping @Sendable (Int) -> RemoteFileRequest
  ) async throws(FileSystemSourceError) -> Result {
    do {
      return try await session.call(makeRequest, as: type)
    } catch {
      throw Self.sourceError(error)
    }
  }

  static func sourceError(_ error: RemoteKageServeError) -> FileSystemSourceError {
    switch error {
    case .unavailable(let failure):
      return .connection(failure.message)
    case .malformedResponse(let message):
      return .ioFailure("The host's answer couldn't be read: \(message)")
    case .remote(let remote):
      switch remote.code {
      case .notFound: return .notFound(remote.message)
      case .permission: return .permission(remote.message)
      case .notGit: return .notGit(remote.message)
      case .badRequest: return FileSystemSourceError(code: .badRequest, message: remote.message)
      case .inputOutput: return .ioFailure(remote.message)
      case .tooLarge:
        var error = FileSystemSourceError.tooLarge(size: Int(remote.size ?? 0))
        error.modificationDate = remote.mtime.map(date(milliseconds:))
        return error
      case .conflict:
        return .conflict(currentModificationDate: remote.mtime.map(date(milliseconds:)))
      }
    }
  }

  static func changeEvent(_ event: RemoteFileEvent) -> FileSystemChangeEvent {
    switch event {
    case .changed(let paths):
      .changed(directories: Set(paths.map { URL(filePath: $0, directoryHint: .isDirectory) }))
    case .treeChanged(let root):
      .treeChanged(root: URL(filePath: root, directoryHint: .isDirectory))
    case .rescan(let path):
      .rescan(URL(filePath: path, directoryHint: .isDirectory))
    }
  }

  /// The absolute POSIX path a URL carries, without a trailing slash. Not
  /// `standardizedFileURL`: that consults this Mac's disk (it drops a leading
  /// `/private` when the shorter path exists here), and the path names a file
  /// on the host.
  static func path(_ url: URL) -> String {
    var path = url.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }

  static func date(milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
  }

  /// Rounds rather than truncates, so a date made by `date(milliseconds:)`
  /// comes back as the same integer the host compares against.
  static func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
  }

  private static func kind(_ kind: RemoteFileKind) -> FileSystemEntry.Kind {
    switch kind {
    case .file: .file
    case .dir: .directory
    case .symlink: .symlink
    }
  }
}
