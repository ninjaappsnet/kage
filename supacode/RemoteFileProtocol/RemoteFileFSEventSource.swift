import CoreServices
import Foundation
import Synchronization

/// The live event source: FSEvents, directory-level (no per-file events),
/// 0.2 s latency, `WatchRoot` so a moved or deleted root is reported.
nonisolated struct RemoteFileFSEventSource: RemoteFileEventSource {
  var latency: TimeInterval = 0.2

  func currentEventID() -> UInt64 {
    FSEventsGetCurrentEventId()
  }

  func start(
    paths: [String],
    since: UInt64?,
    handler: @escaping @Sendable ([RemoteFileFSEvent]) -> Void
  ) -> (any RemoteFileEventStream)? {
    RemoteFileFSEventStream(paths: paths, since: since, latency: latency, handler: handler)
  }
}

/// One `FSEventStream` delivering on a private serial queue. The callback box
/// is owned by the stream's context (released when the stream is), so a
/// callback already queued when `stop()` runs never touches freed memory.
nonisolated final class RemoteFileFSEventStream: RemoteFileEventStream, @unchecked Sendable {
  private final class Callback: Sendable {
    let handler: @Sendable ([RemoteFileFSEvent]) -> Void
    init(handler: @escaping @Sendable ([RemoteFileFSEvent]) -> Void) { self.handler = handler }
  }

  private let stream: FSEventStreamRef
  private let queue = DispatchQueue(label: "net.ninjaapps.kage.host-serve.fsevents")
  private let isStopped = Mutex(false)

  init?(
    paths: [String],
    since: UInt64?,
    latency: TimeInterval,
    handler: @escaping @Sendable ([RemoteFileFSEvent]) -> Void
  ) {
    let callbackBox = Unmanaged.passRetained(Callback(handler: handler))
    var context = FSEventStreamContext(
      version: 0,
      info: callbackBox.toOpaque(),
      retain: nil,
      release: { info in
        guard let info else { return }
        Unmanaged<AnyObject>.fromOpaque(info).release()
      },
      copyDescription: nil
    )
    let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, eventIDs in
      guard let info else { return }
      let box = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
      let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
      var events: [RemoteFileFSEvent] = []
      events.reserveCapacity(count)
      for index in 0..<count {
        guard let path = paths[index] as? String else { continue }
        events.append(
          RemoteFileFSEvent(
            path: path,
            flags: RemoteFileFSEventStream.flags(eventFlags[index]),
            id: eventIDs[index]
          )
        )
      }
      box.handler(events)
    }
    let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
    guard
      let stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        callback,
        &context,
        paths as CFArray,
        since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        latency,
        flags
      )
    else {
      callbackBox.release()
      return nil
    }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, queue)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      return nil
    }
  }

  func stop() {
    let wasStopped = isStopped.withLock { stopped in
      defer { stopped = true }
      return stopped
    }
    guard !wasStopped else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }

  deinit {
    stop()
  }

  private static func flags(_ raw: FSEventStreamEventFlags) -> RemoteFileFSEvent.Flags {
    let mapping: [(Int, RemoteFileFSEvent.Flags)] = [
      (kFSEventStreamEventFlagMustScanSubDirs, .mustScanSubDirs),
      (kFSEventStreamEventFlagUserDropped, .userDropped),
      (kFSEventStreamEventFlagKernelDropped, .kernelDropped),
      (kFSEventStreamEventFlagEventIdsWrapped, .eventIDsWrapped),
      (kFSEventStreamEventFlagHistoryDone, .historyDone),
      (kFSEventStreamEventFlagRootChanged, .rootChanged),
      (kFSEventStreamEventFlagUnmount, .unmount),
    ]
    var result: RemoteFileFSEvent.Flags = []
    for (bit, flag) in mapping where raw & FSEventStreamEventFlags(bit) != 0 {
      result.insert(flag)
    }
    return result
  }
}
