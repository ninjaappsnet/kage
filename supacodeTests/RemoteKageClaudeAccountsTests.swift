import ComposableArchitecture
import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

// MARK: - Command lines.

struct RemoteKageClaudeAccountCommandTests {
  private let tabID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

  @Test func newTabWithAnAccountAsksTheHostCLI() {
    #expect(
      RemoteKageCommand.newClaudeAccountTabArguments(
        worktreeID: "/Users/a b/repo", tabID: tabID, accountID: "work", command: "claude")
        == [
          "host", "claude-tab", "new", "-w", "%2FUsers%2Fa%20b%2Frepo", "--id", "11111111-2222-3333-4444-555555555555",
          "--account", "work", "--input=claude",
        ])
  }

  @Test func restartAsksTheHostCLI() {
    #expect(
      RemoteKageCommand.restartTabArguments(worktreeID: "/Users/a/repo", tabID: "t1", accountID: "work")
        == ["host", "claude-tab", "restart", "-w", "%2FUsers%2Fa%2Frepo", "--tab", "t1", "--account", "work"])
  }

  @Test func aHostCLIWithoutClaudeTabNeedsAnUpdate() {
    let result = RemoteKageCommandResult.classify(
      exitCode: 64,
      stdout: "",
      stderr: """
        Error: Unexpected argument 'claude-tab'
        Usage: supacode host <subcommand>
        """
    )
    #expect(result == .failure(.needsUpdate))
  }
}

// MARK: - Which accounts the menus offer.

struct RemoteKageClaudeAccountMenuTests {
  private let main = HostSnapshot.ClaudeAccountInfo(
    id: "main", name: "Main", menuTitle: "Main — 10% weekly", isDefault: true)
  private let work = HostSnapshot.ClaudeAccountInfo(id: "work", name: "Work", menuTitle: "Work", isDefault: false)

  @Test func menusAppearOnlyWithASecondAccountOnTheHost() {
    #expect(RemoteKageClaudeAccounts.menuAccounts(nil).isEmpty)
    #expect(RemoteKageClaudeAccounts.menuAccounts([main]).isEmpty)
    #expect(RemoteKageClaudeAccounts.menuAccounts([main, work]) == [main, work])
  }

  @Test func aTabsAccountIsWhatItStartedUnderElseTheHostsDefault() {
    var tab = RemoteKagePollingFixtures.tab("t1")
    #expect(RemoteKageClaudeAccounts.currentAccountID(of: tab, accounts: [main, work]) == "main")
    tab.claudeAccountID = "work"
    #expect(RemoteKageClaudeAccounts.currentAccountID(of: tab, accounts: [main, work]) == "work")
    // An account the host no longer has: the tab's account is unknown.
    tab.claudeAccountID = "gone"
    #expect(RemoteKageClaudeAccounts.currentAccountID(of: tab, accounts: [main, work]) == nil)
  }

  @Test func theTabTagNamesTheAccountOnlyWhenThereIsAChoice() {
    var tab = RemoteKagePollingFixtures.tab("t1")
    tab.claudeAccountID = "work"
    #expect(RemoteKageClaudeAccounts.tagName(of: tab, accounts: [main, work]) == "Work")
    #expect(RemoteKageClaudeAccounts.tagName(of: tab, accounts: [work]) == nil)
    tab.claudeAccountID = nil
    #expect(RemoteKageClaudeAccounts.tagName(of: tab, accounts: [main, work]) == nil)
  }
}

// MARK: - New tab and restart from this Mac.

@MainActor
struct RemoteKageClaudeAccountFeatureTests {
  private typealias Fixtures = RemoteKagePollingFixtures
  private let now = Date(timeIntervalSince1970: 1_000_000)

  private func onlineState(
    tabs: [HostSnapshot.Tab],
    _ configure: (inout RemoteKageFeature.State) -> Void = { _ in }
  ) -> RemoteKageFeature.State {
    var state = RemoteKageFeature.State()
    state.$file.withLock { $0 = RemoteKageHostsFile(hosts: [Fixtures.host]) }
    state.hostStates[Fixtures.hostID] = RemoteKageFeature.HostState(
      status: .online, lastSnapshot: Fixtures.snapshot(tabs: tabs), lastUpdated: now)
    configure(&state)
    return state
  }

  nonisolated private static func restarted(_ tab: HostSnapshot.Tab) -> HostSnapshot.Tab {
    var tab = tab
    tab.surfaceID = "surface-new"
    tab.zmxSession = "supa-new"
    tab.claudeAccountID = "work"
    return tab
  }

  @Test(.dependencies) func aNewTabWithAnAccountIsCreatedOnTheHostAndAttached() async {
    let newID = UUID(5)
    let created = LockIsolated<[String]>([])
    let store = TestStore(initialState: onlineState(tabs: [Fixtures.tab("t1")])) {
      RemoteKageFeature()
    } withDependencies: {
      $0.uuid = .constant(newID)
      $0.date = .constant(now)
      $0.remoteKageClient.newClaudeAccountTab = { _, cliPath, worktreeID, tabID, accountID, command in
        created.withValue { $0.append("\(cliPath) \(worktreeID) \(tabID.uuidString) \(accountID) \(command)") }
      }
      $0.remoteKageClient.snapshot = { _ in
        Fixtures.snapshot(tabs: [Fixtures.tab("t1"), Fixtures.tab(newID.uuidString)])
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.newTabWithClaudeAccount(Fixtures.selection, accountID: "work"))
    await store.receive(\.newTabCreated)
    await store.receive(\.snapshotResponse)
    #expect(
      created.value == [
        "/Applications/Kage.app/Contents/Resources/bin/supacode \(Fixtures.worktreeID) \(newID.uuidString) work claude"
      ])
    #expect(store.state.attachedTabs == [Fixtures.key(newID.uuidString)])
    #expect(store.state.pendingNewTabs.isEmpty)
  }

  @Test(.dependencies) func anAttachedTabIsReattachedOnceItsRestartedSessionShowsUp() async {
    let clock = TestClock()
    let old = Fixtures.tab("t1")
    let requests = LockIsolated<[String]>([])
    let snapshots = LockIsolated(0)
    let store = TestStore(initialState: onlineState(tabs: [old]) { $0.attachedTabs = [Fixtures.key("t1")] }) {
      RemoteKageFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date = .constant(now)
      $0.remoteKageClient.restartTab = { _, cliPath, worktreeID, tabID, accountID in
        requests.withValue { $0.append("\(cliPath) \(worktreeID) \(tabID) \(accountID)") }
      }
      $0.remoteKageClient.snapshot = { [old] _ in
        let count = snapshots.withValue {
          $0 += 1
          return $0
        }
        // The first poll can still see the old session.
        return Fixtures.snapshot(tabs: [count == 1 ? old : Self.restarted(old)])
      }
      $0.remoteKageClient.screen = { _, _, _ in "" }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.restartTab(Fixtures.key("t1"), accountID: "work"))
    #expect(store.state.pendingRestarts[Fixtures.key("t1")] != nil)
    await store.receive(\.restartTabSent)
    await store.receive(\.snapshotResponse)
    // The old session ended under the attached terminal, which detached.
    await store.send(.detachTab(Fixtures.key("t1")))
    #expect(store.state.pendingRestarts[Fixtures.key("t1")] != nil)
    await store.send(.pollTick)
    await store.receive(\.snapshotResponse)
    #expect(store.state.pendingRestarts.isEmpty)
    #expect(store.state.attachedTabs.isEmpty)
    await clock.advance(by: RemoteKageFeature.restartReattachDelay)
    await store.receive(\.attachTab)
    #expect(store.state.attachedTabs == [Fixtures.key("t1")])
    #expect(requests.value == ["/Applications/Kage.app/Contents/Resources/bin/supacode \(Fixtures.worktreeID) t1 work"])
  }

  @Test(.dependencies) func aTabThatWasNotAttachedStaysAPreview() async {
    let clock = TestClock()
    let old = Fixtures.tab("t1")
    let store = TestStore(initialState: onlineState(tabs: [old])) {
      RemoteKageFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date = .constant(now)
      $0.remoteKageClient.restartTab = { _, _, _, _, _ in }
      $0.remoteKageClient.snapshot = { [old] _ in Fixtures.snapshot(tabs: [Self.restarted(old)]) }
      $0.remoteKageClient.screen = { _, _, _ in "" }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.restartTab(Fixtures.key("t1"), accountID: "work"))
    await store.receive(\.restartTabSent)
    await store.receive(\.snapshotResponse)
    await clock.advance(by: RemoteKageFeature.restartReattachDelay)
    await store.finish()
    #expect(store.state.pendingRestarts.isEmpty)
    #expect(store.state.attachedTabs.isEmpty)
  }

  @Test(.dependencies) func aFailedRestartShowsWhy() async {
    let store = TestStore(initialState: onlineState(tabs: [Fixtures.tab("t1")])) {
      RemoteKageFeature()
    } withDependencies: {
      $0.remoteKageClient.restartTab = { _, _, _, _, _ in throw RemoteKageError.needsUpdate }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.restartTab(Fixtures.key("t1"), accountID: "work"))
    await store.receive(\.restartTabFailed)
    #expect(store.state.lastError == "The host's Kage is too old. Update Kage on that Mac.")
    #expect(store.state.pendingRestarts.isEmpty)
  }

  @Test(.dependencies) func aRestartTheHostNeverCarriesOutGivesUp() async {
    let old = Fixtures.tab("t1")
    let store = TestStore(initialState: onlineState(tabs: [old])) {
      RemoteKageFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0.remoteKageClient.restartTab = { _, _, _, _, _ in }
      $0.remoteKageClient.snapshot = { [old] _ in Fixtures.snapshot(tabs: [old]) }
      $0.remoteKageClient.screen = { _, _, _ in "" }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.restartTab(Fixtures.key("t1"), accountID: "work"))
    await store.receive(\.restartTabSent)
    await store.receive(\.snapshotResponse)
    for _ in 1..<RemoteKageFeature.newTabSnapshotLimit {
      await store.send(.snapshotResponse(Fixtures.hostID, .success(Fixtures.snapshot(tabs: [old]))))
    }
    #expect(store.state.pendingRestarts.isEmpty)
    #expect(store.state.lastError == "The tab didn't restart on Mini.")
  }

  @Test(.dependencies) func aTabNotInTheSnapshotCannotBeRestarted() async {
    let store = TestStore(initialState: onlineState(tabs: [Fixtures.tab("t1")])) { RemoteKageFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.restartTab(Fixtures.key("gone"), accountID: "work"))
    #expect(store.state.pendingRestarts.isEmpty)
  }
}
