import Combine
import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Remote Kage hosts: other Macs running Kage whose projects and sessions this
/// Mac shows in the sidebar and can attach to. See
/// `docs/plans/remote-kage-hosts.md`.
///
/// Contract (shared by the sidebar/detail views and this reducer):
/// - `hostStates` has one entry per configured host once `.task` ran; a host's
///   last good snapshot is kept while it is offline, so the sidebar keeps its rows.
/// - `select` sets `selection` (nil clears it). The sidebar sends it when a
///   remote worktree row is chosen, and `select(nil)` when a local row is.
/// - `selectTab` records the shown tab for a remote worktree and refreshes that
///   tab's screen preview unless it is attached.
/// - `attachTab` / `detachTab` add / remove the tab in `attachedTabs`; the detail
///   view shows a live terminal exactly for the tabs in that set.
/// - `quickAnswer` types `text` into the session without attaching, then
///   refreshes its screen.
/// - `newTab` creates a tab on the host, then re-polls that host and selects
///   and attaches the new tab once it appears.
///
/// Polling (`.task`): every host is fetched at once and then on every 5 s
/// `pollTick`, never twice at a time; a failing host backs off
/// (`RemoteKagePollSchedule`). Edits to `remote-hosts.json` start / stop a
/// host's polling immediately. A tab that turns `awaitingInput` between two
/// snapshots posts one notification unless it is attached and on screen.
@Reducer
struct RemoteKageFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.remoteKageHostsFile) var file = RemoteKageHostsFile()
    var hostStates: [RemoteKageHost.ID: HostState] = [:]
    var selection: RemoteKageSelection?
    /// The tab the detail shows, per remote worktree.
    var selectedTabByWorktree: [RemoteKageSelection: String] = [:]
    /// Tabs with a live attached terminal on this Mac.
    var attachedTabs: Set<RemoteKageTabKey> = []
    /// Last screen preview fetched per tab.
    var screens: [RemoteKageTabKey: String] = [:]
    var settings = RemoteKageSettingsFeature.State()
    /// The last quick answer / new tab failure, for the detail view to show
    /// until `dismissError`.
    var lastError: String?
    /// Tabs requested with `newTab` that the host hasn't reported yet.
    var pendingNewTabs: [RemoteKageTabKey: PendingNewTab] = [:]
    /// Tabs asked to restart (`restartTab`) whose new session the host hasn't reported yet.
    var pendingRestarts: [RemoteKageTabKey: PendingRestart] = [:]

    // Polling bookkeeping. Changes on every tick and no view reads it, so it
    // stays out of observation.
    @ObservationStateIgnored var polledHosts: [RemoteKageHost.ID: RemoteKageHost] = [:]
    @ObservationStateIgnored var snapshotsInFlight: Set<RemoteKageHost.ID> = []
    @ObservationStateIgnored var pollSchedules: [RemoteKageHost.ID: RemoteKagePollSchedule] = [:]
    @ObservationStateIgnored var screensInFlight: Set<RemoteKageTabKey> = []

    var hosts: [RemoteKageHost] { file.hosts }

    func host(_ id: RemoteKageHost.ID) -> RemoteKageHost? {
      file.hosts.first { $0.id == id }
    }

    func snapshot(for hostID: RemoteKageHost.ID) -> HostSnapshot? {
      hostStates[hostID]?.lastSnapshot
    }

    func worktree(for selection: RemoteKageSelection) -> HostSnapshot.Worktree? {
      snapshot(for: selection.hostID)?.repositories
        .lazy
        .flatMap(\.worktrees)
        .first { $0.id == selection.worktreeID }
    }

    func tab(for key: RemoteKageTabKey) -> HostSnapshot.Tab? {
      snapshot(for: key.hostID)?.repositories
        .lazy
        .flatMap(\.worktrees)
        .flatMap(\.tabs)
        .first { $0.id == key.tabID }
    }

    /// The tab the detail currently shows: the selected worktree's selected tab.
    var shownTab: RemoteKageTabKey? {
      guard let selection, let tabID = selectedTabByWorktree[selection] else { return nil }
      return RemoteKageTabKey(hostID: selection.hostID, tabID: tabID)
    }

    /// Shown and attached: the user is looking at its live terminal.
    func isWatching(_ key: RemoteKageTabKey) -> Bool {
      shownTab == key && attachedTabs.contains(key)
    }
  }

  struct PendingNewTab: Equatable, Sendable {
    var selection: RemoteKageSelection
    var snapshotsWaited = 0
  }

  struct PendingRestart: Equatable, Sendable {
    /// The session the restart ends; a different one in a snapshot is the new session.
    var oldSession: String?
    /// The tab was attached here when the restart was asked for.
    var reattach: Bool
    var snapshotsWaited = 0
  }

  /// Wait after the new session appears before attaching, so the host's zmx has it listed.
  static let restartReattachDelay: Duration = .seconds(1)

  static let pollInterval = RemoteKagePollSchedule.tickInterval
  /// How long after a quick answer the screen is re-read, so it shows the reaction.
  static let quickAnswerRefreshDelay: Duration = .milliseconds(300)
  /// Snapshots to wait for a requested tab before giving up on it (about a minute).
  static let newTabSnapshotLimit = 12

  struct HostState: Equatable, Sendable {
    var status: HostStatus = .connecting
    /// Last good snapshot, kept across failures.
    var lastSnapshot: HostSnapshot?
    var lastUpdated: Date?
  }

  enum HostStatus: Equatable, Sendable {
    case connecting
    case online
    case offline(String)
    case kageNotRunning
    case needsUpdate
  }

  enum Action: Equatable {
    case task
    case hostsFileChanged
    case pollTick
    case snapshotResponse(RemoteKageHost.ID, Result<HostSnapshot, RemoteKageError>)
    case select(RemoteKageSelection?)
    case selectTab(RemoteKageSelection, tabID: String)
    case attachTab(RemoteKageTabKey)
    case detachTab(RemoteKageTabKey)
    case refreshScreen(RemoteKageTabKey)
    case screenResponse(RemoteKageTabKey, Result<String, RemoteKageError>)
    case quickAnswer(RemoteKageTabKey, text: String)
    case quickAnswerFailed(RemoteKageTabKey, RemoteKageError)
    case newTab(RemoteKageSelection, command: String?)
    case newTabFailed(RemoteKageSelection, RemoteKageError)
    case settings(RemoteKageSettingsFeature.Action)
    case newTabCreated(RemoteKageTabKey)
    case dismissError
    /// A tab on the host whose Claude Code runs as one of the host's accounts.
    case newTabWithClaudeAccount(RemoteKageSelection, accountID: String)
    /// Restart a host tab under one of the host's accounts (confirmed by the view).
    case restartTab(RemoteKageTabKey, accountID: String)
    case restartTabSent(RemoteKageTabKey)
    case restartTabFailed(RemoteKageTabKey, RemoteKageError)
  }

  nonisolated enum CancelID: Hashable, Sendable {
    case polling
    case snapshot(RemoteKageHost.ID)
    case screen(RemoteKageTabKey)
  }

  private static let logger = SupaLogger("RemoteKage")

  @Dependency(\.remoteKageClient) private var client
  @Dependency(\.continuousClock) private var clock
  @Dependency(\.date.now) private var now
  @Dependency(\.uuid) private var uuid
  @Dependency(SystemNotificationClient.self) private var notifications
  @Dependency(NotificationSoundClient.self) private var notificationSound

  var body: some Reducer<State, Action> {
    Scope(state: \.settings, action: \.settings) {
      RemoteKageSettingsFeature()
    }
    Reduce { state, action in
      switch action {
      case .task:
        return .merge(syncHosts(&state), startPolling(state))

      case .hostsFileChanged:
        return syncHosts(&state)

      case .pollTick:
        return pollTick(&state)

      case .snapshotResponse(let hostID, let result):
        return snapshotResponse(hostID, result, &state)

      case .select(let selection):
        return select(selection, &state)

      case .selectTab(let selection, let tabID):
        if state.selectedTabByWorktree[selection] != tabID {
          state.selectedTabByWorktree[selection] = tabID
        }
        let key = RemoteKageTabKey(hostID: selection.hostID, tabID: tabID)
        return state.attachedTabs.contains(key) ? .none : refreshScreen(key, &state)

      case .attachTab(let key):
        state.attachedTabs.insert(key)
        state.screensInFlight.remove(key)
        return .cancel(id: CancelID.screen(key))

      case .detachTab(let key):
        guard state.attachedTabs.remove(key) != nil else { return .none }
        // The preview takes over again; show what the session looks like now.
        return refreshScreen(key, &state)

      case .refreshScreen(let key):
        return refreshScreen(key, &state)

      case .screenResponse(let key, let result):
        state.screensInFlight.remove(key)
        guard state.host(key.hostID) != nil else { return .none }
        switch result {
        case .success(let screen):
          if state.screens[key] != screen {
            state.screens[key] = screen
          }
        case .failure(let error):
          Self.logger.warning("Screen of tab \(key.tabID) failed: \(error.localizedDescription)")
        }
        return .none

      case .quickAnswer(let key, let text):
        return quickAnswer(key, text: text, &state)

      case .quickAnswerFailed(_, let error):
        state.lastError = error.localizedDescription
        return .none

      case .newTab(let selection, let command):
        return newTab(selection, command: command, &state)

      case .newTabCreated(let key):
        // Re-poll now (dropping a poll that may predate the tab) so it shows up fast.
        return fetchSnapshot(key.hostID, &state)

      case .newTabFailed(let selection, let error):
        for key in state.pendingNewTabs.keys where state.pendingNewTabs[key]?.selection == selection {
          state.pendingNewTabs[key] = nil
        }
        state.lastError = error.localizedDescription
        return .none

      case .dismissError:
        state.lastError = nil
        return .none

      case .settings:
        return .none

      case .newTabWithClaudeAccount(let selection, let accountID):
        return newTab(selection, command: "claude", claudeAccountID: accountID, &state)

      case .restartTab(let key, let accountID):
        return restartTab(key, accountID: accountID, &state)

      case .restartTabSent(let key):
        // Re-poll now so the new session shows up fast.
        return fetchSnapshot(key.hostID, &state)

      case .restartTabFailed(let key, let error):
        state.pendingRestarts[key] = nil
        state.lastError = error.localizedDescription
        return .none
      }
    }
  }

  // MARK: - Polling.

  private func startPolling(_ state: State) -> Effect<Action> {
    let file = state.$file
    return .merge(
      .run { [clock] send in
        while true {
          try await clock.sleep(for: Self.pollInterval)
          await send(.pollTick)
        }
      },
      .run { send in
        // `publisher` replays the current value first; only later edits matter.
        for await _ in file.publisher.map(\.hosts).removeDuplicates().dropFirst().values {
          await send(.hostsFileChanged)
        }
      }
    )
    .cancellable(id: CancelID.polling, cancelInFlight: true)
  }

  /// Aligns polling with the hosts file: new hosts are fetched at once,
  /// removed ones (and ones whose address or login changed) are forgotten.
  private func syncHosts(_ state: inout State) -> Effect<Action> {
    let hosts = state.hosts
    let hostsByID = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var effects: [Effect<Action>] = []
    for (id, polled) in state.polledHosts {
      guard let host = hostsByID[id], host.address == polled.address, host.username == polled.username else {
        effects.append(forget(id, &state))
        continue
      }
      if host != polled {
        state.polledHosts[id] = host
      }
    }
    for host in hosts where state.polledHosts[host.id] == nil {
      state.polledHosts[host.id] = host
      state.pollSchedules[host.id] = RemoteKagePollSchedule()
      if state.hostStates[host.id] == nil {
        state.hostStates[host.id] = HostState()
      }
      effects.append(fetchSnapshot(host.id, &state))
    }
    return .merge(effects)
  }

  /// Drops everything this Mac holds for a host and stops its requests.
  private func forget(_ hostID: RemoteKageHost.ID, _ state: inout State) -> Effect<Action> {
    state.polledHosts[hostID] = nil
    state.pollSchedules[hostID] = nil
    state.snapshotsInFlight.remove(hostID)
    if state.hostStates[hostID] != nil {
      state.hostStates[hostID] = nil
    }
    if state.selection?.hostID == hostID {
      state.selection = nil
    }
    for selection in state.selectedTabByWorktree.keys where selection.hostID == hostID {
      state.selectedTabByWorktree[selection] = nil
    }
    for key in state.attachedTabs where key.hostID == hostID {
      state.attachedTabs.remove(key)
    }
    for key in state.screens.keys where key.hostID == hostID {
      state.screens[key] = nil
    }
    for key in state.pendingNewTabs.keys where key.hostID == hostID {
      state.pendingNewTabs[key] = nil
    }
    for key in state.pendingRestarts.keys where key.hostID == hostID {
      state.pendingRestarts[key] = nil
    }
    let screenFetches = state.screensInFlight.filter { $0.hostID == hostID }
    state.screensInFlight.subtract(screenFetches)
    return .merge(
      [.cancel(id: CancelID.snapshot(hostID))] + screenFetches.map { .cancel(id: CancelID.screen($0)) }
    )
  }

  private func pollTick(_ state: inout State) -> Effect<Action> {
    var effects: [Effect<Action>] = []
    for host in state.hosts where !state.snapshotsInFlight.contains(host.id) {
      var schedule = state.pollSchedules[host.id] ?? RemoteKagePollSchedule()
      let isDue = schedule.consumeTick()
      state.pollSchedules[host.id] = schedule
      if isDue {
        effects.append(fetchSnapshot(host.id, &state))
      }
    }
    if let key = state.shownTab,
      !state.attachedTabs.contains(key),
      !state.screensInFlight.contains(key),
      state.hostStates[key.hostID]?.status == .online
    {
      effects.append(refreshScreen(key, &state))
    }
    return .merge(effects)
  }

  private func fetchSnapshot(_ hostID: RemoteKageHost.ID, _ state: inout State) -> Effect<Action> {
    guard let host = state.host(hostID) else { return .none }
    state.snapshotsInFlight.insert(hostID)
    return .run { [client] send in
      do {
        await send(.snapshotResponse(hostID, .success(try await client.snapshot(host))))
      } catch is CancellationError {
        return
      } catch {
        await send(.snapshotResponse(hostID, .failure(.wrapping(error))))
      }
    }
    .cancellable(id: CancelID.snapshot(hostID), cancelInFlight: true)
  }

  private func snapshotResponse(
    _ hostID: RemoteKageHost.ID,
    _ result: Result<HostSnapshot, RemoteKageError>,
    _ state: inout State
  ) -> Effect<Action> {
    guard let host = state.host(hostID) else { return .none }
    state.snapshotsInFlight.remove(hostID)
    var hostState = state.hostStates[hostID] ?? HostState()
    switch result {
    case .failure(let error):
      state.pollSchedules[hostID, default: RemoteKagePollSchedule()].recordFailure()
      hostState.status = HostStatus(error)
      if state.hostStates[hostID] != hostState {
        state.hostStates[hostID] = hostState
        Self.logger.info("Remote host \(host.name) is unavailable: \(error.localizedDescription)")
      }
      return .none

    case .success(let snapshot):
      state.pollSchedules[hostID, default: RemoteKagePollSchedule()].recordSuccess()
      let previous = hostState.lastSnapshot
      hostState.status = .online
      if previous != snapshot {
        hostState.lastSnapshot = snapshot
      }
      hostState.lastUpdated = now
      state.hostStates[hostID] = hostState
      pruneVanishedTabs(of: hostID, in: snapshot, &state)
      resolvePendingNewTabs(of: host, in: snapshot, &state)
      let reattach = resolvePendingRestarts(of: host, in: snapshot, &state)
      return .merge(reattach, notifyNewlyAwaiting(host: host, previous: previous, current: snapshot, state: state))
    }
  }

  /// A tab closed on the host takes its terminal, preview and selection with it.
  private func pruneVanishedTabs(of hostID: RemoteKageHost.ID, in snapshot: HostSnapshot, _ state: inout State) {
    let tabIDs = RemoteKageSnapshotDiff.tabIDs(in: snapshot)
    let isGone = { (key: RemoteKageTabKey) in key.hostID == hostID && !tabIDs.contains(key.tabID) }
    for key in state.attachedTabs where isGone(key) {
      state.attachedTabs.remove(key)
    }
    for key in state.screens.keys where isGone(key) {
      state.screens[key] = nil
    }
    for (selection, tabID) in state.selectedTabByWorktree
    where selection.hostID == hostID && !tabIDs.contains(tabID) {
      state.selectedTabByWorktree[selection] = nil
    }
  }

  private func resolvePendingNewTabs(of host: RemoteKageHost, in snapshot: HostSnapshot, _ state: inout State) {
    for (key, pending) in state.pendingNewTabs where key.hostID == host.id {
      if let location = RemoteKageSnapshotDiff.location(ofTab: key.tabID, in: snapshot) {
        state.pendingNewTabs[key] = nil
        let selection = RemoteKageSelection(hostID: host.id, worktreeID: location.worktreeID)
        state.selection = selection
        state.selectedTabByWorktree[selection] = location.tab.id
        state.attachedTabs.insert(RemoteKageTabKey(hostID: host.id, tabID: location.tab.id))
      } else if pending.snapshotsWaited + 1 >= Self.newTabSnapshotLimit {
        state.pendingNewTabs[key] = nil
        state.lastError = "The new tab didn't appear on \(host.name)."
      } else {
        state.pendingNewTabs[key]?.snapshotsWaited += 1
      }
    }
  }

  /// One notification per tab that started waiting for input, honoring the
  /// app's notification settings (system notification, else the sound).
  private func notifyNewlyAwaiting(
    host: RemoteKageHost,
    previous: HostSnapshot?,
    current: HostSnapshot,
    state: State
  ) -> Effect<Action> {
    let awaiting = RemoteKageSnapshotDiff.newlyAwaitingTabs(previous: previous, current: current)
      .filter { !state.isWatching(RemoteKageTabKey(hostID: host.id, tabID: $0.tab.id)) }
    guard !awaiting.isEmpty else { return .none }
    @Shared(.settingsFile) var settingsFile
    let settings = settingsFile.global
    if settings.systemNotificationsEnabled {
      let messages = awaiting.map {
        (title: "\(host.name) · \($0.repositoryName)", body: "\($0.tab.title) is waiting for input")
      }
      return .run { [notifications] _ in
        for message in messages {
          await notifications.send(message.title, message.body, nil)
        }
      }
    }
    let sound = settings.notificationSound
    guard sound != .never else { return .none }
    return .run { [notificationSound] _ in
      await notificationSound.play(sound)
    }
  }

  // MARK: - Selection and screens.

  private func select(_ selection: RemoteKageSelection?, _ state: inout State) -> Effect<Action> {
    if state.selection != selection {
      state.selection = selection
    }
    guard let selection else { return .none }
    if state.selectedTabByWorktree[selection] == nil,
      let worktree = state.worktree(for: selection),
      let tab = worktree.tabs.first(where: \.isFocused) ?? worktree.tabs.first
    {
      state.selectedTabByWorktree[selection] = tab.id
    }
    guard let key = state.shownTab, !state.attachedTabs.contains(key) else { return .none }
    return refreshScreen(key, &state)
  }

  private func refreshScreen(_ key: RemoteKageTabKey, _ state: inout State) -> Effect<Action> {
    guard let host = state.host(key.hostID),
      let zmxPath = state.snapshot(for: key.hostID)?.zmxPath,
      let session = state.tab(for: key)?.zmxSession
    else { return .none }
    state.screensInFlight.insert(key)
    return .run { [client] send in
      do {
        await send(.screenResponse(key, .success(try await client.screen(host, zmxPath, session))))
      } catch is CancellationError {
        return
      } catch {
        await send(.screenResponse(key, .failure(.wrapping(error))))
      }
    }
    .cancellable(id: CancelID.screen(key), cancelInFlight: true)
  }

  // MARK: - Input and new tabs.

  private func quickAnswer(_ key: RemoteKageTabKey, text: String, _ state: inout State) -> Effect<Action> {
    guard let host = state.host(key.hostID),
      let zmxPath = state.snapshot(for: key.hostID)?.zmxPath,
      let session = state.tab(for: key)?.zmxSession
    else {
      state.lastError = "This tab can't take input from this Mac."
      return .none
    }
    return .run { [client, clock] send in
      do {
        try await client.send(host, zmxPath, session, text)
        try await clock.sleep(for: Self.quickAnswerRefreshDelay)
        await send(.refreshScreen(key))
      } catch is CancellationError {
        return
      } catch {
        await send(.quickAnswerFailed(key, .wrapping(error)))
      }
    }
  }

  private func newTab(
    _ selection: RemoteKageSelection,
    command: String?,
    claudeAccountID: String? = nil,
    _ state: inout State
  ) -> Effect<Action> {
    guard let host = state.host(selection.hostID) else { return .none }
    let tabID = uuid()
    let key = RemoteKageTabKey(hostID: host.id, tabID: tabID.uuidString)
    state.pendingNewTabs[key] = PendingNewTab(selection: selection)
    let reportedCLIPath = state.snapshot(for: host.id)?.cliPath ?? ""
    let cliPath = reportedCLIPath.isEmpty ? RemoteKageCommand.defaultCLIPath : reportedCLIPath
    return .run { [client] send in
      do {
        if let claudeAccountID {
          try await client.newClaudeAccountTab(
            host, cliPath, selection.worktreeID, tabID, claudeAccountID, command ?? "claude")
        } else {
          try await client.newTab(host, cliPath, selection.worktreeID, tabID, command)
        }
        await send(.newTabCreated(key))
      } catch is CancellationError {
        return
      } catch {
        await send(.newTabFailed(selection, .wrapping(error)))
      }
    }
  }
}

// MARK: - Restart under a host account.

extension RemoteKageFeature {
  private func restartTab(_ key: RemoteKageTabKey, accountID: String, _ state: inout State) -> Effect<Action> {
    guard let host = state.host(key.hostID),
      let snapshot = state.snapshot(for: key.hostID),
      let location = RemoteKageSnapshotDiff.location(ofTab: key.tabID, in: snapshot)
    else { return .none }
    state.pendingRestarts[key] = PendingRestart(
      oldSession: location.tab.zmxSession,
      reattach: state.attachedTabs.contains(key)
    )
    let cliPath = (snapshot.cliPath ?? "").isEmpty ? RemoteKageCommand.defaultCLIPath : snapshot.cliPath ?? ""
    return .run { [client] send in
      do {
        try await client.restartTab(host, cliPath, location.worktreeID, location.tab.id, accountID)
        await send(.restartTabSent(key))
      } catch is CancellationError {
        return
      } catch {
        await send(.restartTabFailed(key, .wrapping(error)))
      }
    }
  }

  /// A restart is done when the tab reports a session other than the one it
  /// ended. The old session's end detached a live terminal (`onExit`), so one
  /// that was attached is attached again, after the host's zmx has listed it.
  fileprivate func resolvePendingRestarts(
    of host: RemoteKageHost,
    in snapshot: HostSnapshot,
    _ state: inout State
  ) -> Effect<Action> {
    var reattach: [RemoteKageTabKey] = []
    for (key, pending) in state.pendingRestarts where key.hostID == host.id {
      guard let location = RemoteKageSnapshotDiff.location(ofTab: key.tabID, in: snapshot) else {
        state.pendingRestarts[key] = nil
        continue
      }
      if location.tab.zmxSession != pending.oldSession {
        state.pendingRestarts[key] = nil
        if pending.reattach, location.tab.zmxSession != nil { reattach.append(key) }
      } else if pending.snapshotsWaited + 1 >= Self.newTabSnapshotLimit {
        state.pendingRestarts[key] = nil
        state.lastError = "The tab didn't restart on \(host.name)."
      } else {
        state.pendingRestarts[key]?.snapshotsWaited += 1
      }
    }
    guard !reattach.isEmpty else { return .none }
    return .run { [clock, reattach] send in
      try await clock.sleep(for: Self.restartReattachDelay)
      for key in reattach {
        await send(.attachTab(key))
      }
    }
  }
}

extension RemoteKageFeature.HostStatus {
  init(_ error: RemoteKageError) {
    switch error {
    case .needsUpdate: self = .needsUpdate
    case .kageNotRunning: self = .kageNotRunning
    case .unreachable, .commandFailed: self = .offline(error.localizedDescription)
    }
  }
}
