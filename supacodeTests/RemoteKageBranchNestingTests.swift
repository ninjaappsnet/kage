import Foundation
import Testing

@testable import supacode

/// Remote worktrees nest by branch path like local ones (`SidebarBranchNesting`).
struct RemoteKageBranchNestingTests {
  private typealias Nesting = RemoteKageBranchNesting
  private let hostID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!

  private func worktree(
    _ name: String,
    branch: String? = nil,
    isMain: Bool = false,
    isPinned: Bool = false,
    isAwaitingInput: Bool = false
  ) -> RemoteKageSidebarModel.Worktree {
    RemoteKageSidebarModel.Worktree(
      selection: RemoteKageSelection(hostID: hostID, worktreeID: "/repo/\(name)"),
      name: name,
      isMain: isMain,
      isPinned: isPinned,
      tabCount: 1,
      agents: [],
      unknownAgentCount: 0,
      isAwaitingInput: isAwaitingInput,
      isBusy: false,
      branch: branch ?? name
    )
  }

  private func repository(_ worktrees: [RemoteKageSidebarModel.Worktree], isGit: Bool = true)
    -> RemoteKageSidebarModel.Repository
  {
    RemoteKageSidebarModel.Repository(
      id: "/repo", name: "repo", color: nil, isGitRepository: isGit, worktrees: worktrees)
  }

  /// A compact picture of the rows: "  feat/" for a group, "    rf-picker" for a worktree.
  private func outline(_ rows: [Nesting.Row]) -> [String] {
    rows.map { row in
      switch row {
      case .worktree(let worktree, let depth, let title):
        String(repeating: "  ", count: depth) + title + (worktree.isMain ? " (main)" : "")
      case .group(let group):
        String(repeating: "  ", count: group.depth) + group.label + "/" + (group.isCollapsed ? " (collapsed)" : "")
      }
    }
  }

  @Test func branchesSharingAPrefixNestUnderAFolderLikeLocal() {
    let repo = repository([
      worktree("main", isMain: true),
      worktree("feat/rf-picker"),
      worktree("fix/crash"),
      worktree("feat/other"),
    ])
    let rows = Nesting.rows(for: repo, nestByBranch: true, collapsed: [])
    #expect(outline(rows) == ["main (main)", "feat/", "  other", "  rf-picker", "fix/crash"])
  }

  @Test func withNestingOffTheRowsKeepTheHostsOrderAndFullNames() {
    let repo = repository([worktree("main", isMain: true), worktree("feat/rf-picker"), worktree("feat/other")])
    #expect(
      outline(Nesting.rows(for: repo, nestByBranch: false, collapsed: []))
        == ["main (main)", "feat/rf-picker", "feat/other"])
  }

  @Test func aFolderRepositoryNeverNests() {
    let repo = repository([worktree("feat/a"), worktree("feat/b")], isGit: false)
    #expect(outline(Nesting.rows(for: repo, nestByBranch: true, collapsed: [])) == ["feat/a", "feat/b"])
  }

  @Test func pinnedAndUnpinnedNestSeparatelyPinnedFirst() {
    let repo = repository([
      worktree("main", isMain: true),
      worktree("feat/a", isPinned: true),
      worktree("feat/b", isPinned: true),
      worktree("feat/c"),
      worktree("feat/d"),
    ])
    let rows = Nesting.rows(for: repo, nestByBranch: true, collapsed: [])
    #expect(outline(rows) == ["main (main)", "feat/", "  a", "  b", "feat/", "  c", "  d"])
    let buckets = rows.compactMap { row -> Nesting.Bucket? in
      if case .group(let group) = row { return group.bucket }
      return nil
    }
    #expect(buckets == [.pinned, .unpinned])
  }

  @Test func aCollapsedGroupHidesItsWorktreesButKnowsAboutThem() {
    let repo = repository([worktree("feat/a", isAwaitingInput: true), worktree("feat/b"), worktree("fix/c")])
    let rows = Nesting.rows(
      for: repo, nestByBranch: true, collapsed: [Nesting.GroupKey(bucket: .unpinned, prefix: "feat")])
    #expect(outline(rows) == ["feat/ (collapsed)", "fix/c"])
    guard case .group(let group) = rows.first else {
      Issue.record("Expected a group first")
      return
    }
    #expect(group.worktrees.map(\.name) == ["feat/a", "feat/b"])
    #expect(group.isAwaitingInput)
  }

  @Test func aCustomTitleNestsByItsBranchButKeepsTheTitle() {
    let repo = repository([worktree("Picker work", branch: "feat/rf-picker"), worktree("feat/other")])
    #expect(
      outline(Nesting.rows(for: repo, nestByBranch: true, collapsed: []))
        == ["feat/", "  other", "  Picker work"])
  }

  @Test func anOlderHostWithoutBranchesNestsByName() {
    var old = worktree("feat/a")
    old.branch = nil
    var other = worktree("feat/b")
    other.branch = nil
    #expect(
      outline(Nesting.rows(for: repository([old, other]), nestByBranch: true, collapsed: []))
        == ["feat/", "  a", "  b"])
  }
}

struct RemoteKageBranchGroupExpansionTests {
  @Test func branchGroupsRememberOnlyWhatIsCollapsedPerHostAndRepository() throws {
    let host = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    let key = RemoteKageBranchNesting.GroupKey(bucket: .unpinned, prefix: "feat")
    var expansion = RemoteKageSidebarExpansion()
    #expect(expansion.collapsedBranchGroups(host: host, repository: "/repo").isEmpty)
    expansion.setBranchGroup(host: host, repository: "/repo", key, expanded: false)
    #expect(expansion.collapsedBranchGroups(host: host, repository: "/repo") == [key])
    #expect(expansion.collapsedBranchGroups(host: host, repository: "/other").isEmpty)
    let restored = try #require(RemoteKageSidebarExpansion(rawValue: expansion.rawValue))
    #expect(restored.collapsedBranchGroups(host: host, repository: "/repo") == [key])
    expansion.setBranchGroup(host: host, repository: "/repo", key, expanded: true)
    #expect(expansion.collapsedBranchGroups(host: host, repository: "/repo").isEmpty)
  }

  @Test func revealingAWorktreeOpensTheBranchGroupsAboveIt() {
    let host = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    var expansion = RemoteKageSidebarExpansion()
    for key in [
      RemoteKageBranchNesting.GroupKey(bucket: .unpinned, prefix: "feat"),
      RemoteKageBranchNesting.GroupKey(bucket: .pinned, prefix: "feat/ui"),
      RemoteKageBranchNesting.GroupKey(bucket: .unpinned, prefix: "fix"),
    ] {
      expansion.setBranchGroup(host: host, repository: "/repo", key, expanded: false)
    }
    let revealed = expansion.revealing(
      .init(hostID: host, groupID: nil, repositoryID: "/repo", branch: "feat/ui/picker"))
    #expect(
      revealed.collapsedBranchGroups(host: host, repository: "/repo")
        == [RemoteKageBranchNesting.GroupKey(bucket: .unpinned, prefix: "fix")])
  }

  @Test func theRevealTargetNamesTheWorktreesRepositoryAndBranch() {
    let host = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    var worktree = RemoteKagePollingFixtures.snapshot(tabs: []).repositories[0].worktrees[0]
    worktree.name = "Custom"
    worktree.branch = "feat/picker"
    var snapshot = RemoteKagePollingFixtures.snapshot(tabs: [])
    snapshot.repositories[0].worktrees = [worktree]
    var hostState = RemoteKageFeature.HostState()
    hostState.lastSnapshot = snapshot
    let model = RemoteKageSidebarModel.make(
      hosts: [RemoteKageHost(id: host, name: "Mini", username: "me", address: "mini")],
      hostStates: [host: hostState]
    )
    let target = model.revealTarget(for: RemoteKageSelection(hostID: host, worktreeID: worktree.id))
    #expect(target?.repositoryID == snapshot.repositories[0].id)
    #expect(target?.branch == "feat/picker")
  }
}
