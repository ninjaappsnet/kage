import Foundation

/// Remote worktrees nested by branch path, the way the local sidebar nests
/// them (`SidebarBranchNesting`, same View → "Nest Worktrees by Branch"
/// setting): the main worktree first, then pinned, then unpinned worktrees,
/// each bucket nested on its own. Pure; the view renders the rows.
enum RemoteKageBranchNesting {
  nonisolated enum Bucket: String, Hashable, Sendable {
    case pinned
    case unpinned
  }

  /// A branch group, per bucket like local collapse state.
  nonisolated struct GroupKey: Hashable, Sendable {
    var bucket: Bucket
    var prefix: String
  }

  struct Group: Equatable {
    var bucket: Bucket
    var prefix: String
    /// The path the header shows (several components when a chain collapses).
    var label: String
    var depth: Int
    var isCollapsed: Bool
    /// Every worktree under the group, shown or not.
    var worktrees: [RemoteKageSidebarModel.Worktree]

    var key: GroupKey { GroupKey(bucket: bucket, prefix: prefix) }
    var isAwaitingInput: Bool { worktrees.contains(where: \.isAwaitingInput) }
  }

  enum Row: Equatable, Identifiable {
    case worktree(RemoteKageSidebarModel.Worktree, depth: Int, title: String)
    case group(Group)

    var id: String {
      switch self {
      case .worktree(let worktree, _, _): "worktree:\(worktree.selection.worktreeID)"
      case .group(let group): "group:\(group.bucket.rawValue):\(group.prefix)"
      }
    }
  }

  static func rows(
    for repository: RemoteKageSidebarModel.Repository,
    nestByBranch: Bool,
    collapsed: Set<GroupKey>
  ) -> [Row] {
    let worktrees = repository.worktrees
    guard nestByBranch, repository.isGitRepository else {
      return worktrees.map { .worktree($0, depth: 0, title: $0.name) }
    }
    let main = worktrees.filter(\.isMain).map { Row.worktree($0, depth: 0, title: $0.name) }
    let pinned = worktrees.filter { !$0.isMain && $0.isPinned }
    let unpinned = worktrees.filter { !$0.isMain && !$0.isPinned }
    return main
      + nested(pinned, bucket: .pinned, collapsed: collapsed)
      + nested(unpinned, bucket: .unpinned, collapsed: collapsed)
  }

  private static func nested(
    _ worktrees: [RemoteKageSidebarModel.Worktree],
    bucket: Bucket,
    collapsed: Set<GroupKey>
  ) -> [Row] {
    var byID: [SidebarItemID: RemoteKageSidebarModel.Worktree] = [:]
    var branches: [SidebarItemID: String] = [:]
    let ids = worktrees.map { worktree in
      let id = SidebarItemID(worktree.selection.worktreeID)
      byID[id] = worktree
      branches[id] = worktree.branch ?? worktree.name
      return id
    }
    let collapsedPrefixes = Set(collapsed.filter { $0.bucket == bucket }.map(\.prefix))
    return SidebarBranchNesting.buildRows(itemIDs: ids, branchNames: branches, collapsedPrefixes: collapsedPrefixes)
      .compactMap { row in
        switch row {
        case .leaf(let id, let depth, let displayName):
          guard let worktree = byID[id] else { return nil }
          return .worktree(worktree, depth: depth, title: title(of: worktree, tail: displayName))
        case .groupHeader(let prefix, let components, let depth, let isCollapsed, let leafIDs):
          return .group(
            Group(
              bucket: bucket,
              prefix: prefix,
              label: components.isEmpty ? prefix : components.joined(separator: "/"),
              depth: depth,
              isCollapsed: isCollapsed,
              worktrees: leafIDs.compactMap { byID[$0] }
            )
          )
        }
      }
  }

  /// A custom title stays as it is; a branch name shows only the part below
  /// its group, like a local row.
  private static func title(of worktree: RemoteKageSidebarModel.Worktree, tail: String?) -> String {
    if let branch = worktree.branch, branch != worktree.name { return worktree.name }
    return tail ?? worktree.name
  }
}
