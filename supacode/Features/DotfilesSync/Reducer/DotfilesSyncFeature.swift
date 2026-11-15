import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Settings → Sync: keeps Claude Code, Codex and Kage settings plus per-project
/// Claude memory in sync between machines through a private git repository.
/// Passes run at launch, every `interval`, and on demand; see `DotfilesSyncEngine`.
@Reducer
struct DotfilesSyncFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.dotfilesSyncSettings) var settings = DotfilesSyncSettings()
    var isSyncing = false
    /// What the running pass is doing, with its progress bar fraction.
    var progress: DotfilesSyncProgress?
    var lastSyncedAt: Date?
    var lastReport: DotfilesSyncReport?
    var lastError: String?
    /// Skills and files whose copies differ, waiting for the user's choice.
    var conflicts: [DotfilesVersionConflict] = []
    /// Choices made but not yet applied by a pass.
    var choices: [String: DotfilesVersionChoice] = [:]
    /// Problems already notified about, so the same one isn't announced every pass.
    var notifiedProblems: [String] = []

    var canSync: Bool { settings.isEnabled && !settings.trimmedRemoteURL.isEmpty }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case tick
    case setEnabled(Bool)
    case syncNowTapped
    case syncFinished(Result<DotfilesSyncReport, Error>)
    case progress(DotfilesSyncProgress)
    /// Keep one side of a conflict (`unit` is a skill folder or a file).
    case choose(unit: String, DotfilesVersionChoice)
    case chooseAll(DotfilesVersionChoice)
  }

  nonisolated static let interval: Duration = .seconds(2 * 60)

  private nonisolated enum CancelID: Hashable, Sendable {
    case timer
    case pass
  }

  @Dependency(DotfilesSyncClient.self) private var client
  @Dependency(SystemNotificationClient.self) private var notifications
  @Dependency(\.continuousClock) private var clock
  @Dependency(\.date.now) private var now

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        return startTimer(state: state)

      case .tick, .syncNowTapped:
        guard state.canSync, !state.isSyncing else { return .none }
        state.isSyncing = true
        state.progress = DotfilesSyncProgress(message: "Starting…", fraction: 0)
        let remote = state.settings.trimmedRemoteURL
        let choices = state.choices
        return .run { [client] send in
          let report = await Result {
            try await client.sync(remote, choices) { progress in await send(.progress(progress)) }
          }
          await send(.syncFinished(report))
        }
        .cancellable(id: CancelID.pass)

      case .progress(let progress):
        guard state.isSyncing else { return .none }
        state.progress = progress
        return .none

      case .setEnabled(let isEnabled):
        state.$settings.withLock { $0.isEnabled = isEnabled }
        guard isEnabled else { return .cancel(id: CancelID.timer) }
        return startTimer(state: state)

      case .choose(let unit, let choice):
        state.choices[unit] = choice
        state.conflicts.removeAll { $0.unit == unit }
        return .send(.syncNowTapped)

      case .chooseAll(let choice):
        for conflict in state.conflicts { state.choices[conflict.unit] = choice }
        state.conflicts = []
        return .send(.syncNowTapped)

      case .syncFinished(.success(let report)):
        return finish(&state, report: report)

      case .syncFinished(.failure(let error)):
        state.isSyncing = false
        state.progress = nil
        state.lastError = error.localizedDescription
        return .none
      }
    }
  }

  private func finish(_ state: inout State, report: DotfilesSyncReport) -> Effect<Action> {
    state.isSyncing = false
    state.progress = nil
    state.lastSyncedAt = now
    state.lastReport = report
    state.lastError = nil
    for unit in report.resolvedChoices { state.choices[unit] = nil }
    state.conflicts = report.versionConflicts.filter { state.choices[$0.unit] == nil }
    // A choice made while this pass ran is applied right away.
    let rerun: Effect<Action> = state.choices.isEmpty ? .none : .send(.syncNowTapped)
    let problems =
      report.blockedSecrets.map { "secret:\($0)" } + report.unresolved.map { "conflict:\($0)" }
      + state.conflicts.map { "choice:\($0.unit)" }
    guard !problems.isEmpty, problems != state.notifiedProblems else {
      state.notifiedProblems = problems
      return rerun
    }
    state.notifiedProblems = problems
    let message = Self.problemMessage(report, choices: state.conflicts.count)
    return .merge(
      rerun,
      .run { [notifications] _ in
        await notifications.send("Sync needs attention", message, nil)
      }
    )
  }

  /// Syncs now, then every `interval`, while enabled with a remote set.
  private func startTimer(state: State) -> Effect<Action> {
    guard state.canSync else { return .none }
    return .run { [clock] send in
      await send(.tick)
      for await _ in clock.timer(interval: Self.interval) {
        await send(.tick)
      }
    }
    .cancellable(id: CancelID.timer, cancelInFlight: true)
  }

  static func problemMessage(_ report: DotfilesSyncReport, choices: Int = 0) -> String {
    var parts: [String] = []
    if choices > 0 {
      let items = choices == 1 ? "1 item differs" : "\(choices) items differ"
      parts.append("\(items) between Macs: choose which to keep in Settings → Sync.")
    }
    if !report.blockedSecrets.isEmpty {
      parts.append("Not synced, may contain a secret: \(report.blockedSecrets.joined(separator: ", ")).")
    }
    if !report.unresolved.isEmpty {
      let files = report.unresolved.joined(separator: ", ")
      parts.append("Kept this Mac's copy of \(files); the other copy is in ~/.kage/dotfiles-conflicts.")
    }
    return parts.joined(separator: " ")
  }
}
