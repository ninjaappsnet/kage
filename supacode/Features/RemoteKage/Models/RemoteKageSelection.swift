import Foundation

/// A remote worktree selected in the sidebar: which host, which of its worktrees.
nonisolated struct RemoteKageSelection: Hashable, Sendable, Codable {
  var hostID: RemoteKageHost.ID
  /// The host's raw worktree id (`HostSnapshot.Worktree.id`).
  var worktreeID: String
}

/// One remote tab, addressed globally.
nonisolated struct RemoteKageTabKey: Hashable, Sendable {
  var hostID: RemoteKageHost.ID
  /// The host's tab UUID string (`HostSnapshot.Tab.id`).
  var tabID: String
}
