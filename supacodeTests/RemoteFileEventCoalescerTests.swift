import Clocks
import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// Event pacing of `kage host serve`: `changed` batches over 200 ms,
/// `treeChanged` at most once a second per root, `rescan` immediately.
nonisolated struct RemoteFileEventCoalescerTests {
  @Test func changedPathsAreBatchedOver200Milliseconds() async {
    let clock = TestClock()
    let events = LockIsolated<[RemoteFileEvent]>([])
    let coalescer = RemoteFileEventCoalescer(clock: clock) { event in events.withValue { $0.append(event) } }

    coalescer.ingest(RemoteFileEventClassification(changed: ["/r/b"]))
    await clock.advance(by: .milliseconds(100))
    coalescer.ingest(RemoteFileEventClassification(changed: ["/r/a", "/r/b"]))
    await clock.advance(by: .milliseconds(99))
    #expect(events.value.isEmpty)
    await clock.advance(by: .milliseconds(1))
    #expect(events.value == [.changed(paths: ["/r/a", "/r/b"])])

    // Idle: nothing more, ever.
    await clock.advance(by: .seconds(10))
    #expect(events.value.count == 1)

    coalescer.ingest(RemoteFileEventClassification(changed: ["/r/c"]))
    await clock.advance(by: .milliseconds(200))
    #expect(events.value == [.changed(paths: ["/r/a", "/r/b"]), .changed(paths: ["/r/c"])])
  }

  @Test func treeChangedLeadsThenTrailsAtMostOncePerSecondPerRoot() async {
    let clock = TestClock()
    let events = LockIsolated<[RemoteFileEvent]>([])
    let coalescer = RemoteFileEventCoalescer(clock: clock) { event in events.withValue { $0.append(event) } }

    coalescer.ingest(RemoteFileEventClassification(treeRoots: ["/r"]))
    #expect(events.value == [.treeChanged(root: "/r")])

    await clock.advance(by: .milliseconds(100))
    coalescer.ingest(RemoteFileEventClassification(treeRoots: ["/r", "/s"]))
    await clock.advance(by: .milliseconds(400))
    coalescer.ingest(RemoteFileEventClassification(treeRoots: ["/r"]))
    #expect(events.value == [.treeChanged(root: "/r"), .treeChanged(root: "/s")])

    await clock.advance(by: .milliseconds(499))
    #expect(events.value.count == 2)
    await clock.advance(by: .milliseconds(1))
    #expect(events.value == [.treeChanged(root: "/r"), .treeChanged(root: "/s"), .treeChanged(root: "/r")])

    // The trailing emission opens a new window; with no further change it lapses.
    await clock.advance(by: .seconds(5))
    #expect(events.value.count == 3)
    coalescer.ingest(RemoteFileEventClassification(treeRoots: ["/r"]))
    #expect(events.value.last == .treeChanged(root: "/r"))
    #expect(events.value.count == 4)
  }

  @Test func rescansAreImmediateAndCancelStopsPendingWork() async {
    let clock = TestClock()
    let events = LockIsolated<[RemoteFileEvent]>([])
    let coalescer = RemoteFileEventCoalescer(clock: clock) { event in events.withValue { $0.append(event) } }

    coalescer.ingest(RemoteFileEventClassification(changed: ["/r"], rescans: ["/r"]))
    #expect(events.value == [.rescan(path: "/r")])
    coalescer.cancel()
    await clock.advance(by: .seconds(1))
    #expect(events.value == [.rescan(path: "/r")])
  }
}
