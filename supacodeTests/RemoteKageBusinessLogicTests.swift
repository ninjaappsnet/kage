import Foundation
import Testing

@testable import supacode

struct RemoteKagePollScheduleTests {
  @Test func retryDelayDoublesFromFiveSecondsUpToAMinute() {
    let delays = (1...7).map { RemoteKagePollSchedule.retryDelay(afterFailures: $0) }
    #expect(
      delays == [.seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60), .seconds(60), .seconds(60)])
  }

  private static func ticks(_ schedule: inout RemoteKagePollSchedule, _ count: Int) -> [Bool] {
    (0..<count).map { _ in schedule.consumeTick() }
  }

  @Test func failuresSkipTicksUntilTheRetryDelayPassed() {
    var schedule = RemoteKagePollSchedule()
    #expect(Self.ticks(&schedule, 1) == [true])
    schedule.recordFailure()  // 5 s: poll on the next tick.
    #expect(Self.ticks(&schedule, 1) == [true])
    schedule.recordFailure()  // 10 s: skip one tick.
    #expect(Self.ticks(&schedule, 2) == [false, true])
    schedule.recordFailure()  // 20 s: skip three ticks.
    #expect(Self.ticks(&schedule, 4) == [false, false, false, true])
  }

  @Test func successResetsTheBackoff() {
    var schedule = RemoteKagePollSchedule()
    schedule.recordFailure()
    schedule.recordFailure()
    schedule.recordSuccess()
    #expect(schedule.failureCount == 0)
    #expect(Self.ticks(&schedule, 1) == [true])
  }
}

struct RemoteKageSnapshotDiffTests {
  private typealias Fixtures = RemoteKagePollingFixtures

  @Test func firstSnapshotNeverCountsAsATransition() {
    let current = Fixtures.snapshot(tabs: [Fixtures.tab("t1", activity: "awaitingInput")])
    #expect(RemoteKageSnapshotDiff.newlyAwaitingTabs(previous: nil, current: current).isEmpty)
  }

  @Test func busyToAwaitingIsATransition() {
    let previous = Fixtures.snapshot(tabs: [Fixtures.tab("t1", activity: "busy"), Fixtures.tab("t2")])
    let current = Fixtures.snapshot(tabs: [
      Fixtures.tab("t1", title: "Claude", activity: "awaitingInput"), Fixtures.tab("t2"),
    ])
    let awaiting = RemoteKageSnapshotDiff.newlyAwaitingTabs(previous: previous, current: current)
    #expect(awaiting.map(\.tab.id) == ["t1"])
    #expect(awaiting.first?.repositoryName == "kage")
    #expect(awaiting.first?.worktreeID == Fixtures.worktreeID)
  }

  @Test func stillAwaitingIsNotATransition() {
    let snapshot = Fixtures.snapshot(tabs: [Fixtures.tab("t1", activity: "awaitingInput")])
    #expect(RemoteKageSnapshotDiff.newlyAwaitingTabs(previous: snapshot, current: snapshot).isEmpty)
  }

  @Test func aNewTabThatIsAlreadyAwaitingIsATransition() {
    let previous = Fixtures.snapshot(tabs: [])
    let current = Fixtures.snapshot(tabs: [Fixtures.tab("t9", activity: "awaitingInput")])
    #expect(RemoteKageSnapshotDiff.newlyAwaitingTabs(previous: previous, current: current).map(\.tab.id) == ["t9"])
  }

  @Test func tabIDsCoverEveryWorktree() {
    let snapshot = Fixtures.snapshot(tabs: [Fixtures.tab("t1"), Fixtures.tab("t2")])
    #expect(RemoteKageSnapshotDiff.tabIDs(in: snapshot) == ["t1", "t2"])
  }
}
