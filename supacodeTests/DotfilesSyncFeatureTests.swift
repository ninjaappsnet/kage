import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct DotfilesSyncFeatureTests {
  private func state(enabled: Bool) -> DotfilesSyncFeature.State {
    let state = DotfilesSyncFeature.State()
    state.$settings.withLock { $0 = DotfilesSyncSettings(isEnabled: enabled, remoteURL: "git@github.com:me/dots.git") }
    return state
  }

  @Test(.dependencies) func enabledSyncRunsAtLaunchAndPeriodically() async {
    let clock = TestClock()
    let passes = LockIsolated<[String]>([])
    let store = TestStore(initialState: state(enabled: true)) {
      DotfilesSyncFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date = .constant(Date(timeIntervalSince1970: 1_000))
      $0[DotfilesSyncClient.self].sync = { remote, _, _ in
        passes.withValue { $0.append(remote) }
        return DotfilesSyncReport()
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.task)
    await store.receive(\.syncFinished)
    #expect(passes.value == ["git@github.com:me/dots.git"])
    #expect(store.state.lastSyncedAt == Date(timeIntervalSince1970: 1_000))

    await clock.advance(by: DotfilesSyncFeature.interval)
    await store.receive(\.syncFinished)
    #expect(passes.value.count == 2)
    await store.send(.setEnabled(false))
    await clock.advance(by: DotfilesSyncFeature.interval * 3)
    #expect(passes.value.count == 2)
  }

  @Test(.dependencies) func disabledSyncNeverRuns() async {
    let clock = TestClock()
    let passes = LockIsolated(0)
    let store = TestStore(initialState: state(enabled: false)) {
      DotfilesSyncFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0[DotfilesSyncClient.self].sync = { _, _, _ in
        passes.withValue { $0 += 1 }
        return DotfilesSyncReport()
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.task)
    await clock.advance(by: DotfilesSyncFeature.interval * 2)
    await store.send(.syncNowTapped)
    #expect(passes.value == 0)
  }

  @Test(.dependencies) func aPassInFlightIsNotStartedTwice() async {
    var initial = state(enabled: true)
    initial.isSyncing = true
    let store = TestStore(initialState: initial) { DotfilesSyncFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.syncNowTapped)
    await store.finish()
  }

  @Test(.dependencies) func problemsNotifyOnceUntilTheyChange() async {
    let sent = LockIsolated<[String]>([])
    var report = DotfilesSyncReport()
    report.blockedSecrets = ["claude/settings.json"]
    let store = TestStore(initialState: state(enabled: true)) {
      DotfilesSyncFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000))
      $0[SystemNotificationClient.self].send = { title, _, _ in sent.withValue { $0.append(title) } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.syncFinished(.success(report)))
    await store.send(.syncFinished(.success(report)))
    await store.finish()
    #expect(sent.value.count == 1)

    report.unresolved = ["claude/CLAUDE.md"]
    await store.send(.syncFinished(.success(report)))
    await store.finish()
    #expect(sent.value.count == 2)
  }

  @Test(.dependencies) func progressShowsWhileSyncingAndClearsAfter() async {
    let store = TestStore(initialState: state(enabled: true)) {
      DotfilesSyncFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000))
      $0[DotfilesSyncClient.self].sync = { _, _, progress in
        await progress(DotfilesSyncProgress(message: "Sending changes…", fraction: 0.3))
        return DotfilesSyncReport()
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.syncNowTapped)
    await store.receive(\.progress) {
      $0.progress = DotfilesSyncProgress(message: "Sending changes…", fraction: 0.3)
    }
    await store.receive(\.syncFinished)
    #expect(store.state.progress == nil)
  }

  @Test(.dependencies) func aChoiceIsSentWithTheNextPassAndClearedOnceApplied() async {
    let sent = LockIsolated<[[String: DotfilesVersionChoice]]>([])
    var initial = state(enabled: true)
    initial.conflicts = [DotfilesVersionConflict(unit: "agents/skills/tool", paths: ["agents/skills/tool/SKILL.md"])]
    let store = TestStore(initialState: initial) {
      DotfilesSyncFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000))
      $0[DotfilesSyncClient.self].sync = { _, choices, _ in
        sent.withValue { $0.append(choices) }
        var report = DotfilesSyncReport()
        report.resolvedChoices = Array(choices.keys)
        return report
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.choose(unit: "agents/skills/tool", .useRepository))
    await store.receive(\.syncFinished)
    #expect(sent.value == [["agents/skills/tool": .useRepository]])
    #expect(store.state.choices.isEmpty)
    #expect(store.state.conflicts.isEmpty)
  }

  @Test(.dependencies) func failuresAreKeptForSettings() async {
    let store = TestStore(initialState: state(enabled: true)) { DotfilesSyncFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.syncFinished(.failure(DotfilesGitError(arguments: ["fetch"], message: "denied"))))
    #expect(store.state.lastError == "git fetch failed: denied")
    #expect(store.state.isSyncing == false)
  }
}
