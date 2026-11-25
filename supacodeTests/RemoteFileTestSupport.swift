import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// A scratch directory for `kage host serve` tests, returned in canonical form
/// (`/private/var/...`) because that is how FSEvents and `realpath` report it.
nonisolated struct RemoteFileScratchDirectory: Sendable {
  let path: String

  init() throws {
    let url = URL.temporaryDirectory.appending(path: "rf-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // Not `URL.resolvingSymlinksInPath()`: it strips `/private`, realpath keeps it.
    let canonical = try #require(realpath(url.path(percentEncoded: false), nil))
    defer { free(canonical) }
    path = String(cString: canonical)
  }

  func appending(_ component: String) -> String { path + "/" + component }

  @discardableResult
  func makeFile(_ name: String, contents: String = "", mode: Int? = nil) throws -> String {
    let filePath = appending(name)
    try FileManager.default.createDirectory(
      atPath: (filePath as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: URL(filePath: filePath))
    if let mode {
      try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: filePath)
    }
    return filePath
  }

  @discardableResult
  func makeDirectory(_ name: String) throws -> String {
    let directoryPath = appending(name)
    try FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
    return directoryPath
  }

  func remove() {
    // Restore permissions a test may have dropped so cleanup cannot fail.
    if let enumerator = FileManager.default.enumerator(atPath: path) {
      for case let relative as String in enumerator {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appending(relative))
      }
    }
    try? FileManager.default.removeItem(atPath: path)
  }

  /// The modification time the protocol reports for `filePath`.
  static func mtime(of filePath: String) throws -> Int64 {
    let date = try #require(
      try FileManager.default.attributesOfItem(atPath: filePath)[.modificationDate] as? Date
    )
    return Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
  }
}

/// An FSEvents stand-in: records every stream the watcher starts and lets a
/// test deliver events to the live one.
nonisolated final class FakeRemoteFileEventSource: RemoteFileEventSource, Sendable {
  struct Start: Equatable, Sendable {
    var paths: [String]
    var since: UInt64?
  }

  private final class Stream: RemoteFileEventStream, Sendable {
    let onStop: @Sendable () -> Void
    init(onStop: @escaping @Sendable () -> Void) { self.onStop = onStop }
    func stop() { onStop() }
  }

  let starts = LockIsolated<[Start]>([])
  let stops = LockIsolated(0)
  let eventID = LockIsolated<UInt64>(100)
  private let handler = LockIsolated<(@Sendable ([RemoteFileFSEvent]) -> Void)?>(nil)
  private let liveToken = LockIsolated<UUID?>(nil)

  func currentEventID() -> UInt64 { eventID.value }

  func start(
    paths: [String],
    since: UInt64?,
    handler: @escaping @Sendable ([RemoteFileFSEvent]) -> Void
  ) -> (any RemoteFileEventStream)? {
    starts.withValue { $0.append(Start(paths: paths, since: since)) }
    self.handler.setValue(handler)
    let token = UUID()
    liveToken.setValue(token)
    return Stream { [stops, weak self] in
      stops.withValue { $0 += 1 }
      // Stopping a replaced stream must not silence its successor.
      guard let self, liveToken.value == token else { return }
      self.handler.setValue(nil)
      liveToken.setValue(nil)
    }
  }

  var isRunning: Bool { handler.value != nil }

  func send(_ events: [RemoteFileFSEvent]) {
    handler.value?(events)
  }

  func send(path: String, flags: RemoteFileFSEvent.Flags = []) {
    send([RemoteFileFSEvent(path: path, flags: flags, id: eventID.value)])
  }
}

/// Identity resolution for fake paths: anything ending in `.txt` is a file.
nonisolated enum FakeRemoteFileResolver {
  static func resolve(gitDirectories: [String: String] = [:]) -> @Sendable (String) -> RemoteFileWatchEntry? {
    { path in
      RemoteFileWatchEntry(
        requested: path,
        canonical: path,
        isDirectory: !path.hasSuffix(".txt"),
        gitDirectory: gitDirectories[path]
      )
    }
  }
}
