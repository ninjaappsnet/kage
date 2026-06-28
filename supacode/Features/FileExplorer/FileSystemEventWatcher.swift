import CoreServices
import Foundation

/// Watches a directory subtree with FSEvents and invokes `onChange` whenever
/// anything underneath it is created, deleted, renamed, or modified. Coding
/// agents mutate the worktree constantly, so the explorer needs to reflect disk
/// changes without a manual refresh.
///
/// `onChange` fires on a private dispatch queue (not the main thread); the model
/// hops back to the main actor. The stream stops and releases on `deinit`, so a
/// watcher's lifetime is simply tied to its owner.
final class FileSystemEventWatcher: @unchecked Sendable {
  nonisolated(unsafe) private var stream: FSEventStreamRef?
  private let queue = DispatchQueue(label: "net.ninjaapps.kage.file-explorer.fsevents")
  private let onChange: @Sendable () -> Void

  /// Returns `nil` if FSEvents could not create a stream for `url` (e.g. the
  /// path is gone); callers degrade gracefully to manual / on-appear refresh.
  init?(url: URL, latency: TimeInterval = 0.3, onChange: @escaping @Sendable () -> Void) {
    self.onChange = onChange
    self.stream = nil

    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil,
    )
    let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<FileSystemEventWatcher>.fromOpaque(info).takeUnretainedValue()
      watcher.onChange()
    }
    let flags = UInt32(
      kFSEventStreamCreateFlagFileEvents
        | kFSEventStreamCreateFlagNoDefer
        | kFSEventStreamCreateFlagIgnoreSelf
    )
    guard
      let stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        callback,
        &context,
        [url.path(percentEncoded: false)] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        latency,
        flags
      )
    else {
      return nil
    }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, queue)
    _ = FSEventStreamStart(stream)
  }

  deinit {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}
