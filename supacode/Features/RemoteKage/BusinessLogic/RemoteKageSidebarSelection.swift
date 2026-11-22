import ComposableArchitecture
import Foundation

extension SidebarSelection {
  /// The remote Kage worktree this sidebar selection names, if any.
  var remoteKageSelection: RemoteKageSelection? {
    guard case .remoteKage(let selection) = self else { return nil }
    return selection
  }
}

/// How a sidebar `List` selection set that contains remote Kage rows resolves.
/// A remote row is exclusive: it is never selected together with local rows or
/// another remote row, because the detail shows exactly one remote worktree.
enum RemoteKageSidebarSelection {
  /// The remote worktree the new selection set chooses, or nil when the set is
  /// a local selection (remote rows in it are then ignored).
  ///
  /// A row that wasn't selected before wins: that is the row the user just
  /// clicked. When the set holds only the already-selected remote row plus
  /// local rows, the user extended the selection from it (Cmd / Shift click),
  /// so the local rows win and the remote row drops out.
  static func remoteSelection(
    in selections: Set<SidebarSelection>,
    current: SidebarSelection?
  ) -> RemoteKageSelection? {
    let currentRemote = current?.remoteKageSelection
    let remotes = selections.compactMap(\.remoteKageSelection)
    let newcomers = remotes.filter { $0 != currentRemote }
    if !newcomers.isEmpty {
      // Several new remote rows only come from a Shift range; pick one stably.
      return newcomers.min { ($0.hostID.uuidString, $0.worktreeID) < ($1.hostID.uuidString, $1.worktreeID) }
    }
    guard let currentRemote, remotes.contains(currentRemote) else { return nil }
    let hasLocalRows = selections.contains { $0.remoteKageSelection == nil }
    return hasLocalRows ? nil : currentRemote
  }
}

extension RepositoriesFeature.State {
  /// The detail shows a remote Kage worktree instead of a local one.
  var isShowingRemoteKage: Bool {
    selection?.remoteKageSelection != nil
  }

  /// Selects a remote Kage worktree in the sidebar, replacing any local
  /// selection, so local-only actions (archive, delete, typing into the
  /// terminal) have no target while it is shown.
  mutating func selectRemoteKage(_ remote: RemoteKageSelection) -> Effect<RepositoriesFeature.Action> {
    selection = .remoteKage(remote)
    sidebarSelectedWorktreeIDs = []
    return .send(.delegate(.selectedWorktreeChanged(nil)))
  }
}
