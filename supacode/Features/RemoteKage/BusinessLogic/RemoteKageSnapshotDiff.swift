import Foundation

/// Compares and searches host snapshots.
nonisolated enum RemoteKageSnapshotDiff {
  /// A tab with the repository and worktree it lives in.
  struct TabLocation: Equatable, Sendable {
    var repositoryName: String
    var worktreeID: String
    var tab: HostSnapshot.Tab
  }

  static func locations(in snapshot: HostSnapshot) -> [TabLocation] {
    snapshot.repositories.flatMap { repository in
      repository.worktrees.flatMap { worktree in
        worktree.tabs.map { TabLocation(repositoryName: repository.name, worktreeID: worktree.id, tab: $0) }
      }
    }
  }

  /// Tabs waiting for input now that weren't in `previous`. Nothing on a
  /// host's first snapshot (`previous == nil`): that is state, not a change.
  static func newlyAwaitingTabs(previous: HostSnapshot?, current: HostSnapshot) -> [TabLocation] {
    guard let previous else { return [] }
    let wasAwaiting = Set(locations(in: previous).filter(\.tab.isAwaitingInput).map(\.tab.id))
    return locations(in: current).filter { $0.tab.isAwaitingInput && !wasAwaiting.contains($0.tab.id) }
  }

  static func tabIDs(in snapshot: HostSnapshot) -> Set<String> {
    Set(locations(in: snapshot).map(\.tab.id))
  }

  /// Finds a tab by id. Case-insensitive: a tab created here with a UUID may
  /// come back in either case.
  static func location(ofTab tabID: String, in snapshot: HostSnapshot) -> TabLocation? {
    locations(in: snapshot).first { $0.tab.id.caseInsensitiveCompare(tabID) == .orderedSame }
  }
}
