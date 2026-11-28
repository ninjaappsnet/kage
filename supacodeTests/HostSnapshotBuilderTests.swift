import Foundation
import IdentifiedCollections
import OrderedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct HostSnapshotBuilderTests {
  // MARK: - Fixtures

  private func firstRepository(_ snapshot: HostSnapshot) throws -> HostSnapshot.Repository {
    try #require(snapshot.repositories.first)
  }

  private func firstTabs(_ snapshot: HostSnapshot) throws -> [HostSnapshot.Tab] {
    let repository = try firstRepository(snapshot)
    return try #require(repository.worktrees.first).tabs
  }

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
    usesZmx: Bool = true,
    workingDirectory: String? = nil
  ) -> HostSnapshotBuilder.TabInput {
    .init(
      id: id, title: title, isFocused: focused, surfaceID: surface, isTerminal: terminal, usesZmx: usesZmx,
      workingDirectory: workingDirectory)
  }

  // MARK: - Working directory

  @Test func tabWorkingDirectoryIsCopiedFromTheInput() throws {
    let repo = makeRepository("/tmp/a")
    let snapshot = build(
      repositories: [repo],
      tabs: [repo.worktrees[0].id: [tab(workingDirectory: "/tmp/a/Sources"), tab()]]
    )
    let tabs = try firstTabs(snapshot)
    #expect(tabs.map(\.workingDirectory) == ["/tmp/a/Sources", nil])
  }

  @Test func workingDirectoryRoundTripsThroughJSON() throws {
    let repo = makeRepository("/tmp/a")
    let snapshot = build(
      repositories: [repo], tabs: [repo.worktrees[0].id: [tab(workingDirectory: "/tmp/a/x")]])
    let json = try HostSnapshotBuilder.encodeJSON(snapshot)
    let decoded = try JSONDecoder().decode(HostSnapshot.self, from: Data(json.utf8))
    #expect(decoded == snapshot)
    #expect(try firstTabs(decoded).first?.workingDirectory == "/tmp/a/x")
  }

  @Test func snapshotWithoutWorkingDirectoryStillDecodes() throws {
    let json = """
      {"schemaVersion":1,"kageVersion":"1.3.2","machineName":"M","workspaces":[],"repositories":[
      {"id":"/r","name":"r","rootPath":"/r","isGitRepository":true,"worktrees":[
      {"id":"/r","name":"main","path":"/r","isMain":true,"isPinned":false,"tabs":[
      {"id":"t","title":"zsh","isFocused":true,"surfaceID":"s","agents":[]}]}]}]}
      """
    let decoded = try JSONDecoder().decode(HostSnapshot.self, from: Data(json.utf8))
    #expect(try firstTabs(decoded).first?.workingDirectory == nil)
  }

  // MARK: - Header

  @Test func headerFieldsAreCopied() throws {
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

  @Test func repositoriesFollowSidebarSectionOrderWithUnknownAppended() throws {
    let repoA = makeRepository("/tmp/a")
    let repoB = makeRepository("/tmp/b")
    let repoC = makeRepository("/tmp/c")
    var sidebar = SidebarState()
    sidebar.sections = [repoB.id: .init(), repoA.id: .init()]
    let snapshot = build(repositories: [repoA, repoB, repoC], sidebar: sidebar)
    #expect(snapshot.repositories.map(\.id) == ["/tmp/b", "/tmp/a", "/tmp/c"])
  }

  @Test func remoteRepositoriesAreExcluded() throws {
    let local = makeRepository("/tmp/local")
    let remote = makeRepository(
      "/srv/remote", host: RemoteHost(alias: "box", username: "dev", port: 22))
    let snapshot = build(repositories: [local, remote])
    #expect(snapshot.repositories.map(\.id) == ["/tmp/local"])
  }

  @Test func customTitleColorAndGitFlagComeFromSidebar() throws {
    let repo = makeRepository("/tmp/folder", isGit: false)
    var sidebar = SidebarState()
    sidebar.sections = [repo.id: .init(title: "  Pretty  ", color: .teal)]
    let snapshot = build(repositories: [repo], sidebar: sidebar)
    let result = try firstRepository(snapshot)
    #expect(result.name == "Pretty")
    #expect(result.color == HostSnapshot.RepositoryColorValue(rawValue: "teal"))
    #expect(result.isGitRepository == false)
    #expect(result.rootPath == "/tmp/folder")
  }

  @Test func blankTitleFallsBackToRepositoryName() throws {
    let repo = makeRepository("/tmp/plain")
    var sidebar = SidebarState()
    sidebar.sections = [repo.id: .init(title: "   ")]
    let snapshot = build(repositories: [repo], sidebar: sidebar)
    let result = try firstRepository(snapshot)
    #expect(result.name == "plain")
    #expect(result.color == nil)
  }

  // MARK: - Workspaces

  @Test func workspacesKeepSwitcherOrderAndMembership() throws {
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

  @Test func worktreesAreMainFirstThenPinnedThenUnpinned() throws {
    let repo = makeRepository("/tmp/r", branches: ["x", "y", "z"])
    var sidebar = SidebarState()
    sidebar.insert(worktree: WorktreeID("/tmp/r/y"), in: repo.id, bucket: .unpinned)
    sidebar.insert(worktree: WorktreeID("/tmp/r/x"), in: repo.id, bucket: .unpinned)
    sidebar.insert(worktree: WorktreeID("/tmp/r/z"), in: repo.id, bucket: .pinned)
    let worktrees = try firstRepository(build(repositories: [repo], sidebar: sidebar)).worktrees
    #expect(worktrees.map(\.name) == ["main", "z", "y", "x"])
    #expect(worktrees.map(\.isMain) == [true, false, false, false])
    #expect(worktrees.map(\.isPinned) == [false, true, false, false])
    #expect(worktrees.map(\.path) == ["/tmp/r", "/tmp/r/z", "/tmp/r/y", "/tmp/r/x"])
    #expect(worktrees.map(\.id) == ["/tmp/r", "/tmp/r/z", "/tmp/r/y", "/tmp/r/x"])
  }

  @Test func archivedWorktreesAreExcluded() throws {
    let repo = makeRepository("/tmp/r", branches: ["old", "new"])
    var sidebar = SidebarState()
    sidebar.insert(worktree: WorktreeID("/tmp/r/new"), in: repo.id, bucket: .unpinned)
    sidebar.archive(worktree: WorktreeID("/tmp/r/old"), in: repo.id, from: .unpinned, at: Date())
    let worktrees = try firstRepository(build(repositories: [repo], sidebar: sidebar)).worktrees
    #expect(worktrees.map(\.name) == ["main", "new"])
  }

  @Test func worktreesMissingFromSidebarAreAppendedInRepositoryOrder() throws {
    let repo = makeRepository("/tmp/r", branches: ["a", "b", "c"])
    var sidebar = SidebarState()
    sidebar.insert(worktree: WorktreeID("/tmp/r/b"), in: repo.id, bucket: .unpinned)
    let worktrees = try firstRepository(build(repositories: [repo], sidebar: sidebar)).worktrees
    #expect(worktrees.map(\.name) == ["main", "b", "a", "c"])
  }

  @Test func mainWorktreeIsNotDuplicatedWhenBucketed() throws {
    let repo = makeRepository("/tmp/r", branches: ["a"])
    var sidebar = SidebarState()
    sidebar.insert(worktree: WorktreeID("/tmp/r/a"), in: repo.id, bucket: .unpinned)
    sidebar.insert(worktree: WorktreeID("/tmp/r"), in: repo.id, bucket: .unpinned)
    let worktrees = try firstRepository(build(repositories: [repo], sidebar: sidebar)).worktrees
    #expect(worktrees.map(\.name) == ["main", "a"])
  }

  @Test func customWorktreeTitleOverridesName() throws {
    let repo = makeRepository("/tmp/r", branches: ["feat"])
    var sidebar = SidebarState()
    sidebar.insert(worktree: WorktreeID("/tmp/r/feat"), in: repo.id, bucket: .unpinned)
    sidebar.setCustomization(
      title: "Shiny", color: nil, worktree: WorktreeID("/tmp/r/feat"), in: repo.id)
    let worktrees = try firstRepository(build(repositories: [repo], sidebar: sidebar)).worktrees
    #expect(worktrees.map(\.name) == ["main", "Shiny"])
  }

  @Test func worktreesCarryTheirBranchBesideACustomTitle() throws {
    let repo = makeRepository("/tmp/r", branches: ["feat/rf-picker"])
    var sidebar = SidebarState()
    sidebar.insert(worktree: WorktreeID("/tmp/r/feat/rf-picker"), in: repo.id, bucket: .unpinned)
    sidebar.setCustomization(
      title: "Picker", color: nil, worktree: WorktreeID("/tmp/r/feat/rf-picker"), in: repo.id)
    let worktrees = try firstRepository(build(repositories: [repo], sidebar: sidebar)).worktrees
    #expect(worktrees.map(\.name) == ["main", "Picker"])
    #expect(worktrees.map(\.branch) == ["main", "feat/rf-picker"])
  }

  // MARK: - Tabs

  @Test func tabsKeepOrderFocusAndTitles() throws {
    let repo = makeRepository("/tmp/r")
    let first = UUID()
    let second = UUID()
    let tabs = [
      WorktreeID("/tmp/r"): [
        tab(first, title: "build", focused: false),
        tab(second, title: "claude", focused: true),
      ]
    ]
    let result = try firstTabs(build(repositories: [repo], tabs: tabs))
    #expect(result.map(\.id) == [first.uuidString, second.uuidString])
    #expect(result.map(\.title) == ["build", "claude"])
    #expect(result.map(\.isFocused) == [false, true])
  }

  @Test func nonTerminalTabsAreOmitted() throws {
    let repo = makeRepository("/tmp/r")
    let keep = UUID()
    let tabs = [
      WorktreeID("/tmp/r"): [tab(UUID(), terminal: false), tab(keep)]
    ]
    let result = try firstTabs(build(repositories: [repo], tabs: tabs))
    #expect(result.map(\.id) == [keep.uuidString])
  }

  // MARK: - zmx

  @Test func zmxSessionIsDerivedFromSurfaceID() throws {
    let repo = makeRepository("/tmp/r")
    let surface = UUID()
    let tabs = [WorktreeID("/tmp/r"): [tab(surface: surface)]]
    let result = try #require(firstTabs(build(repositories: [repo], tabs: tabs)).first)
    #expect(result.surfaceID == surface.uuidString)
    #expect(result.zmxSession == ZmxSessionID.make(surfaceID: surface))
  }

  @Test func zmxSessionIsNilWhenTabBypassesZmx() throws {
    let repo = makeRepository("/tmp/r")
    let tabs = [WorktreeID("/tmp/r"): [tab(usesZmx: false)]]
    let result = try #require(firstTabs(build(repositories: [repo], tabs: tabs)).first)
    #expect(result.zmxSession == nil)
  }

  @Test func zmxSessionIsNilWhenZmxUnavailable() throws {
    let repo = makeRepository("/tmp/r")
    let tabs = [WorktreeID("/tmp/r"): [tab()]]
    let snapshot = build(repositories: [repo], tabs: tabs, zmxPath: nil)
    #expect(snapshot.zmxPath == nil)
    #expect(try firstTabs(snapshot).first?.zmxSession == nil)
  }

  // MARK: - Agents

  @Test func agentsAreMappedPerSurfaceAndSortedByKind() throws {
    let repo = makeRepository("/tmp/r")
    let surface = UUID()
    let other = UUID()
    let tabs = [WorktreeID("/tmp/r"): [tab(surface: surface), tab(surface: other)]]
    let agents: [HostSnapshotBuilder.AgentInput] = [
      .init(surfaceID: surface, kind: "codex", activity: "idle"),
      .init(surfaceID: surface, kind: "claude", activity: "awaitingInput"),
    ]
    let result = try firstTabs(build(repositories: [repo], tabs: tabs, agents: agents))
    #expect(result.count == 2)
    #expect(
      result.first?.agents == [
        HostSnapshot.Agent(kind: "claude", activity: "awaitingInput"),
        HostSnapshot.Agent(kind: "codex", activity: "idle"),
      ])
    #expect(result.first?.isAwaitingInput == true)
    #expect(result.last?.agents.isEmpty == true)
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
    let row = try #require(rows.first)
    let json = try #require(row["json"])
    #expect(row.count == 1)
    #expect(try JSONDecoder().decode(HostSnapshot.self, from: Data(json.utf8)) == snapshot)
  }
}
