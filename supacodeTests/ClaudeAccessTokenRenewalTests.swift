import ComposableArchitecture
import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

/// An expired access token with a valid login: Kage has Claude Code renew it
/// (`claude doctor` as the account), then fetches the usage again.
@MainActor
struct ClaudeAccessTokenRenewalTests {
  private let work = ClaudeAccount(id: "work", name: "Work", configDirectoryPath: "/tmp/kage-claude/work")
  private let weekly = ClaudeUsage(fiveHour: nil, sevenDay: .init(percentUsed: 42, resetsAt: nil))

  private func state(loggedIn: Bool = true) -> ClaudeAccountsFeature.State {
    var state = ClaudeAccountsFeature.State()
    state.$file.withLock { file in
      file = ClaudeAccountsFile()
      file.accounts = [work]
    }
    state.statuses["work"] = .loaded(ClaudeAuthStatus(loggedIn: loggedIn))
    return state
  }

  @Test(.dependencies) func anExpiredTokenIsRenewedAndTheUsageFetchedAgain() async {
    let renewed = LockIsolated<[ClaudeAccountID]>([])
    let store = TestStore(initialState: state()) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
      $0[ClaudeAccountsClient.self].usage = { [weekly] _ in
        if renewed.value.isEmpty { throw ClaudeUsageError.tokenExpired }
        return weekly
      }
      $0[ClaudeAccountsClient.self].renewAccessToken = { account in
        renewed.withValue { $0.append(account.id) }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.refreshUsage("work"))
    await store.receive(\.usageLoaded)
    await store.receive(\.accessTokenRenewed)
    // The renewal skips the once-a-minute throttle: the fetch it follows failed.
    await store.receive(\.usageLoaded)
    #expect(renewed.value == ["work"])
    #expect(store.state.usages["work"]?.usage == weekly)
    #expect(store.state.usageFailures["work"] == nil)
  }

  @Test(.dependencies) func aRenewalThatDidNotHelpIsNotRetriedWithinTheHour() async {
    let renewals = LockIsolated(0)
    let now = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let store = TestStore(initialState: state()) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.date = DateGenerator { now.value }
      $0[ClaudeAccountsClient.self].usage = { _ in throw ClaudeUsageError.tokenExpired }
      $0[ClaudeAccountsClient.self].renewAccessToken = { _ in renewals.withValue { $0 += 1 } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.refreshUsage("work"))
    await store.receive(\.usageLoaded)
    await store.receive(\.accessTokenRenewed)
    await store.receive(\.usageLoaded)
    await store.finish()
    #expect(renewals.value == 1)
    #expect(store.state.usageFailures["work"] == .tokenExpired)

    now.withValue { $0.addTimeInterval(ClaudeAccountsFeature.usageMinimumInterval + 1) }
    await store.send(.refreshUsage("work"))
    await store.receive(\.usageLoaded)
    await store.finish()
    #expect(renewals.value == 1)

    now.withValue { $0.addTimeInterval(ClaudeAccountsFeature.accessTokenRenewalInterval) }
    await store.send(.refreshUsage("work"))
    await store.receive(\.usageLoaded)
    await store.receive(\.accessTokenRenewed)
    #expect(renewals.value == 2)
  }

  @Test(.dependencies) func aLoggedOutAccountIsNeverRenewed() async {
    let store = TestStore(initialState: state(loggedIn: false)) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
      $0[ClaudeAccountsClient.self].usage = { _ in throw ClaudeUsageError.tokenExpired }
      $0[ClaudeAccountsClient.self].renewAccessToken = { _ in Issue.record("Unexpected renewal") }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.refreshUsage("work"))
    await store.receive(\.usageLoaded)
    await store.finish()
  }

  @Test(.dependencies) func otherFailuresAreNotRenewals() async {
    let store = TestStore(initialState: state()) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
      $0[ClaudeAccountsClient.self].usage = { _ in throw ClaudeUsageError.httpStatus(500) }
      $0[ClaudeAccountsClient.self].renewAccessToken = { _ in Issue.record("Unexpected renewal") }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.refreshUsage("work"))
    await store.receive(\.usageLoaded)
    await store.finish()
  }

  @Test(.dependencies) func aFailedRenewalLeavesTheReasonShowing() async {
    let store = TestStore(initialState: state()) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
      $0[ClaudeAccountsClient.self].usage = { _ in throw ClaudeUsageError.tokenExpired }
      $0[ClaudeAccountsClient.self].renewAccessToken = { _ in throw ClaudeAccountsError.claudeNotFound }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.refreshUsage("work"))
    await store.receive(\.usageLoaded)
    await store.receive(\.accessTokenRenewed)
    await store.finish()
    #expect(store.state.usageFailures["work"] == .tokenExpired)
  }
}

/// `claude doctor` is run with a time limit, so a release that waits for a
/// terminal can't leave a process behind per account.
struct ClaudeCLIRunnerTimeoutTests {
  @Test(.timeLimit(.minutes(1))) func aCommandThatOutlivesItsLimitIsTerminated() async throws {
    let clock = TestClock()
    let terminated = LockIsolated(false)
    let (events, continuation) = AsyncThrowingStream<ShellStreamEvent, Error>.makeStream()
    let process = StreamingShellProcess(events: events) {
      terminated.setValue(true)
      continuation.finish(throwing: CancellationError())
    }
    let run = Task { try await ClaudeCLIRunner.drain(process, timeout: .seconds(60), clock: clock) }
    // Let the watchdog start sleeping before time moves.
    await Task.megaYield()
    await clock.advance(by: .seconds(59))
    #expect(!terminated.value)
    await clock.advance(by: .seconds(1))
    await #expect(throws: ClaudeAccountsError.self) { try await run.value }
    #expect(terminated.value)
  }

  @Test(.timeLimit(.minutes(1))) func aCommandThatFinishesInTimeIsLeftAlone() async throws {
    let clock = TestClock()
    let terminated = LockIsolated(false)
    let (events, continuation) = AsyncThrowingStream<ShellStreamEvent, Error>.makeStream()
    let process = StreamingShellProcess(events: events) { terminated.setValue(true) }
    continuation.yield(.finished(ShellOutput(stdout: "ok", stderr: "", exitCode: 0)))
    continuation.finish()
    try await ClaudeCLIRunner.drain(process, timeout: .seconds(60), clock: clock)
    await clock.advance(by: .seconds(120))
    #expect(!terminated.value)
  }
}
