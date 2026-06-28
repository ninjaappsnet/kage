import ComposableArchitecture
import Dependencies
import Foundation
import OrderedCollections
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

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

  // MARK: - Fixtures

  private func makeRepository(_ id: Repository.ID) -> Repository {
    let root = URL(fileURLWithPath: id.rawValue)
    let main = Worktree(
      id: WorktreeID("\(id.rawValue)/main"),
      name: "main",
      detail: "",
      workingDirectory: root,
      repositoryRootURL: root
    )
    return Repository(
      id: id,
      rootURL: root,
      name: Repository.name(for: root),
      worktrees: IdentifiedArray(uniqueElements: [main])
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
