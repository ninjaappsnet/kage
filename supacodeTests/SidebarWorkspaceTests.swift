import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import OrderedCollections
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// `.dependencies` gives every test its own dependency context, and with it its
/// own `@Shared(.sidebar)` storage. Without it these tests race: the sidebar is
/// process-global, so one test switching the active workspace is visible to
/// every other test Swift Testing happens to run in parallel with it.
@Suite(.dependencies)
@MainActor
struct SidebarWorkspaceTests {
  private let repoA: Repository.ID = "/tmp/repo-a"
  private let repoB: Repository.ID = "/tmp/repo-b"

  // MARK: - Codable

  @Test func workspacesRoundTripThroughCodable() throws {
    var state = SidebarState()
    state.addWorkspace(.init(id: "ws-1", name: "Work"))
    state.addWorkspace(.init(id: "ws-2", name: "Side"))
    state.setWorkspace("ws-1", for: repoA)
    state.activeWorkspaceID = "ws-2"

    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(SidebarState.self, from: data)

    #expect(decoded.workspaces.count == 2)
    #expect(decoded.workspaces["ws-1"]?.name == "Work")
    #expect(Array(decoded.workspaces.keys) == ["ws-1", "ws-2"])
    #expect(decoded.sections[repoA]?.workspaceID == "ws-1")
    #expect(decoded.activeWorkspaceID == "ws-2")
  }

  @Test func legacySidebarJSONDecodesWithEmptyWorkspaces() throws {
    // A sidebar.json written before the workspaces feature shipped has neither
    // `workspaces` / `activeWorkspaceID` nor a per-section `workspaceID`.
    // `OrderedDictionary` encodes Codable as a flat [key, value, …] array, so
    // `sections` / `buckets` are arrays on the wire, not JSON objects.
    let legacy = """
      {
        "schemaVersion": 1,
        "sections": ["/tmp/repo-a", { "collapsed": false, "buckets": [] }]
      }
      """
    let decoded = try JSONDecoder().decode(SidebarState.self, from: Data(legacy.utf8))

    #expect(decoded.workspaces.isEmpty)
    #expect(decoded.activeWorkspaceID == nil)
    #expect(decoded.sections[repoA]?.workspaceID == nil)
    #expect(decoded.sections[repoA] != nil)
  }

  @Test func emptyWorkspacesAreOmittedFromEncodedFile() throws {
    let state = SidebarState(sections: [repoA: .init()])
    let data = try JSONEncoder().encode(state)
    let json = String(bytes: data, encoding: .utf8) ?? ""
    #expect(!json.contains("workspaces"))
    #expect(!json.contains("activeWorkspaceID"))
  }

  @Test func rememberedSelectionsRoundTripThroughCodable() throws {
    var state = SidebarState()
    state.addWorkspace(.init(id: "ws-1", name: "Work"))
    state.rememberSelection(worktreeID(repoA), for: "ws-1")
    state.rememberSelection(worktreeID(repoB), for: nil)

    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(SidebarState.self, from: data)

    #expect(decoded.rememberedSelection(for: "ws-1") == worktreeID(repoA))
    // "All Projects" (nil filter) persists under its own sentinel key.
    #expect(decoded.rememberedSelection(for: nil) == worktreeID(repoB))
  }

  @Test func legacySidebarJSONDecodesWithNoRememberedSelections() throws {
    // `lastSelectionByWorkspace` is additive: a file written before per-workspace
    // selection memory shipped has no such key and must still decode.
    let legacy = """
      {
        "schemaVersion": 1,
        "sections": ["/tmp/repo-a", { "collapsed": false, "buckets": [] }]
      }
      """
    let decoded = try JSONDecoder().decode(SidebarState.self, from: Data(legacy.utf8))

    #expect(decoded.lastSelectionByWorkspace.isEmpty)
    #expect(decoded.rememberedSelection(for: nil) == nil)
  }

  @Test func emptyRememberedSelectionsAreOmittedFromEncodedFile() throws {
    let state = SidebarState(sections: [repoA: .init()])
    let data = try JSONEncoder().encode(state)
    let json = String(bytes: data, encoding: .utf8) ?? ""
    #expect(!json.contains("lastSelectionByWorkspace"))
  }

  // MARK: - Mutations

  @Test func removeWorkspaceRevertsMembersAndResetsActive() {
    var state = SidebarState()
    state.addWorkspace(.init(id: "ws-1", name: "Work"))
    state.addWorkspace(.init(id: "ws-2", name: "Side"))
    state.setWorkspace("ws-1", for: repoA)
    state.setWorkspace("ws-2", for: repoB)
    state.activeWorkspaceID = "ws-1"

    state.removeWorkspace("ws-1")

    #expect(state.workspaces["ws-1"] == nil)
    #expect(state.workspaces["ws-2"]?.name == "Side")
    // repoA reverts to ungrouped; repoB keeps its (different) workspace.
    #expect(state.sections[repoA]?.workspaceID == nil)
    #expect(state.sections[repoB]?.workspaceID == "ws-2")
    // The active filter pointed at the deleted workspace → falls back to "All".
    #expect(state.activeWorkspaceID == nil)
  }

  @Test func removeWorkspaceKeepsActiveWhenADifferentWorkspaceIsDeleted() {
    var state = SidebarState()
    state.addWorkspace(.init(id: "ws-1", name: "Work"))
    state.addWorkspace(.init(id: "ws-2", name: "Side"))
    state.activeWorkspaceID = "ws-1"

    state.removeWorkspace("ws-2")

    #expect(state.activeWorkspaceID == "ws-1")
  }

  @Test func setWorkspaceMaterializesSection() {
    var state = SidebarState()
    #expect(state.sections[repoA] == nil)
    state.setWorkspace("ws-1", for: repoA)
    #expect(state.sections[repoA]?.workspaceID == "ws-1")
  }

  @Test func rememberingNilSelectionClearsTheEntry() {
    var state = SidebarState()
    state.rememberSelection(worktreeID(repoA), for: "ws-1")
    #expect(state.rememberedSelection(for: "ws-1") == worktreeID(repoA))

    state.rememberSelection(nil, for: "ws-1")
    #expect(state.rememberedSelection(for: "ws-1") == nil)
    #expect(state.lastSelectionByWorkspace.isEmpty)
  }

  @Test func removeWorkspaceDropsItsRememberedSelection() {
    var state = SidebarState()
    state.addWorkspace(.init(id: "ws-1", name: "Work"))
    state.rememberSelection(worktreeID(repoA), for: "ws-1")
    state.rememberSelection(worktreeID(repoB), for: nil)

    state.removeWorkspace("ws-1")

    #expect(state.rememberedSelection(for: "ws-1") == nil)
    // "All Projects" is not a workspace and keeps its own memory.
    #expect(state.rememberedSelection(for: nil) == worktreeID(repoB))
  }

  // MARK: - Reducer

  @Test func createWorkspaceAddsItButDoesNotAutoSwitch() async {
    let store = TestStore(initialState: makeState(repositories: [makeRepository(repoA)])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.createWorkspace(name: "  Work  "))

    let id = "00000000-0000-0000-0000-000000000000"
    #expect(store.state.sidebar.workspaces[id]?.name == "Work")
    // Creating does not switch into the (empty) workspace.
    #expect(store.state.sidebar.activeWorkspaceID == nil)
  }

  @Test func createWorkspaceIgnoresBlankName() async {
    let store = TestStore(initialState: makeState(repositories: [makeRepository(repoA)])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.createWorkspace(name: "   "))
    #expect(store.state.sidebar.workspaces.isEmpty)
  }

  @Test func assignRepositoryToWorkspaceSetsMembership() async {
    var initial = makeState(repositories: [makeRepository(repoA)])
    initial.$sidebar.withLock { $0.addWorkspace(.init(id: "ws-1", name: "Work")) }
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.assignRepositoryToWorkspace(repositoryID: repoA, workspaceID: "ws-1"))
    #expect(store.state.sidebar.sections[repoA]?.workspaceID == "ws-1")

    await store.send(.assignRepositoryToWorkspace(repositoryID: repoA, workspaceID: nil))
    #expect(store.state.sidebar.sections[repoA]?.workspaceID == nil)
  }

  @Test func assignRejectsUnknownWorkspace() async {
    let store = TestStore(initialState: makeState(repositories: [makeRepository(repoA)])) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.assignRepositoryToWorkspace(repositoryID: repoA, workspaceID: "ghost"))
    #expect(store.state.sidebar.sections[repoA]?.workspaceID == nil)
  }

  @Test func setActiveWorkspaceRejectsUnknownID() async {
    let store = TestStore(initialState: makeState(repositories: [makeRepository(repoA)])) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.setActiveWorkspace("ghost"))
    #expect(store.state.sidebar.activeWorkspaceID == nil)
  }

  @Test func deleteWorkspaceRevertsMembersAndResetsActive() async {
    var initial = makeState(repositories: [makeRepository(repoA)])
    initial.$sidebar.withLock {
      $0.addWorkspace(.init(id: "ws-1", name: "Work"))
      $0.setWorkspace("ws-1", for: repoA)
      $0.activeWorkspaceID = "ws-1"
    }
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.deleteWorkspace(id: "ws-1"))
    #expect(store.state.sidebar.workspaces.isEmpty)
    #expect(store.state.sidebar.sections[repoA]?.workspaceID == nil)
    #expect(store.state.sidebar.activeWorkspaceID == nil)
  }

  @Test func addingRepositoryWhileWorkspaceActiveInheritsWorkspace() async {
    var initial = makeState(repositories: [makeRepository(repoA)])
    initial.$sidebar.withLock {
      $0.addWorkspace(.init(id: "ws-1", name: "Work"))
      $0.setWorkspace("ws-1", for: repoA)
      $0.activeWorkspaceID = "ws-1"
    }
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off

    let repoBRepository = makeRepository(repoB)
    await store.send(
      .openRepositoriesFinished(
        [makeRepository(repoA), repoBRepository],
        failures: [],
        invalidRoots: [],
        roots: [URL(fileURLWithPath: repoA.rawValue), repoBRepository.rootURL]
      )
    )

    // The repo added while "Work" was the active filter joins it, instead of
    // landing only under "All Projects". Existing membership is untouched.
    #expect(store.state.sidebar.sections[repoB]?.workspaceID == "ws-1")
    #expect(store.state.sidebar.sections[repoA]?.workspaceID == "ws-1")
  }

  @Test func addingRepositoryUnderAllProjectsStaysUngrouped() async {
    let initial = makeState(repositories: [makeRepository(repoA)])
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off

    let repoBRepository = makeRepository(repoB)
    await store.send(
      .openRepositoriesFinished(
        [makeRepository(repoA), repoBRepository],
        failures: [],
        invalidRoots: [],
        roots: [URL(fileURLWithPath: repoA.rawValue), repoBRepository.rootURL]
      )
    )

    // No active workspace filter → new repo stays ungrouped ("All Projects").
    #expect(store.state.sidebar.sections[repoB]?.workspaceID == nil)
  }

  // MARK: - Structure filtering

  @Test func activeWorkspaceHidesNonMemberRepositories() {
    var state = RepositoriesFeature.State(reconciledRepositories: [
      makeRepository(repoA), makeRepository(repoB),
    ])
    // Both repos visible under "All".
    #expect(Set(state.sidebarStructure.reorderableRepositoryIDs) == [repoA, repoB])

    state.$sidebar.withLock {
      $0.addWorkspace(.init(id: "ws-1", name: "Work"))
      $0.setWorkspace("ws-1", for: repoA)
      $0.activeWorkspaceID = "ws-1"
    }
    state.applyPostReduceCacheRecomputes(.sidebarStructure)

    // Only the member repo remains; repoB is filtered out.
    #expect(state.sidebarStructure.reorderableRepositoryIDs == [repoA])
    #expect(state.workspaceVisibleRepositoryIDs() == [repoA])
  }

  @Test func visibleRepositoryIDsIsNilUnderAllProjects() {
    let state = RepositoriesFeature.State(reconciledRepositories: [makeRepository(repoA)])
    #expect(state.workspaceVisibleRepositoryIDs() == nil)
  }

  // MARK: - Switching workspaces moves the selection

  @Test func switchingWorkspaceSelectsFirstVisibleRowAndRemembersTheOutgoingOne() async {
    let store = TestStore(initialState: twoWorkspaceState(active: "ws-1", selected: worktreeID(repoA))) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.setActiveWorkspace("ws-2"))
    await store.receive(\.selectWorktree)

    // repoA is hidden under "ws-2", so the selection lands on the first row the
    // filtered sidebar actually renders.
    #expect(store.state.selectedWorktreeID == worktreeID(repoB))
    #expect(store.state.sidebar.rememberedSelection(for: "ws-1") == worktreeID(repoA))
  }

  @Test func switchingBackRestoresTheRememberedSelection() async {
    let store = TestStore(initialState: twoWorkspaceState(active: "ws-1", selected: worktreeID(repoA))) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.setActiveWorkspace("ws-2"))
    await store.receive(\.selectWorktree)
    #expect(store.state.selectedWorktreeID == worktreeID(repoB))

    await store.send(.setActiveWorkspace("ws-1"))
    await store.receive(\.selectWorktree)

    #expect(store.state.selectedWorktreeID == worktreeID(repoA))
    #expect(store.state.sidebar.rememberedSelection(for: "ws-2") == worktreeID(repoB))
  }

  @Test func switchingToAllProjectsKeepsAStillVisibleSelection() async {
    // repoA belongs to "ws-1"; "All Projects" shows every repo, so the selected
    // row stays put and no `.selectWorktree` is sent (exhaustivity proves it).
    var initial = twoWorkspaceState(active: "ws-1", selected: worktreeID(repoA))
    initial.$sidebar.withLock { $0.setWorkspace(nil, for: repoB) }
    initial.applyPostReduceCacheRecomputes()

    let store = TestStore(initialState: initial) { RepositoriesFeature() }

    await store.send(.setActiveWorkspace(nil)) {
      $0.$sidebar.withLock {
        $0.rememberSelection(self.worktreeID(self.repoA), for: "ws-1")
        $0.activeWorkspaceID = nil
      }
      $0.applyPostReduceCacheRecomputes(.sidebarStructure)
    }

    #expect(store.state.selectedWorktreeID == worktreeID(repoA))
  }

  @Test func switchingToTheAlreadyActiveWorkspaceIsANoOp() async {
    let store = TestStore(initialState: twoWorkspaceState(active: "ws-1", selected: worktreeID(repoA))) {
      RepositoriesFeature()
    }
    // Not exhaustive on purpose: `twoWorkspaceState` mutates `@Shared(.sidebar)`
    // before the store exists, and TestStore only settles that pending shared
    // change against a closure that locks `$sidebar` itself — asserting "no
    // state change at all" here would fail on that bookkeeping, not on behavior.
    store.exhaustivity = .off

    await store.send(.setActiveWorkspace("ws-1"))

    // An empty memory is the proof the guard fired: an unguarded arm would have
    // recorded the outgoing selection against the workspace it never left.
    #expect(store.state.sidebar.lastSelectionByWorkspace.isEmpty)
    #expect(store.state.selectedWorktreeID == worktreeID(repoA))
  }

  @Test func switchingToAWorkspaceWithNoVisibleRowsClearsTheSelection() async {
    var initial = twoWorkspaceState(active: "ws-1", selected: worktreeID(repoA))
    // "ws-2" exists but owns no repository, so the filtered sidebar is empty.
    initial.$sidebar.withLock { $0.setWorkspace(nil, for: repoB) }
    initial.applyPostReduceCacheRecomputes()

    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.setActiveWorkspace("ws-2"))
    await store.receive(\.selectWorktree)

    #expect(store.state.selectedWorktreeID == nil)
  }

  @Test func rememberedSelectionThatNoLongerExistsFallsBackToFirstVisibleRow() async {
    var initial = twoWorkspaceState(active: "ws-1", selected: worktreeID(repoA))
    initial.$sidebar.withLock {
      $0.rememberSelection(WorktreeID("\(self.repoB.rawValue)/deleted"), for: "ws-2")
    }
    initial.applyPostReduceCacheRecomputes()

    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.setActiveWorkspace("ws-2"))
    await store.receive(\.selectWorktree)

    #expect(store.state.selectedWorktreeID == worktreeID(repoB))
  }

  @Test func archivedRememberedSelectionFallsBackToFirstVisibleRow() async {
    let feature = WorktreeID("\(repoB.rawValue)/feature")
    var initial = twoWorkspaceState(
      repositories: [makeRepository(repoA), makeRepository(repoB, extraBranches: ["feature"])],
      active: "ws-1",
      selected: worktreeID(repoA)
    )
    initial.$sidebar.withLock {
      $0.archive(worktree: feature, in: self.repoB, from: .unpinned, at: Date(timeIntervalSince1970: 0))
      $0.rememberSelection(feature, for: "ws-2")
    }
    initial.applyPostReduceCacheRecomputes()

    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.setActiveWorkspace("ws-2"))
    await store.receive(\.selectWorktree)

    // The archived row isn't rendered, so restoring it would select nothing.
    #expect(store.state.selectedWorktreeID == worktreeID(repoB))
  }

  // MARK: - Fixtures

  private func worktreeID(_ repositoryID: Repository.ID, _ name: String = "main") -> Worktree.ID {
    WorktreeID("\(repositoryID.rawValue)/\(name)")
  }

  /// Reconciled two-repo state with repoA in "ws-1" and repoB in "ws-2", so a
  /// switch between the two always changes which repository is visible.
  private func twoWorkspaceState(
    repositories: [Repository]? = nil,
    active: SidebarState.Workspace.ID?,
    selected: Worktree.ID?
  ) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State(
      reconciledRepositories: repositories ?? [makeRepository(repoA), makeRepository(repoB)]
    )
    state.$sidebar.withLock { sidebar in
      sidebar.addWorkspace(.init(id: "ws-1", name: "Work"))
      sidebar.addWorkspace(.init(id: "ws-2", name: "Side"))
      sidebar.setWorkspace("ws-1", for: self.repoA)
      sidebar.setWorkspace("ws-2", for: self.repoB)
      sidebar.activeWorkspaceID = active
    }
    state.setSingleWorktreeSelection(selected)
    state.applyPostReduceCacheRecomputes()
    return state
  }

  private func makeRepository(_ id: Repository.ID, extraBranches: [String] = []) -> Repository {
    let root = URL(fileURLWithPath: id.rawValue)
    let main = Worktree(
      id: WorktreeID("\(id.rawValue)/main"),
      name: "main",
      detail: "",
      workingDirectory: root,
      repositoryRootURL: root
    )
    let extras = extraBranches.map { branch in
      Worktree(
        id: WorktreeID("\(id.rawValue)/\(branch)"),
        name: branch,
        detail: "",
        workingDirectory: root.appending(path: branch),
        repositoryRootURL: root
      )
    }
    return Repository(
      id: id,
      rootURL: root,
      name: Repository.name(for: root),
      worktrees: IdentifiedArray(uniqueElements: [main] + extras)
    )
  }

  private func makeState(repositories: [Repository]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: repositories)
    state.repositoryRoots = repositories.map(\.rootURL)
    state.$sidebar.withLock { sidebar in
      for repository in repositories {
        sidebar.sections[repository.id] = .init()
      }
    }
    return state
  }
}
