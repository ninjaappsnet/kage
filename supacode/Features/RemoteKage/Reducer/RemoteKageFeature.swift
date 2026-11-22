import ComposableArchitecture
import Foundation

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
  }

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
  }

  var body: some Reducer<State, Action> {
    Scope(state: \.settings, action: \.settings) {
      RemoteKageSettingsFeature()
    }
    Reduce { _, _ in
      // Implemented in Phase 3.
      .none
    }
  }
}
