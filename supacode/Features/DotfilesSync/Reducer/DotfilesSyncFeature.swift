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
    var lastSyncedAt: Date?
    var lastReport: DotfilesSyncReport?
    var lastError: String?
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
        let remote = state.settings.trimmedRemoteURL
        return .run { [client] send in
          await send(.syncFinished(Result { try await client.sync(remote) }))
        }
        .cancellable(id: CancelID.pass)

      case .setEnabled(let isEnabled):
        state.$settings.withLock { $0.isEnabled = isEnabled }
        guard isEnabled else { return .cancel(id: CancelID.timer) }
        return startTimer(state: state)

      case .syncFinished(.success(let report)):
        state.isSyncing = false
        state.lastSyncedAt = now
        state.lastReport = report
        state.lastError = nil
        let problems = report.blockedSecrets.map { "secret:\($0)" } + report.unresolved.map { "conflict:\($0)" }
        guard !problems.isEmpty, problems != state.notifiedProblems else {
          state.notifiedProblems = problems
          return .none
        }
        state.notifiedProblems = problems
        let message = Self.problemMessage(report)
        return .run { [notifications] _ in
          await notifications.send("Sync needs attention", message, nil)
        }

      case .syncFinished(.failure(let error)):
        state.isSyncing = false
        state.lastError = error.localizedDescription
        return .none
      }
    }
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

  static func problemMessage(_ report: DotfilesSyncReport) -> String {
    var parts: [String] = []
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
