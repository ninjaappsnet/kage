import Darwin
import Foundation
import Synchronization

/// A running FSEvents stream (or a test's stand-in).
nonisolated protocol RemoteFileEventStream: AnyObject, Sendable {
  func stop()
}

/// Starts event streams. `RemoteFileFSEventSource` is the live one.
nonisolated protocol RemoteFileEventSource: Sendable {
  /// The newest event id the system has handed out; a rebuilt stream replays
  /// from the id captured when the watch set changed, so no event is lost.
  func currentEventID() -> UInt64

  func start(
    paths: [String],
    since: UInt64?,
    handler: @escaping @Sendable ([RemoteFileFSEvent]) -> Void
  ) -> (any RemoteFileEventStream)?
}

/// What `treeChanged` watches inside a git directory: HEAD (branch switch,
/// commit) and index (stage, unstage). Lock files and FETCH_HEAD come and go
/// in the same folder and must not count.
nonisolated struct RemoteFileGitStamp: Equatable, Sendable {
  nonisolated struct File: Equatable, Sendable {
    var modification: Int64
    var size: Int64
    var inode: UInt64
  }

  var head: File?
  var index: File?

  static func read(_ gitDirectory: String) -> Self {
    Self(head: file(gitDirectory + "/HEAD"), index: file(gitDirectory + "/index"))
  }

  private static func file(_ path: String) -> File? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    let modification = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    return File(modification: modification, size: Int64(info.st_size), inode: UInt64(info.st_ino))
  }
}

/// Owns the `watch` set of one `kage host serve` process: one event stream
/// over its roots, started at once when there is none, rebuilt after a short
/// debounce only when the roots themselves change (expanding a folder inside a
/// watched root costs nothing), and stopped when the set empties.
nonisolated final class RemoteFileWatcher: Sendable {
  private struct State {
    var set = RemoteFileWatchSet(entries: [])
    var stream: (any RemoteFileEventStream)?
    var streamPaths: [String] = []
    var streamGeneration = 0
    var pendingSince: UInt64?
    var rebuildTask: Task<Void, Never>?
    var rebuildGeneration = 0
    var stamps: [String: RemoteFileGitStamp] = [:]
  }

  private let state = Mutex(State())
  private let source: any RemoteFileEventSource
  private let clock: any Clock<Duration>
  private let resolve: @Sendable (String) -> RemoteFileWatchEntry?
  private let gitStamp: @Sendable (String) -> RemoteFileGitStamp
  private let rebuildDelay: Duration
  private let coalescer: RemoteFileEventCoalescer

  init(
    source: any RemoteFileEventSource,
    clock: any Clock<Duration>,
    resolve: @escaping @Sendable (String) -> RemoteFileWatchEntry? = RemoteFileWatchEntry.resolve,
    gitStamp: @escaping @Sendable (String) -> RemoteFileGitStamp = RemoteFileGitStamp.read,
    rebuildDelay: Duration = .milliseconds(200),
    emit: @escaping @Sendable (RemoteFileEvent) -> Void
  ) {
    self.source = source
    self.clock = clock
    self.resolve = resolve
    self.gitStamp = gitStamp
    self.rebuildDelay = rebuildDelay
    coalescer = RemoteFileEventCoalescer(clock: clock, emit: emit)
  }

  static func live(emit: @escaping @Sendable (RemoteFileEvent) -> Void) -> RemoteFileWatcher {
    RemoteFileWatcher(source: RemoteFileFSEventSource(), clock: ContinuousClock(), emit: emit)
  }

  /// Replaces the watch set. Paths that do not exist are skipped (the viewer
  /// re-sends the set when it re-lists). Returns once a first stream is live.
  func setWatchedPaths(_ paths: [String]) {
    let set = RemoteFileWatchSet(entries: paths.compactMap(resolve))
    let stopped: (any RemoteFileEventStream)? = state.withLock { state in
      state.set = set
      state.stamps = Dictionary(
        uniqueKeysWithValues: set.gitDirectories.map { ($0, state.stamps[$0] ?? gitStamp($0)) }
      )
      let target = set.streamPaths
      if target.isEmpty {
        state.rebuildTask?.cancel()
        state.rebuildTask = nil
        state.pendingSince = nil
        state.streamPaths = []
        state.streamGeneration += 1
        defer { state.stream = nil }
        return state.stream
      }
      if state.stream == nil {
        startStream(in: &state, since: nil)
        return nil
      }
      if target == state.streamPaths {
        state.rebuildTask?.cancel()
        state.rebuildTask = nil
        state.pendingSince = nil
        return nil
      }
      if state.pendingSince == nil { state.pendingSince = source.currentEventID() }
      state.rebuildTask?.cancel()
      state.rebuildGeneration += 1
      let generation = state.rebuildGeneration
      state.rebuildTask = Task { [weak self, clock, rebuildDelay] in
        try? await clock.sleep(for: rebuildDelay)
        guard !Task.isCancelled else { return }
        self?.rebuildStream(generation: generation)
      }
      return nil
    }
    if let stopped {
      stopped.stop()
      coalescer.cancel()
    }
  }

  /// Stops the stream and drops pending events (stdin closed).
  func stop() {
    let stopped = state.withLock { state -> (any RemoteFileEventStream)? in
      state.rebuildTask?.cancel()
      state.rebuildTask = nil
      state.streamGeneration += 1
      state.streamPaths = []
      defer { state.stream = nil }
      return state.stream
    }
    stopped?.stop()
    coalescer.cancel()
  }

  private func rebuildStream(generation: Int) {
    let old = state.withLock { state -> (any RemoteFileEventStream)? in
      guard state.rebuildTask != nil, state.rebuildGeneration == generation else { return nil }
      state.rebuildTask = nil
      let old = state.stream
      let since = state.pendingSince
      state.pendingSince = nil
      startStream(in: &state, since: since)
      return old
    }
    old?.stop()
  }

  private func startStream(in state: inout State, since: UInt64?) {
    state.streamGeneration += 1
    let generation = state.streamGeneration
    state.streamPaths = state.set.streamPaths
    state.stream = source.start(paths: state.set.streamPaths, since: since) { [weak self] events in
      self?.handle(events, generation: generation)
    }
  }

  private func handle(_ events: [RemoteFileFSEvent], generation: Int) {
    let classification = state.withLock { state -> RemoteFileEventClassification? in
      guard state.streamGeneration == generation else { return nil }
      var classification = state.set.classify(events)
      for gitDirectory in classification.gitDirectories {
        let stamp = gitStamp(gitDirectory)
        guard stamp != state.stamps[gitDirectory] else { continue }
        state.stamps[gitDirectory] = stamp
        classification.treeRoots.formUnion(state.set.roots(forGitDirectory: gitDirectory))
      }
      classification.gitDirectories = []
      return classification
    }
    guard let classification, !classification.isEmpty else { return }
    coalescer.ingest(classification)
  }
}
