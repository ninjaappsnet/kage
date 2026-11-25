import Clocks
import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// The watch-set manager behind `watch`: one stream over the top-most
/// directories, rebuilt (debounced, without losing events) only when they change.
nonisolated struct RemoteFileWatcherTests {
  private struct Harness {
    let clock = TestClock()
    let source = FakeRemoteFileEventSource()
    let events = LockIsolated<[RemoteFileEvent]>([])
    let stamps = LockIsolated<[String: RemoteFileGitStamp]>([:])
    let watcher: RemoteFileWatcher

    init(gitDirectories: [String: String] = [:]) {
      let events = events
      let stamps = stamps
      watcher = RemoteFileWatcher(
        source: source,
        clock: clock,
        resolve: FakeRemoteFileResolver.resolve(gitDirectories: gitDirectories),
        gitStamp: { stamps.value[$0] ?? RemoteFileGitStamp(head: nil, index: nil) },
        emit: { event in events.withValue { $0.append(event) } }
      )
    }
  }

  @Test func theFirstWatchStartsAStreamImmediately() {
    let harness = Harness()
    harness.watcher.setWatchedPaths(["/repo", "/repo/src"])
    #expect(harness.source.starts.value == [.init(paths: ["/repo"], since: nil)])
  }

  @Test func expandingADirectoryUnderAWatchedRootKeepsTheStream() async {
    let harness = Harness()
    harness.watcher.setWatchedPaths(["/repo"])
    harness.watcher.setWatchedPaths(["/repo", "/repo/src"])
    await harness.clock.advance(by: .seconds(1))
    #expect(harness.source.starts.value.count == 1)

    // The new directory is reported right away, through the same stream.
    harness.source.send(path: "/repo/src/")
    await harness.clock.advance(by: .milliseconds(200))
    #expect(harness.events.value == [.treeChanged(root: "/repo"), .changed(paths: ["/repo/src"])])
  }

  @Test func newRootsRebuildTheStreamOnceAfterADebounceFromTheChangeEventID() async {
    let harness = Harness()
    harness.watcher.setWatchedPaths(["/a"])
    harness.source.eventID.setValue(500)
    harness.watcher.setWatchedPaths(["/a", "/b"])
    await harness.clock.advance(by: .milliseconds(100))
    harness.source.eventID.setValue(600)
    harness.watcher.setWatchedPaths(["/a", "/b", "/c"])
    await harness.clock.advance(by: .milliseconds(199))
    #expect(harness.source.starts.value.count == 1)
    await harness.clock.advance(by: .milliseconds(1))
    #expect(
      harness.source.starts.value == [
        .init(paths: ["/a"], since: nil),
        .init(paths: ["/a", "/b", "/c"], since: 500),
      ]
    )
    #expect(harness.source.stops.value == 1)
    #expect(harness.source.isRunning)
  }

  @Test func anEmptySetStopsTheStreamAndAPendingRebuild() async {
    let harness = Harness()
    harness.watcher.setWatchedPaths(["/a"])
    harness.watcher.setWatchedPaths(["/b"])
    harness.watcher.setWatchedPaths([])
    await harness.clock.advance(by: .seconds(1))
    #expect(harness.source.starts.value.count == 1)
    #expect(harness.source.stops.value == 1)
    #expect(!harness.source.isRunning)

    harness.watcher.setWatchedPaths(["/b"])
    #expect(harness.source.starts.value.last == .init(paths: ["/b"], since: nil))
  }

  @Test func gitDirectoryEventsCountOnlyWhenHeadOrIndexChanged() async {
    let harness = Harness(gitDirectories: ["/repo": "/repo/.git"])
    let stamp = RemoteFileGitStamp(head: .init(modification: 1, size: 10, inode: 1), index: nil)
    harness.stamps.setValue(["/repo/.git": stamp])
    harness.watcher.setWatchedPaths(["/repo"])

    // A lock file or FETCH_HEAD came and went: HEAD and index are unchanged.
    harness.source.send(path: "/repo/.git/")
    await harness.clock.advance(by: .seconds(2))
    #expect(harness.events.value.isEmpty)

    harness.stamps.setValue([
      "/repo/.git": RemoteFileGitStamp(head: stamp.head, index: .init(modification: 2, size: 5, inode: 2))
    ])
    harness.source.send(path: "/repo/.git/")
    #expect(harness.events.value == [.treeChanged(root: "/repo")])
  }

  @Test func stopEndsTheStreamAndPendingEvents() async {
    let harness = Harness()
    harness.watcher.setWatchedPaths(["/repo"])
    harness.source.send(path: "/repo")
    harness.watcher.stop()
    await harness.clock.advance(by: .seconds(1))
    #expect(harness.events.value == [.treeChanged(root: "/repo")])
    #expect(!harness.source.isRunning)
  }
}
