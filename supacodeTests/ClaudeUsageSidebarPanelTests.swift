import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

struct ClaudeUsageRemainingTests {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  private func window(resetsIn seconds: TimeInterval?) -> ClaudeUsage.Window {
    ClaudeUsage.Window(percentUsed: 10, resetsAt: seconds.map { now.addingTimeInterval($0) })
  }

  @Test func daysHoursAndMinutes() {
    #expect(window(resetsIn: 2 * 86_400 + 5 * 3_600 + 12 * 60).timeUntilReset(now: now) == "2d 5h 12m")
  }

  @Test func zeroMiddleUnitsAreKept() {
    #expect(window(resetsIn: 86_400 + 7 * 60).timeUntilReset(now: now) == "1d 0h 7m")
  }

  @Test func underADayDropsDays() {
    #expect(window(resetsIn: 5 * 3_600 + 3 * 60).timeUntilReset(now: now) == "5h 3m")
  }

  @Test func underAnHourShowsMinutesOnly() {
    #expect(window(resetsIn: 12 * 60 + 59).timeUntilReset(now: now) == "12m")
  }

  @Test func lastMinute() {
    #expect(window(resetsIn: 30).timeUntilReset(now: now) == "<1m")
  }

  @Test func nothingWithoutAFutureReset() {
    #expect(window(resetsIn: nil).timeUntilReset(now: now) == nil)
    #expect(window(resetsIn: -5).timeUntilReset(now: now) == nil)
  }
}

@MainActor
struct ClaudeUsageSidebarPanelRefreshTests {
  private let work = ClaudeAccount(id: "work", name: "Work", configDirectoryPath: "/tmp/kage-claude/work")
  private let weekly = ClaudeUsage(fiveHour: nil, sevenDay: .init(percentUsed: 42, resetsAt: nil))

  private func state() -> ClaudeAccountsFeature.State {
    var state = ClaudeAccountsFeature.State()
    state.$file.withLock { file in
      file = ClaudeAccountsFile()
      file.accounts = [work]
    }
    state.statuses[ClaudeAccount.mainID] = .loaded(ClaudeAuthStatus(loggedIn: false))
    state.statuses["work"] = .loaded(ClaudeAuthStatus(loggedIn: true))
    return state
  }

  @Test(.dependencies) func visiblePanelRefreshesLoggedInAccountsPeriodically() async {
    let clock = TestClock()
    let fetched = LockIsolated<[ClaudeAccountID]>([])
    let now = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let store = TestStore(initialState: state()) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date = DateGenerator { now.value }
      $0[ClaudeAccountsClient.self].usage = { [weekly] account in
        fetched.withValue { $0.append(account.id) }
        return weekly
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.usagePanelAppeared)
    await store.receive(\.usageLoaded)
    #expect(fetched.value == ["work"])

    now.withValue { $0.addTimeInterval(5 * 60) }
    await clock.advance(by: ClaudeAccountsFeature.usagePanelRefreshInterval)
    await store.receive(\.usageLoaded)
    #expect(fetched.value == ["work", "work"])

    await store.send(.usagePanelDisappeared)
    await clock.advance(by: ClaudeAccountsFeature.usagePanelRefreshInterval * 3)
    await store.finish()
    #expect(fetched.value == ["work", "work"])
  }
}

struct SidebarBottomCardAnnouncementTests {
  @Test func featureAnnouncementsAreSuppressed() {
    #expect(SidebarBottomCardView.Slot.layoutModes.withoutAnnouncements == .none)
    #expect(SidebarBottomCardView.Slot.fileExplorerBeta.withoutAnnouncements == .none)
  }

  @Test func actionableCardsStay() {
    #expect(SidebarBottomCardView.Slot.agent(.promptInstall).withoutAnnouncements == .agent(.promptInstall))
    #expect(SidebarBottomCardView.Slot.none.withoutAnnouncements == .none)
  }
}
