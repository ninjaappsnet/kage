import ComposableArchitecture
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct RemoteKageSidebarModelTests {
  private let hostID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

  private func tab(
    _ id: String,
    title: String = "zsh",
    agents: [HostSnapshot.Agent] = [],
    session: String? = nil
  ) -> HostSnapshot.Tab {
    HostSnapshot.Tab(
      id: id,
      title: title,
      isFocused: false,
      surfaceID: id,
      zmxSession: session,
      agents: agents
    )
  }

  private func worktree(
    _ id: String,
    name: String? = nil,
    isMain: Bool = false,
    tabs: [HostSnapshot.Tab] = []
  ) -> HostSnapshot.Worktree {
    HostSnapshot.Worktree(id: id, name: name ?? id, path: "/r/\(id)", isMain: isMain, isPinned: false, tabs: tabs)
  }

  private func repository(
    _ id: String,
    workspaceID: String? = nil,
    color: String? = nil,
    worktrees: [HostSnapshot.Worktree]
  ) -> HostSnapshot.Repository {
    HostSnapshot.Repository(
      id: id,
      name: id.uppercased(),
      rootPath: "/r/\(id)",
      workspaceID: workspaceID,
      isGitRepository: true,
      color: color.map(HostSnapshot.RepositoryColorValue.init(rawValue:)),
      worktrees: worktrees
    )
  }

  private func snapshot(
    workspaces: [HostSnapshot.Workspace] = [],
    repositories: [HostSnapshot.Repository]
  ) -> HostSnapshot {
    HostSnapshot(
      schemaVersion: 1,
      kageVersion: "1.4.0",
      machineName: "Mac mini",
      zmxPath: "/z",
      cliPath: "/c",
      workspaces: workspaces,
      repositories: repositories
    )
  }

  // MARK: - Grouping.

  @Test func groupsRepositoriesByWorkspaceInHostOrderWithUngroupedLast() throws {
    let snapshot = snapshot(
      workspaces: [.init(id: "w2", name: "Work"), .init(id: "w1", name: "Side"), .init(id: "w3", name: "Empty")],
      repositories: [
        repository("loose", worktrees: [worktree("loose-main", isMain: true)]),
        repository("a", workspaceID: "w1", worktrees: [worktree("a-main", isMain: true)]),
        repository("b", workspaceID: "w2", worktrees: [worktree("b-main", isMain: true)]),
        repository("c", workspaceID: "w1", worktrees: [worktree("c-main", isMain: true)]),
        repository("orphan", workspaceID: "gone", worktrees: [worktree("o-main", isMain: true)]),
      ]
    )

    let groups = RemoteKageSidebarModel.groups(for: snapshot, hostID: hostID)

    #expect(groups.map(\.id) == [.workspace("w2"), .workspace("w1"), .ungrouped])
    #expect(groups.map(\.title) == ["Work", "Side", "Other Projects"])
    try #require(groups.count == 3)
    #expect(groups[0].repositories.map(\.id) == ["b"])
    #expect(groups[1].repositories.map(\.id) == ["a", "c"])
    // Repositories pointing at a workspace the host no longer lists fall back to ungrouped.
    #expect(groups[2].repositories.map(\.id) == ["loose", "orphan"])
  }

  @Test func hostWithoutWorkspacesHasOneUntitledGroup() {
    let snapshot = snapshot(repositories: [repository("a", worktrees: [worktree("a-main", isMain: true)])])

    let groups = RemoteKageSidebarModel.groups(for: snapshot, hostID: hostID)

    #expect(groups.map(\.id) == [.ungrouped])
    #expect(groups.first?.title == nil)
  }

  @Test func repositoryRowsCarryWorktreesInOrderAndParseTheirColor() throws {
    let snapshot = snapshot(
      repositories: [
        repository(
          "a",
          color: "teal",
          worktrees: [worktree("a-main", name: "main", isMain: true), worktree("a-feat", name: "feat")]
        ),
        repository("b", color: "not-a-color", worktrees: [worktree("b-main", isMain: true)]),
      ]
    )

    let repositories = RemoteKageSidebarModel.groups(for: snapshot, hostID: hostID).flatMap(\.repositories)

    try #require(repositories.count == 2)
    try #require(repositories[0].worktrees.count == 2)
    #expect(repositories[0].name == "A")
    #expect(repositories[0].color == .teal)
    #expect(repositories[0].worktrees.map(\.name) == ["main", "feat"])
    #expect(repositories[0].worktrees.map(\.isMain) == [true, false])
    #expect(repositories[0].worktrees[1].selection == RemoteKageSelection(hostID: hostID, worktreeID: "a-feat"))
    #expect(repositories[0].soleWorktree == nil)
    #expect(repositories[1].color == nil)
    #expect(repositories[1].soleWorktree?.selection.worktreeID == "b-main")
  }

  // MARK: - Agents.

  @Test func worktreeAggregatesAgentsAcrossTabsAwaitingFirst() throws {
    let snapshot = snapshot(
      repositories: [
        repository(
          "a",
          worktrees: [
            worktree(
              "a-main",
              isMain: true,
              tabs: [
                tab("t1", agents: [.init(kind: "codex", activity: "busy")]),
                tab("t2", agents: [.init(kind: "claude", activity: "awaitingInput")]),
                tab("t3", agents: [.init(kind: "mystery-agent", activity: "busy")]),
                tab("t4"),
              ]
            )
          ]
        )
      ]
    )

    let row = try #require(
      RemoteKageSidebarModel.groups(for: snapshot, hostID: hostID).first?.repositories.first?.worktrees.first
    )

    #expect(
      row.agents == [
        AgentPresenceFeature.AgentInstance(agent: .claude, activity: .awaitingInput),
        AgentPresenceFeature.AgentInstance(agent: .codex, activity: .busy),
      ]
    )
    #expect(row.unknownAgentCount == 1)
    #expect(row.isAwaitingInput)
    #expect(row.isBusy)
    #expect(row.tabCount == 4)
  }

  @Test func unknownActivityReadsAsIdle() {
    let instances = RemoteKageSidebarModel.agentInstances(
      for: [tab("t1", agents: [.init(kind: "claude", activity: "somethingNew")])]
    )

    #expect(instances.known == [AgentPresenceFeature.AgentInstance(agent: .claude, activity: .idle)])
    #expect(instances.unknownCount == 0)
  }

  @Test func idleWorktreeIsNeitherAwaitingNorBusy() throws {
    let snapshot = snapshot(
      repositories: [
        repository(
          "a",
          worktrees: [
            worktree("a-main", isMain: true, tabs: [tab("t1", agents: [.init(kind: "claude", activity: "idle")])])
          ]
        )
      ]
    )

    let row = try #require(
      RemoteKageSidebarModel.groups(for: snapshot, hostID: hostID).first?.repositories.first?.worktrees.first
    )

    #expect(!row.isAwaitingInput)
    #expect(!row.isBusy)
    #expect(row.agents == [AgentPresenceFeature.AgentInstance(agent: .claude, activity: .idle)])
  }

  // MARK: - Hosts.

  @Test func hostsFollowConfiguredOrderAndOnlySnapshottedOnesHaveGroups() throws {
    let first = RemoteKageHost(id: hostID, name: "Mini 1", username: "me", address: "mini1")
    let second = RemoteKageHost(name: "Mini 2", username: "me", address: "mini2")
    let awaiting = snapshot(
      repositories: [
        repository(
          "a",
          worktrees: [
            worktree(
              "a-main", isMain: true, tabs: [tab("t", agents: [.init(kind: "claude", activity: "awaitingInput")])])
          ]
        )
      ]
    )
    let hostStates: [RemoteKageHost.ID: RemoteKageFeature.HostState] = [
      first.id: .init(status: .online, lastSnapshot: awaiting, lastUpdated: nil),
      second.id: .init(status: .connecting, lastSnapshot: nil, lastUpdated: nil),
    ]

    let model = RemoteKageSidebarModel.make(hosts: [first, second], hostStates: hostStates)

    #expect(model.hosts.map(\.name) == ["Mini 1", "Mini 2"])
    try #require(model.hosts.count == 2)
    #expect(model.hosts[0].groups?.count == 1)
    #expect(model.hosts[0].isAwaitingInput)
    #expect(model.hosts[1].groups == nil)
    #expect(!model.hosts[1].isAwaitingInput)
    #expect(model.hosts[1].indicator.label == "Connecting…")
  }

  @Test func hostWithoutStateYetReadsAsConnecting() {
    let host = RemoteKageHost(id: hostID, name: "Mini 1", username: "me", address: "mini1")

    let model = RemoteKageSidebarModel.make(hosts: [host], hostStates: [:])

    #expect(model.hosts.first?.groups == nil)
    #expect(model.hosts.first?.indicator == RemoteKageHostIndicator.make(status: .connecting, snapshot: nil))
  }

  @Test func offlineHostKeepsItsLastSnapshotRows() {
    let host = RemoteKageHost(id: hostID, name: "Mini 1", username: "me", address: "mini1")
    let last = snapshot(repositories: [repository("a", worktrees: [worktree("a-main", isMain: true)])])

    let model = RemoteKageSidebarModel.make(
      hosts: [host],
      hostStates: [hostID: .init(status: .offline("timeout"), lastSnapshot: last, lastUpdated: nil)]
    )

    #expect(model.hosts.first?.groups?.first?.repositories.map(\.id) == ["a"])
    #expect(model.hosts.first?.indicator.label == "Offline")
  }

  // MARK: - Status indicator.

  @Test func indicatorDescribesEachStatus() {
    let snap = snapshot(repositories: [])
    let online = RemoteKageHostIndicator.make(status: .online, snapshot: snap)
    #expect(online.label == "Online")
    #expect(online.tint == .green)
    #expect(online.help == "Online\nMac mini · Kage 1.4.0")

    let offline = RemoteKageHostIndicator.make(status: .offline("Connection timed out"), snapshot: nil)
    #expect(offline.label == "Offline")
    #expect(offline.tint == .red)
    #expect(offline.help == "Offline: Connection timed out")

    let notRunning = RemoteKageHostIndicator.make(status: .kageNotRunning, snapshot: snap)
    #expect(notRunning.label == "Kage isn't running")
    #expect(notRunning.tint == .orange)
    #expect(notRunning.help == "Kage isn't running: open Kage on that Mac.\nMac mini · Kage 1.4.0")

    let update = RemoteKageHostIndicator.make(status: .needsUpdate, snapshot: nil)
    #expect(update.label == "Needs update")
    #expect(update.tint == .yellow)
    #expect(update.help == "Needs update: update Kage on that Mac.")

    let connecting = RemoteKageHostIndicator.make(status: .connecting, snapshot: nil)
    #expect(connecting.label == "Connecting…")
    #expect(connecting.tint == .secondary)

    #expect(Set([online, offline, notRunning, update, connecting].map(\.systemImage)).count == 5)
  }

  // MARK: - Awaiting input on collapsible containers.

  private func awaitingTab() -> HostSnapshot.Tab {
    tab("t-await", agents: [.init(kind: "claude", activity: "awaitingInput")])
  }

  @Test func groupAwaitsInputWhenAnyWorktreeInItDoes() throws {
    let snapshot = snapshot(
      workspaces: [.init(id: "w1", name: "Side"), .init(id: "w2", name: "Work")],
      repositories: [
        repository("a", workspaceID: "w1", worktrees: [worktree("a-main", isMain: true)]),
        repository(
          "b",
          workspaceID: "w2",
          worktrees: [worktree("b-main", isMain: true), worktree("b-x", tabs: [awaitingTab()])]
        ),
      ]
    )

    let groups = RemoteKageSidebarModel.groups(for: snapshot, hostID: hostID)

    try #require(groups.count == 2)
    #expect(!groups[0].isAwaitingInput)
    #expect(groups[1].isAwaitingInput)
  }

  @Test func modelAwaitsInputWhenAnyHostDoes() {
    let quiet = RemoteKageHost(name: "Quiet", username: "me", address: "q")
    let loud = RemoteKageHost(id: hostID, name: "Loud", username: "me", address: "l")
    let loudSnapshot = snapshot(
      repositories: [repository("a", worktrees: [worktree("a-main", isMain: true, tabs: [awaitingTab()])])]
    )

    let allQuiet = RemoteKageSidebarModel.make(hosts: [quiet], hostStates: [:])
    let oneLoud = RemoteKageSidebarModel.make(
      hosts: [quiet, loud],
      hostStates: [loud.id: .init(status: .online, lastSnapshot: loudSnapshot, lastUpdated: nil)]
    )

    #expect(!allQuiet.isAwaitingInput)
    #expect(oneLoud.isAwaitingInput)
  }

  // MARK: - Reveal target.

  @Test func revealTargetNamesTheHostAndTheWorkspaceHoldingTheSelection() {
    let host = RemoteKageHost(id: hostID, name: "Mini", username: "me", address: "m")
    let last = snapshot(
      workspaces: [.init(id: "w1", name: "Side")],
      repositories: [
        repository("a", workspaceID: "w1", worktrees: [worktree("a-main", isMain: true)]),
        repository("loose", worktrees: [worktree("loose-main", isMain: true)]),
      ]
    )
    let model = RemoteKageSidebarModel.make(
      hosts: [host],
      hostStates: [hostID: .init(status: .online, lastSnapshot: last, lastUpdated: nil)]
    )

    let inWorkspace = model.revealTarget(for: RemoteKageSelection(hostID: hostID, worktreeID: "a-main"))
    let inUngrouped = model.revealTarget(for: RemoteKageSelection(hostID: hostID, worktreeID: "loose-main"))

    #expect(inWorkspace == .init(hostID: hostID, groupID: .workspace("w1")))
    #expect(inUngrouped == .init(hostID: hostID, groupID: .ungrouped))
  }

  @Test func revealTargetFallsBackToTheHostBeforeItsSnapshotArrives() {
    let host = RemoteKageHost(id: hostID, name: "Mini", username: "me", address: "m")
    let model = RemoteKageSidebarModel.make(hosts: [host], hostStates: [:])

    let target = model.revealTarget(for: RemoteKageSelection(hostID: hostID, worktreeID: "a-main"))

    #expect(target == .init(hostID: hostID, groupID: nil))
  }

  @Test func revealTargetIsNilWithoutASelectionOrForAnUnknownHost() {
    let host = RemoteKageHost(id: hostID, name: "Mini", username: "me", address: "m")
    let model = RemoteKageSidebarModel.make(hosts: [host], hostStates: [:])
    let stranger = RemoteKageSelection(hostID: UUID(), worktreeID: "x")

    #expect(model.revealTarget(for: nil) == nil)
    #expect(model.revealTarget(for: stranger) == nil)
  }
}
