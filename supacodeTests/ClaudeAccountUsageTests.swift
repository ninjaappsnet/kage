import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

// MARK: - Usage payload.

struct ClaudeUsageTests {
  @Test func decodesWeeklyAndFiveHourWindows() throws {
    let json = """
      {
        "five_hour": {"utilization": 12.5, "resets_at": "2026-11-15T18:00:00.123456+00:00"},
        "seven_day": {"utilization": 41.6, "resets_at": "2026-11-16T17:00:00.450666+00:00",
                      "limit_dollars": null},
        "seven_day_opus": null,
        "extra_usage": {"is_enabled": false}
      }
      """
    let usage = try ClaudeUsage.decode(Data(json.utf8))
    #expect(usage.fiveHour?.percentUsed == 12.5)
    #expect(usage.sevenDay?.percentUsed == 41.6)
    // Microsecond fractions, which ISO8601DateFormatter alone rejects.
    let weeklyReset = try #require(usage.sevenDay?.resetsAt?.timeIntervalSince1970)
    let fiveHourReset = try #require(usage.fiveHour?.resetsAt?.timeIntervalSince1970)
    #expect(abs(weeklyReset - 1_794_848_400.450666) < 0.001)
    #expect(abs(fiveHourReset - 1_794_765_600.123456) < 0.001)
  }

  @Test func missingOrNullWindowsDecodeAsNil() throws {
    let usage = try ClaudeUsage.decode(Data(#"{"five_hour": null, "seven_day": {"utilization": 0.0}}"#.utf8))
    #expect(usage.fiveHour == nil)
    #expect(usage.sevenDay == ClaudeUsage.Window(percentUsed: 0, resetsAt: nil))
  }

  @Test func undecodablePayloadThrows() {
    #expect(throws: (any Error).self) { try ClaudeUsage.decode(Data("<html>".utf8)) }
  }

  @Test func percentLabelRoundsAndClamps() {
    #expect(ClaudeUsage.Window(percentUsed: 41.6, resetsAt: nil).percentLabel == "42%")
    #expect(ClaudeUsage.Window(percentUsed: 0.2, resetsAt: nil).percentLabel == "0%")
    #expect(ClaudeUsage.Window(percentUsed: 104, resetsAt: nil).percentLabel == "100%")
    #expect(ClaudeUsage.Window(percentUsed: -3, resetsAt: nil).percentLabel == "0%")
  }
}

// MARK: - Stored login.

struct ClaudeCredentialsTests {
  @Test func mainAccountUsesTheUnsuffixedKeychainService() {
    #expect(ClaudeCredentials.keychainService(for: .main()) == "Claude Code-credentials")
  }

  @Test func otherAccountsAreSuffixedWithTheirConfigDirectoryHash() {
    // Claude Code suffixes the service with the first 8 hex digits of
    // sha256(CLAUDE_CONFIG_DIR), the exact string it was started with.
    let account = ClaudeAccount(
      id: "work", name: "Work", configDirectoryPath: "/Users/test/.kage/claude-accounts/work")
    #expect(ClaudeCredentials.keychainService(for: account) == "Claude Code-credentials-37e3b421")
  }

  @Test func parsesTheOAuthAccessToken() {
    let json = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":1794761078000}}"#
    #expect(
      ClaudeCredentials.parseToken(json)
        == ClaudeCredentials.OAuthToken(
          accessToken: "tok", expiresAt: Date(timeIntervalSince1970: 1_794_761_078)))
  }

  @Test func tokenWithoutAccessTokenIsRejected() {
    #expect(ClaudeCredentials.parseToken(#"{"claudeAiOauth":{}}"#) == nil)
    #expect(ClaudeCredentials.parseToken("not json") == nil)
  }

  @Test func expiryIsCheckedAgainstNow() {
    let token = ClaudeCredentials.OAuthToken(accessToken: "tok", expiresAt: Date(timeIntervalSince1970: 100))
    #expect(token.isExpired(now: Date(timeIntervalSince1970: 100)))
    #expect(!token.isExpired(now: Date(timeIntervalSince1970: 99)))
    #expect(!ClaudeCredentials.OAuthToken(accessToken: "tok", expiresAt: nil).isExpired(now: .distantFuture))
  }
}

// MARK: - Reducer.

@MainActor
struct ClaudeAccountUsageFeatureTests {
  private let work = ClaudeAccount(id: "work", name: "Work", configDirectoryPath: "/tmp/kage-claude/work")
  private let weekly = ClaudeUsage(fiveHour: nil, sevenDay: .init(percentUsed: 42, resetsAt: nil))

  private func state() -> ClaudeAccountsFeature.State {
    let state = ClaudeAccountsFeature.State()
    state.$file.withLock { file in
      file = ClaudeAccountsFile()
      file.accounts = [work]
    }
    return state
  }

  @Test(.dependencies) func loggedInStatusFetchesUsage() async {
    let fetched = LockIsolated<[ClaudeAccountID]>([])
    let store = TestStore(initialState: state()) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
      $0[ClaudeAccountsClient.self].usage = { [weekly] account in
        fetched.withValue { $0.append(account.id) }
        return weekly
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.statusLoaded("work", .success(ClaudeAuthStatus(loggedIn: true))))
    await store.receive(\.usageLoaded)
    #expect(fetched.value == ["work"])
    #expect(store.state.usages["work"]?.usage == weekly)
  }

  @Test(.dependencies) func loggedOutStatusSkipsTheFetchAndDropsOldUsage() async {
    let fetched = LockIsolated(0)
    var initial = state()
    initial.usages["work"] = .init(usage: weekly, fetchedAt: Date(timeIntervalSince1970: 0))
    let store = TestStore(initialState: initial) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
      $0[ClaudeAccountsClient.self].usage = { [weekly] _ in
        fetched.withValue { $0 += 1 }
        return weekly
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.statusLoaded("work", .success(ClaudeAuthStatus(loggedIn: false))))
    await store.finish()
    #expect(fetched.value == 0)
    #expect(store.state.usages["work"] == nil)
  }

  @Test(.dependencies) func failedFetchKeepsTheLastKnownUsage() async {
    let fetchedAt = Date(timeIntervalSince1970: 0)
    var initial = state()
    initial.usages["work"] = .init(usage: weekly, fetchedAt: fetchedAt)
    let store = TestStore(initialState: initial) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
      $0[ClaudeAccountsClient.self].usage = { _ in throw ClaudeUsageError.tokenExpired }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.refreshUsage("work"))
    await store.receive(\.usageLoaded)
    #expect(store.state.usages["work"]?.usage == weekly)
  }

  @Test(.dependencies) func refreshesWithinTheMinimumIntervalAreSkipped() async {
    let fetched = LockIsolated(0)
    let now = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let store = TestStore(initialState: state()) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.date = DateGenerator { now.value }
      $0[ClaudeAccountsClient.self].usage = { [weekly] _ in
        fetched.withValue { $0 += 1 }
        return weekly
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.refreshUsage("work"))
    await store.receive(\.usageLoaded)
    await store.send(.refreshUsage("work"))
    await store.finish()
    #expect(fetched.value == 1)

    now.withValue { $0.addTimeInterval(ClaudeAccountsFeature.usageMinimumInterval + 1) }
    await store.send(.refreshUsage("work"))
    await store.receive(\.usageLoaded)
    #expect(fetched.value == 2)
  }

  @Test(.dependencies) func removingAnAccountDropsItsUsage() async {
    var initial = state()
    initial.usages["work"] = .init(usage: weekly, fetchedAt: Date(timeIntervalSince1970: 0))
    let store = TestStore(initialState: initial) { ClaudeAccountsFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.alert(.presented(.confirmRemove("work"))))
    #expect(store.state.usages["work"] == nil)
  }
}

@MainActor
struct ClaudeAccountMenuTitleTests {
  @Test func menuTitleAddsWeeklyUsageWhenKnown() {
    let work = ClaudeAccount(id: "work", name: "Work", configDirectoryPath: "/tmp/kage-claude/work")
    var state = ClaudeAccountsFeature.State()
    #expect(state.menuTitle(for: work) == "Work")
    state.usages["work"] = .init(
      usage: ClaudeUsage(fiveHour: nil, sevenDay: .init(percentUsed: 41.6, resetsAt: nil)),
      fetchedAt: Date(timeIntervalSince1970: 0))
    #expect(state.menuTitle(for: work) == "Work — 42% weekly")
  }
}
