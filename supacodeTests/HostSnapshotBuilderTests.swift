import Foundation
import IdentifiedCollections
import OrderedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct HostSnapshotBuilderTests {
  // MARK: - Fixtures

  private func makeRepository(
    _ path: String,
    branches: [String] = [],
    isGit: Bool = true,
    host: RemoteHost? = nil
  ) -> Repository {
    let root = URL(fileURLWithPath: path)
    let main = Worktree(
      id: WorktreeID(path),
      name: "main",
      detail: "",
      workingDirectory: root,
      repositoryRootURL: root
    )
    let extras = branches.map { branch in
      Worktree(
        id: WorktreeID("\(path)/\(branch)"),
        name: branch,
        detail: "",
        workingDirectory: root.appending(path: branch),
        repositoryRootURL: root
      )
    }
    return Repository(
      id: RepositoryID(path),
      rootURL: root,
      name: root.lastPathComponent,
      worktrees: IdentifiedArray(uniqueElements: [main] + extras),
      isGitRepository: isGit,
      host: host
    )
  }

  private func build(
    repositories: [Repository],
    sidebar: SidebarState = SidebarState(),
    tabs: [Worktree.ID: [HostSnapshotBuilder.TabInput]] = [:],
    agents: [HostSnapshotBuilder.AgentInput] = [],
    zmxPath: String? = "/Applications/Kage.app/Contents/Resources/zmx/zmx"
  ) -> HostSnapshot {
    HostSnapshotBuilder.build(
      HostSnapshotBuilder.Inputs(
        repositories: repositories,
        sidebar: sidebar,
        tabsByWorktree: tabs,
        agents: agents,
        zmxPath: zmxPath,
        cliPath: "/Applications/Kage.app/Contents/Resources/bin/supacode",
        kageVersion: "1.2.3",
        machineName: "Mini"
      )
    )
  }

  private func tab(
    _ id: UUID = UUID(),
    title: String = "zsh",
    focused: Bool = false,
    surface: UUID = UUID(),
    terminal: Bool = true,
    usesZmx: Bool = true
  ) -> HostSnapshotBuilder.TabInput {
    .init(id: id, title: title, isFocused: focused, surfaceID: surface, isTerminal: terminal, usesZmx: usesZmx)
  }

  // MARK: - Header

  @Test func headerFieldsAreCopied() {
    let snapshot = build(repositories: [])
    #expect(snapshot.schemaVersion == HostSnapshot.currentSchemaVersion)
    #expect(snapshot.kageVersion == "1.2.3")
    #expect(snapshot.machineName == "Mini")
    #expect(snapshot.cliPath == "/Applications/Kage.app/Contents/Resources/bin/supacode")
    #expect(snapshot.zmxPath == "/Applications/Kage.app/Contents/Resources/zmx/zmx")
    #expect(snapshot.workspaces.isEmpty)
    #expect(snapshot.repositories.isEmpty)
  }

  // MARK: - Repositories

  @Test func repositoriesFollowSidebarSectionOrderWithUnknownAppended() {
    let repoA = makeRepository("/tmp/a")
    let repoB = makeRepository("/tmp/b")
    let repoC = makeRepository("/tmp/c")
    var sidebar = SidebarState()
    sidebar.sections = [repoB.id: .init(), repoA.id: .init()]
    let snapshot = build(repositories: [repoA, repoB, repoC], sidebar: sidebar)
    #expect(snapshot.repositories.map(\.id) == ["/tmp/b", "/tmp/a", "/tmp/c"])
  }

  @Test func remoteRepositoriesAreExcluded() {
    let local = makeRepository("/tmp/local")
    let remote = makeRepository(
      "/srv/remote", host: RemoteHost(alias: "box", username: "dev", port: 22))
    let snapshot = build(repositories: [local, remote])
    #expect(snapshot.repositories.map(\.id) == ["/tmp/local"])
  }

  @Test func customTitleColorAndGitFlagComeFromSidebar() {
    let repo = makeRepository("/tmp/folder", isGit: false)
    var sidebar = SidebarState()
    sidebar.sections = [repo.id: .init(title: "  Pretty  ", color: .teal)]
    let snapshot = build(repositories: [repo], sidebar: sidebar)
    let result = snapshot.repositories[0]
    #expect(result.name == "Pretty")
    #expect(result.color == HostSnapshot.RepositoryColorValue(rawValue: "teal"))
    #expect(result.isGitRepository == false)
    #expect(result.rootPath == "/tmp/folder")
  }

  @Test func blankTitleFallsBackToRepositoryName() {
    let repo = makeRepository("/tmp/plain")
    var sidebar = SidebarState()
    sidebar.sections = [repo.id: .init(title: "   ")]
    let snapshot = build(repositories: [repo], sidebar: sidebar)
    #expect(snapshot.repositories[0].name == "plain")
    #expect(snapshot.repositories[0].color == nil)
  }

  // MARK: - Workspaces

  @Test func workspacesKeepSwitcherOrderAndMembership() {
    let repoA = makeRepository("/tmp/a")
    let repoB = makeRepository("/tmp/b")
    var sidebar = SidebarState()
    sidebar.addWorkspace(.init(id: "w2", name: "Side"))
    sidebar.addWorkspace(.init(id: "w1", name: "Work"))
    sidebar.sections = [repoA.id: .init(workspaceID: "w1"), repoB.id: .init()]
    let snapshot = build(repositories: [repoA, repoB], sidebar: sidebar)
    #expect(snapshot.workspaces.map(\.id) == ["w2", "w1"])
    #expect(snapshot.workspaces.map(\.name) == ["Side", "Work"])
    #expect(snapshot.repositories.first { $0.id == "/tmp/a" }?.workspaceID == "w1")
    #expect(snapshot.repositories.first { $0.id == "/tmp/b" }?.workspaceID == nil)
  }

  // MARK: - Worktrees

  @Test func worktreesAreMainFirstThenPinnedThenUnpinned() {
    let repo = makeRepository("/tmp/r", branches: ["x", "y", "z"])
    var sidebar = SidebarState()
    sidebar.insert(worktree: WorktreeID("/tmp/r/y"), in: repo.id, bucket: .unpinned)
    sidebar.insert(worktree: WorktreeID("/tmp/r/x"), in: repo.id, bucket: .unpinned)
    sidebar.insert(worktree: WorktreeID("/tmp/r/z"), in: repo.id, bucket: .pinned)
    let worktrees = build(repositories: [repo], sidebar: sidebar).repositories[0].worktrees
    #expect(worktrees.map(\.name) == ["main", "z", "y", "x"])
    #expect(worktrees.map(\.isMain) == [true, false, false, false])
    #expect(worktrees.map(\.isPinned) == [false, true, false, false])
    #expect(worktrees[1].path == "/tmp/r/z")
    #expect(worktrees[1].id == "/tmp/r/z")
  }

  @Test func archivedWorktreesAreExcluded() {
    let repo = makeRepository("/tmp/r", branches: ["old", "new"])
    var sidebar = SidebarState()
    sidebar.insert(worktree: WorktreeID("/tmp/r/new"), in: repo.id, bucket: .unpinned)
    sidebar.archive(worktree: WorktreeID("/tmp/r/old"), in: repo.id, from: .unpinned, at: Date())
    let worktrees = build(repositories: [repo], sidebar: sidebar).repositories[0].worktrees
    #expect(worktrees.map(\.name) == ["main", "new"])
  }

  @Test func worktreesMissingFromSidebarAreAppendedInRepositoryOrder() {
    let repo = makeRepository("/tmp/r", branches: ["a", "b", "c"])
    var sidebar = SidebarState()
    sidebar.insert(worktree: WorktreeID("/tmp/r/b"), in: repo.id, bucket: .unpinned)
    let worktrees = build(repositories: [repo], sidebar: sidebar).repositories[0].worktrees
    #expect(worktrees.map(\.name) == ["main", "b", "a", "c"])
  }

  @Test func mainWorktreeIsNotDuplicatedWhenBucketed() {
    let repo = makeRepository("/tmp/r", branches: ["a"])
    var sidebar = SidebarState()
    sidebar.insert(worktree: WorktreeID("/tmp/r/a"), in: repo.id, bucket: .unpinned)
    sidebar.insert(worktree: WorktreeID("/tmp/r"), in: repo.id, bucket: .unpinned)
    let worktrees = build(repositories: [repo], sidebar: sidebar).repositories[0].worktrees
    #expect(worktrees.map(\.name) == ["main", "a"])
  }

  @Test func customWorktreeTitleOverridesName() {
    let repo = makeRepository("/tmp/r", branches: ["feat"])
    var sidebar = SidebarState()
    sidebar.insert(worktree: WorktreeID("/tmp/r/feat"), in: repo.id, bucket: .unpinned)
    sidebar.setCustomization(
      title: "Shiny", color: nil, worktree: WorktreeID("/tmp/r/feat"), in: repo.id)
    let worktrees = build(repositories: [repo], sidebar: sidebar).repositories[0].worktrees
    #expect(worktrees.map(\.name) == ["main", "Shiny"])
  }

  // MARK: - Tabs

  @Test func tabsKeepOrderFocusAndTitles() {
    let repo = makeRepository("/tmp/r")
    let first = UUID()
    let second = UUID()
    let tabs = [
      WorktreeID("/tmp/r"): [
        tab(first, title: "build", focused: false),
        tab(second, title: "claude", focused: true),
      ]
    ]
    let result = build(repositories: [repo], tabs: tabs).repositories[0].worktrees[0].tabs
    #expect(result.map(\.id) == [first.uuidString, second.uuidString])
    #expect(result.map(\.title) == ["build", "claude"])
    #expect(result.map(\.isFocused) == [false, true])
  }

  @Test func nonTerminalTabsAreOmitted() {
    let repo = makeRepository("/tmp/r")
    let keep = UUID()
    let tabs = [
      WorktreeID("/tmp/r"): [tab(UUID(), terminal: false), tab(keep)]
    ]
    let result = build(repositories: [repo], tabs: tabs).repositories[0].worktrees[0].tabs
    #expect(result.map(\.id) == [keep.uuidString])
  }

  // MARK: - zmx

  @Test func zmxSessionIsDerivedFromSurfaceID() {
    let repo = makeRepository("/tmp/r")
    let surface = UUID()
    let tabs = [WorktreeID("/tmp/r"): [tab(surface: surface)]]
    let result = build(repositories: [repo], tabs: tabs).repositories[0].worktrees[0].tabs[0]
    #expect(result.surfaceID == surface.uuidString)
    #expect(result.zmxSession == ZmxSessionID.make(surfaceID: surface))
  }

  @Test func zmxSessionIsNilWhenTabBypassesZmx() {
    let repo = makeRepository("/tmp/r")
    let tabs = [WorktreeID("/tmp/r"): [tab(usesZmx: false)]]
    let result = build(repositories: [repo], tabs: tabs).repositories[0].worktrees[0].tabs[0]
    #expect(result.zmxSession == nil)
  }

  @Test func zmxSessionIsNilWhenZmxUnavailable() {
    let repo = makeRepository("/tmp/r")
    let tabs = [WorktreeID("/tmp/r"): [tab()]]
    let snapshot = build(repositories: [repo], tabs: tabs, zmxPath: nil)
    #expect(snapshot.zmxPath == nil)
    #expect(snapshot.repositories[0].worktrees[0].tabs[0].zmxSession == nil)
  }

  // MARK: - Agents

  @Test func agentsAreMappedPerSurfaceAndSortedByKind() {
    let repo = makeRepository("/tmp/r")
    let surface = UUID()
    let other = UUID()
    let tabs = [WorktreeID("/tmp/r"): [tab(surface: surface), tab(surface: other)]]
    let agents: [HostSnapshotBuilder.AgentInput] = [
      .init(surfaceID: surface, kind: "codex", activity: "idle"),
      .init(surfaceID: surface, kind: "claude", activity: "awaitingInput"),
    ]
    let result = build(repositories: [repo], tabs: tabs, agents: agents).repositories[0].worktrees[0].tabs
    #expect(
      result[0].agents == [
        HostSnapshot.Agent(kind: "claude", activity: "awaitingInput"),
        HostSnapshot.Agent(kind: "codex", activity: "idle"),
      ])
    #expect(result[0].isAwaitingInput)
    #expect(result[1].agents.isEmpty)
  }

  // MARK: - Wire

  @Test func jsonRoundTripPreservesSchemaVersion() throws {
    let repo = makeRepository("/tmp/r", branches: ["a"])
    let tabs = [WorktreeID("/tmp/r"): [tab(title: "zsh", focused: true)]]
    let snapshot = build(repositories: [repo], tabs: tabs)
    let json = try HostSnapshotBuilder.encodeJSON(snapshot)
    #expect(!json.contains("\n"))
    let decoded = try JSONDecoder().decode(HostSnapshot.self, from: Data(json.utf8))
    #expect(decoded == snapshot)
    #expect(decoded.schemaVersion == 1)
  }

  @Test func queryRowCarriesTheJSONUnderOneKey() throws {
    let snapshot = build(repositories: [])
    let rows = try HostSnapshotBuilder.queryRows(snapshot)
    #expect(rows.count == 1)
    let json = try #require(rows[0]["json"])
    #expect(rows[0].count == 1)
    #expect(try JSONDecoder().decode(HostSnapshot.self, from: Data(json.utf8)) == snapshot)
  }
}
