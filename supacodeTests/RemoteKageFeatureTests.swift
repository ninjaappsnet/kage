import ComposableArchitecture
import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct RemoteKageFeatureTests {
  private typealias Fixtures = RemoteKagePollingFixtures
  private let now = Date(timeIntervalSince1970: 1_000_000)

  private func state(
    hosts: [RemoteKageHost] = [RemoteKagePollingFixtures.host],
    _ configure: (inout RemoteKageFeature.State) -> Void = { _ in }
  ) -> RemoteKageFeature.State {
    var state = RemoteKageFeature.State()
    state.$file.withLock { $0 = RemoteKageHostsFile(hosts: hosts) }
    configure(&state)
    return state
  }

  private func enableSystemNotifications(_ isEnabled: Bool) {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.systemNotificationsEnabled = isEnabled }
  }

  // MARK: Polling.

  @Test(.dependencies) func taskPollsAtOnceThenEveryFiveSeconds() async {
    let clock = TestClock()
    let fetches = LockIsolated(0)
    let snapshot = Fixtures.snapshot(tabs: [Fixtures.tab("t1")])
    let store = TestStore(initialState: state()) {
      RemoteKageFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date = .constant(now)
      $0.remoteKageClient.snapshot = { _ in
        fetches.withValue { $0 += 1 }
        return snapshot
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.task)
    #expect(store.state.hostStates[Fixtures.hostID]?.status == .connecting)
    await store.receive(\.snapshotResponse)
    #expect(fetches.value == 1)
    #expect(
      store.state.hostStates[Fixtures.hostID]
        == RemoteKageFeature.HostState(status: .online, lastSnapshot: snapshot, lastUpdated: now))
    await clock.advance(by: RemoteKageFeature.pollInterval)
    await store.receive(\.pollTick)
    await store.receive(\.snapshotResponse)
    #expect(fetches.value == 2)
    await store.skipInFlightEffects()
  }

  @Test(.dependencies) func neverRunsTwoSnapshotsForOneHostAtOnce() async {
    let clock = TestClock()
    let fetches = LockIsolated(0)
    let snapshot = Fixtures.snapshot(tabs: [])
    let store = TestStore(initialState: state()) {
      RemoteKageFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date = .constant(now)
      $0.remoteKageClient.snapshot = { _ in
        fetches.withValue { $0 += 1 }
        try await clock.sleep(for: .seconds(12))
        return snapshot
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.task)
    await clock.advance(by: .seconds(5))
    await store.receive(\.pollTick)
    await clock.advance(by: .seconds(5))
    await store.receive(\.pollTick)
    #expect(fetches.value == 1)
    await clock.advance(by: .seconds(2))
    await store.receive(\.snapshotResponse)
    #expect(store.state.hostStates[Fixtures.hostID]?.status == .online)
    await clock.advance(by: .seconds(3))
    await store.receive(\.pollTick)
    #expect(fetches.value == 2)
    await store.skipInFlightEffects()
  }

  @Test(.dependencies) func offlineHostsBackOffAndRecoverOnSuccess() async {
    let clock = TestClock()
    let fetches = LockIsolated(0)
    let isUp = LockIsolated(false)
    let snapshot = Fixtures.snapshot(tabs: [])
    let store = TestStore(initialState: state()) {
      RemoteKageFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date = .constant(now)
      $0.remoteKageClient.snapshot = { _ in
        fetches.withValue { $0 += 1 }
        guard isUp.value else { throw RemoteKageError.unreachable("Connection refused") }
        return snapshot
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.task)
    await store.receive(\.snapshotResponse)
    #expect(store.state.hostStates[Fixtures.hostID]?.status == .offline("Can't reach the host: Connection refused"))
    // 1st failure: retry after 5 s.
    await tick(store, clock)
    await store.receive(\.snapshotResponse)
    #expect(fetches.value == 2)
    // 2nd failure: retry after 10 s.
    await tick(store, clock)
    #expect(fetches.value == 2)
    await tick(store, clock)
    await store.receive(\.snapshotResponse)
    #expect(fetches.value == 3)
    // 3rd failure: retry after 20 s.
    for _ in 0..<3 { await tick(store, clock) }
    #expect(fetches.value == 3)
    isUp.setValue(true)
    await tick(store, clock)
    await store.receive(\.snapshotResponse)
    #expect(fetches.value == 4)
    #expect(store.state.hostStates[Fixtures.hostID]?.status == .online)
    // Success resets the backoff: polled on the very next tick.
    await tick(store, clock)
    await store.receive(\.snapshotResponse)
    #expect(fetches.value == 5)
    await store.skipInFlightEffects()
  }

  private func tick(_ store: TestStoreOf<RemoteKageFeature>, _ clock: TestClock<Duration>) async {
    await clock.advance(by: RemoteKageFeature.pollInterval)
    await store.receive(\.pollTick)
  }

  @Test(.dependencies) func failuresKeepTheLastSnapshotAndMapTheStatus() async {
    let snapshot = Fixtures.snapshot(tabs: [Fixtures.tab("t1")])
    let store = TestStore(initialState: state()) {
      RemoteKageFeature()
    } withDependencies: {
      $0.date = .constant(now)
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.snapshotResponse(Fixtures.hostID, .success(snapshot)))
    await store.send(.snapshotResponse(Fixtures.hostID, .failure(.needsUpdate)))
    #expect(store.state.hostStates[Fixtures.hostID]?.status == .needsUpdate)
    #expect(store.state.hostStates[Fixtures.hostID]?.lastSnapshot == snapshot)
    #expect(store.state.hostStates[Fixtures.hostID]?.lastUpdated == now)
    await store.send(.snapshotResponse(Fixtures.hostID, .failure(.kageNotRunning)))
    #expect(store.state.hostStates[Fixtures.hostID]?.status == .kageNotRunning)
    await store.send(.snapshotResponse(Fixtures.hostID, .failure(.commandFailed("Boom"))))
    #expect(store.state.hostStates[Fixtures.hostID]?.status == .offline("Boom"))
    #expect(store.state.hostStates[Fixtures.hostID]?.lastSnapshot == snapshot)
  }

  @Test(.dependencies) func hostsFileChangesStartAndStopPolling() async {
    let clock = TestClock()
    let polled = LockIsolated<[UUID]>([])
    let snapshot = Fixtures.snapshot(tabs: [Fixtures.tab("t1")])
    let initial = state(hosts: [Fixtures.host]) {
      $0.selection = Fixtures.selection
      $0.selectedTabByWorktree[Fixtures.selection] = "t1"
      $0.attachedTabs = [Fixtures.key("t1")]
      $0.screens[Fixtures.key("t1")] = "screen"
    }
    let store = TestStore(initialState: initial) {
      RemoteKageFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date = .constant(now)
      $0.remoteKageClient.snapshot = { host in
        polled.withValue { $0.append(host.id) }
        return snapshot
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.task)
    await store.receive(\.snapshotResponse)
    store.state.$file.withLock { $0.hosts.append(Fixtures.otherHost) }
    await store.receive(\.hostsFileChanged)
    await store.receive(\.snapshotResponse)
    #expect(polled.value == [Fixtures.hostID, Fixtures.otherHostID])
    #expect(store.state.hostStates[Fixtures.otherHostID]?.status == .online)

    store.state.$file.withLock { $0.hosts.removeAll { $0.id == Fixtures.hostID } }
    await store.receive(\.hostsFileChanged)
    #expect(store.state.hostStates[Fixtures.hostID] == nil)
    #expect(store.state.selection == nil)
    #expect(store.state.selectedTabByWorktree.isEmpty)
    #expect(store.state.attachedTabs.isEmpty)
    #expect(store.state.screens.isEmpty)
    await tick(store, clock)
    await store.receive(\.snapshotResponse)
    #expect(polled.value == [Fixtures.hostID, Fixtures.otherHostID, Fixtures.otherHostID])
    await store.skipInFlightEffects()
  }

  @Test(.dependencies) func vanishedTabsLoseTheirAttachmentScreenAndSelection() async {
    let initial = state {
      $0.selectedTabByWorktree[Fixtures.selection] = "t2"
      $0.attachedTabs = [Fixtures.key("t1"), Fixtures.key("t2"), Fixtures.key("t2", host: Fixtures.otherHostID)]
      $0.screens = [Fixtures.key("t1"): "one", Fixtures.key("t2"): "two"]
    }
    let store = TestStore(initialState: initial) {
      RemoteKageFeature()
    } withDependencies: {
      $0.date = .constant(now)
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.snapshotResponse(Fixtures.hostID, .success(Fixtures.snapshot(tabs: [Fixtures.tab("t1")]))))
    #expect(store.state.attachedTabs == [Fixtures.key("t1"), Fixtures.key("t2", host: Fixtures.otherHostID)])
    #expect(store.state.screens == [Fixtures.key("t1"): "one"])
    #expect(store.state.selectedTabByWorktree.isEmpty)
  }

  // MARK: Notifications.

  @Test(.dependencies) func notifiesWhenATabStartsWaitingForInput() async {
    enableSystemNotifications(true)
    let sent = LockIsolated<[String]>([])
    let store = TestStore(initialState: state()) {
      RemoteKageFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.systemNotificationClient.send = { title, body, _ in sent.withValue { $0.append("\(title) | \(body)") } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    let busy = Fixtures.snapshot(tabs: [Fixtures.tab("t1", title: "Fix login", activity: "busy")])
    let waiting = Fixtures.snapshot(tabs: [Fixtures.tab("t1", title: "Fix login", activity: "awaitingInput")])
    await store.send(.snapshotResponse(Fixtures.hostID, .success(busy)))
    await store.send(.snapshotResponse(Fixtures.hostID, .success(waiting)))
    await store.send(.snapshotResponse(Fixtures.hostID, .success(waiting)))
    await store.finish()
    #expect(sent.value == ["Mini · kage | Fix login is waiting for input"])
  }

  @Test(.dependencies) func firstSnapshotNeverNotifies() async {
    enableSystemNotifications(true)
    let store = TestStore(initialState: state()) {
      RemoteKageFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.systemNotificationClient.send = { _, _, _ in Issue.record("Unexpected notification") }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    let waiting = Fixtures.snapshot(tabs: [Fixtures.tab("t1", activity: "awaitingInput")])
    await store.send(.snapshotResponse(Fixtures.hostID, .success(waiting)))
    await store.finish()
  }

  @Test(.dependencies) func attachedVisibleTabDoesNotNotify() async {
    enableSystemNotifications(true)
    let initial = state {
      $0.selection = Fixtures.selection
      $0.selectedTabByWorktree[Fixtures.selection] = "t1"
      $0.attachedTabs = [Fixtures.key("t1")]
    }
    let store = TestStore(initialState: initial) {
      RemoteKageFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.systemNotificationClient.send = { _, _, _ in Issue.record("Unexpected notification") }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.snapshotResponse(Fixtures.hostID, .success(Fixtures.snapshot(tabs: [Fixtures.tab("t1")]))))
    await store.send(
      .snapshotResponse(
        Fixtures.hostID, .success(Fixtures.snapshot(tabs: [Fixtures.tab("t1", activity: "awaitingInput")]))))
    await store.finish()
  }

  @Test(.dependencies) func disabledSystemNotificationsPlayTheSoundInstead() async {
    enableSystemNotifications(false)
    let played = LockIsolated<[NotificationSound]>([])
    let store = TestStore(initialState: state()) {
      RemoteKageFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.systemNotificationClient.send = { _, _, _ in Issue.record("Unexpected notification") }
      $0[NotificationSoundClient.self].play = { sound in played.withValue { $0.append(sound) } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.snapshotResponse(Fixtures.hostID, .success(Fixtures.snapshot(tabs: [Fixtures.tab("t1")]))))
    await store.send(
      .snapshotResponse(
        Fixtures.hostID, .success(Fixtures.snapshot(tabs: [Fixtures.tab("t1", activity: "awaitingInput")]))))
    await store.finish()
    #expect(played.value == [GlobalSettings.default.notificationSound])
  }

  // MARK: Selection and screens.

  private func onlineState(
    tabs: [HostSnapshot.Tab],
    _ configure: (inout RemoteKageFeature.State) -> Void = { _ in }
  ) -> RemoteKageFeature.State {
    state {
      $0.hostStates[Fixtures.hostID] = RemoteKageFeature.HostState(
        status: .online, lastSnapshot: Fixtures.snapshot(tabs: tabs), lastUpdated: now)
      configure(&$0)
    }
  }

  @Test(.dependencies) func selectingAWorktreeShowsItsFocusedTabScreen() async {
    let requests = LockIsolated<[String]>([])
    let store = TestStore(initialState: onlineState(tabs: [Fixtures.tab("t1"), Fixtures.tab("t2", focused: true)])) {
      RemoteKageFeature()
    } withDependencies: {
      $0.remoteKageClient.screen = { _, zmxPath, session in
        requests.withValue { $0.append("\(zmxPath) \(session)") }
        return "screen of \(session)"
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.select(Fixtures.selection))
    #expect(store.state.selection == Fixtures.selection)
    #expect(store.state.selectedTabByWorktree[Fixtures.selection] == "t2")
    await store.receive(\.screenResponse)
    #expect(store.state.screens[Fixtures.key("t2")] == "screen of supa-t2")
    #expect(requests.value == ["/Applications/Kage.app/Contents/Resources/zmx/zmx supa-t2"])
    await store.send(.select(nil))
    #expect(store.state.selection == nil)
  }

  @Test(.dependencies) func selectingAnAttachedTabFetchesNoScreen() async {
    let initial = onlineState(tabs: [Fixtures.tab("t1")]) { $0.attachedTabs = [Fixtures.key("t1")] }
    let store = TestStore(initialState: initial) {
      RemoteKageFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.selectTab(Fixtures.selection, tabID: "t1"))
    #expect(store.state.selectedTabByWorktree[Fixtures.selection] == "t1")
    await store.finish()
  }

  @Test(.dependencies) func pollTickRefreshesTheShownUnattachedScreen() async {
    let initial = onlineState(tabs: [Fixtures.tab("t1")]) {
      $0.selection = Fixtures.selection
      $0.selectedTabByWorktree[Fixtures.selection] = "t1"
    }
    let store = TestStore(initialState: initial) {
      RemoteKageFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.remoteKageClient.snapshot = { _ in Fixtures.snapshot(tabs: [Fixtures.tab("t1")]) }
      $0.remoteKageClient.screen = { _, _, _ in "fresh" }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.pollTick)
    await store.receive(\.screenResponse)
    #expect(store.state.screens[Fixtures.key("t1")] == "fresh")
    await store.finish()
  }

  @Test(.dependencies) func attachAndDetachTrackTheLiveTerminal() async {
    let store = TestStore(initialState: onlineState(tabs: [Fixtures.tab("t1")])) {
      RemoteKageFeature()
    } withDependencies: {
      $0.remoteKageClient.screen = { _, _, _ in "after detach" }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.attachTab(Fixtures.key("t1")))
    #expect(store.state.attachedTabs == [Fixtures.key("t1")])
    await store.send(.detachTab(Fixtures.key("t1")))
    #expect(store.state.attachedTabs.isEmpty)
    await store.receive(\.screenResponse)
    #expect(store.state.screens[Fixtures.key("t1")] == "after detach")
  }

  // MARK: Quick answer.

  @Test(.dependencies) func quickAnswerTypesThenRefreshesTheScreen() async {
    let clock = TestClock()
    let sent = LockIsolated<[String]>([])
    let store = TestStore(initialState: onlineState(tabs: [Fixtures.tab("t1", activity: "awaitingInput")])) {
      RemoteKageFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.remoteKageClient.send = { _, _, session, text in sent.withValue { $0.append("\(session):\(text)") } }
      $0.remoteKageClient.screen = { _, _, _ in "answered" }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.quickAnswer(Fixtures.key("t1"), text: "1"))
    await clock.advance(by: .milliseconds(299))
    #expect(store.state.screens.isEmpty)
    await clock.advance(by: .milliseconds(1))
    await store.receive(\.refreshScreen)
    await store.receive(\.screenResponse)
    #expect(sent.value == ["supa-t1:1"])
    #expect(store.state.screens[Fixtures.key("t1")] == "answered")
  }

  @Test(.dependencies) func failedQuickAnswerShowsAnError() async {
    let store = TestStore(initialState: onlineState(tabs: [Fixtures.tab("t1")])) {
      RemoteKageFeature()
    } withDependencies: {
      $0.remoteKageClient.send = { _, _, _, _ in throw RemoteKageError.unreachable("Broken pipe") }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.quickAnswer(Fixtures.key("t1"), text: "1"))
    await store.receive(\.quickAnswerFailed)
    #expect(store.state.lastError == "Can't reach the host: Broken pipe")
    await store.send(.dismissError)
    #expect(store.state.lastError == nil)
  }

  // MARK: New tab.

  @Test(.dependencies) func newTabIsSelectedAndAttachedOnceItAppears() async {
    let newID = UUID(5)
    let created = LockIsolated<[String]>([])
    let snapshots = LockIsolated(0)
    let store = TestStore(initialState: onlineState(tabs: [Fixtures.tab("t1")])) {
      RemoteKageFeature()
    } withDependencies: {
      $0.uuid = .constant(newID)
      $0.date = .constant(now)
      $0.remoteKageClient.newTab = { _, cliPath, worktreeID, tabID, command in
        created.withValue { $0.append("\(cliPath) \(worktreeID) \(tabID.uuidString) \(command ?? "-")") }
      }
      $0.remoteKageClient.snapshot = { _ in
        let count = snapshots.withValue {
          $0 += 1
          return $0
        }
        // The first poll after creation can miss the tab; the next one has it.
        let tabs = count == 1 ? [Fixtures.tab("t1")] : [Fixtures.tab("t1"), Fixtures.tab(newID.uuidString)]
        return Fixtures.snapshot(tabs: tabs)
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.newTab(Fixtures.selection, command: "claude"))
    #expect(store.state.pendingNewTabs.keys.contains(Fixtures.key(newID.uuidString)))
    await store.receive(\.newTabCreated)
    await store.receive(\.snapshotResponse)
    #expect(store.state.attachedTabs.isEmpty)
    await store.send(.pollTick)
    await store.receive(\.snapshotResponse)
    #expect(
      created.value == [
        "/Applications/Kage.app/Contents/Resources/bin/supacode \(Fixtures.worktreeID) \(newID.uuidString) claude"
      ])
    #expect(store.state.selection == Fixtures.selection)
    #expect(store.state.selectedTabByWorktree[Fixtures.selection] == newID.uuidString)
    #expect(store.state.attachedTabs == [Fixtures.key(newID.uuidString)])
    #expect(store.state.pendingNewTabs.isEmpty)
  }

  @Test(.dependencies) func failedNewTabShowsAnError() async {
    let store = TestStore(initialState: onlineState(tabs: [])) {
      RemoteKageFeature()
    } withDependencies: {
      $0.uuid = .constant(UUID(5))
      $0.remoteKageClient.newTab = { _, _, _, _, _ in throw RemoteKageError.kageNotRunning }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.newTab(Fixtures.selection, command: nil))
    await store.receive(\.newTabFailed)
    #expect(store.state.lastError == "Kage isn't running on the host.")
    #expect(store.state.pendingNewTabs.isEmpty)
  }
}
