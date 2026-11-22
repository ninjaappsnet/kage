import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct RemoteKageSidebarSelectionTests {
  private let hostID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
  private var remoteA: RemoteKageSelection { RemoteKageSelection(hostID: hostID, worktreeID: "/h/a") }
  private var remoteB: RemoteKageSelection { RemoteKageSelection(hostID: hostID, worktreeID: "/h/b") }

  private func makeWorktree(_ id: String) -> Worktree {
    Worktree(
      id: Worktree.ID(id),
      name: URL(fileURLWithPath: id).lastPathComponent,
      detail: "",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  private func makeRepository(_ worktrees: [Worktree]) -> Repository {
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    return Repository(
      id: RepositoryID(rootURL.path(percentEncoded: false)),
      rootURL: rootURL,
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }

  private func makeState(_ repositories: [Repository]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: repositories)
    state.repositoryRoots = repositories.map(\.rootURL)
    state.applyCacheRecomputes(.all)
    return state
  }

  // MARK: - Pure resolution.

  @Test func localOnlySelectionHasNoRemote() {
    let resolved = RemoteKageSidebarSelection.remoteSelection(in: [.worktree("/tmp/repo/wt1")], current: nil)
    #expect(resolved == nil)
  }

  @Test func newlyChosenRemoteRowWinsOverLocalRows() {
    let resolved = RemoteKageSidebarSelection.remoteSelection(
      in: [.worktree("/tmp/repo/wt1"), .remoteKage(remoteA)],
      current: .worktree("/tmp/repo/wt1")
    )
    #expect(resolved == remoteA)
  }

  @Test func reclickingTheCurrentRemoteRowKeepsIt() {
    let resolved = RemoteKageSidebarSelection.remoteSelection(in: [.remoteKage(remoteA)], current: .remoteKage(remoteA))
    #expect(resolved == remoteA)
  }

  @Test func extendingFromTheCurrentRemoteRowToALocalRowDropsTheRemote() {
    let resolved = RemoteKageSidebarSelection.remoteSelection(
      in: [.remoteKage(remoteA), .worktree("/tmp/repo/wt1")],
      current: .remoteKage(remoteA)
    )
    #expect(resolved == nil)
  }

  @Test func extendingFromTheCurrentRemoteRowToAnotherRemoteRowPicksTheNewOne() {
    let resolved = RemoteKageSidebarSelection.remoteSelection(
      in: [.remoteKage(remoteA), .remoteKage(remoteB)],
      current: .remoteKage(remoteA)
    )
    #expect(resolved == remoteB)
  }

  @Test func remoteSelectionProjections() {
    #expect(SidebarSelection.remoteKage(remoteA).remoteKageSelection == remoteA)
    #expect(SidebarSelection.remoteKage(remoteA).worktreeID == nil)
    #expect(SidebarSelection.remoteKage(remoteA).failedRepositoryID == nil)
    #expect(SidebarSelection.worktree("/x").remoteKageSelection == nil)
  }

  // MARK: - RepositoriesFeature.

  @Test func selectingARemoteRowReplacesTheLocalSelection() async {
    let wt1 = makeWorktree("/tmp/repo/wt1")
    var initialState = makeState([makeRepository([wt1])])
    initialState.selection = .worktree(wt1.id)
    initialState.sidebarSelectedWorktreeIDs = [wt1.id]
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }

    await store.send(.selectionChanged([.remoteKage(remoteA)], focusTerminal: true)) {
      $0.selection = .remoteKage(self.remoteA)
      $0.sidebarSelectedWorktreeIDs = []
      $0.applyPostReduceCacheRecomputes([.selectedWorktreeSlice, .sidebarSelectionSlice])
    }
    await store.receive(\.delegate.selectedWorktreeChanged)
    #expect(store.state.sidebarSelections == [.remoteKage(remoteA)])
    #expect(store.state.selectedWorktreeID == nil)
    #expect(store.state.isShowingRemoteKage)
  }

  @Test func selectingALocalRowReplacesTheRemoteSelection() async {
    let wt1 = makeWorktree("/tmp/repo/wt1")
    var initialState = makeState([makeRepository([wt1])])
    initialState.selection = .remoteKage(remoteA)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.selectionChanged([.remoteKage(remoteA), .worktree(wt1.id)]))
    await store.receive(\.delegate.selectedWorktreeChanged)
    #expect(store.state.selection == .worktree(wt1.id))
    #expect(store.state.sidebarSelectedWorktreeIDs == [wt1.id])
    #expect(!store.state.isShowingRemoteKage)
  }

  @Test func repositoriesReloadKeepsTheRemoteSelection() async {
    let wt1 = makeWorktree("/tmp/repo/wt1")
    let repository = makeRepository([wt1])
    var initialState = makeState([repository])
    initialState.selection = .remoteKage(remoteA)
    let store = TestStore(initialState: initialState) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.repositoriesLoaded([repository], failures: [], roots: [repository.rootURL], animated: false))
    await store.skipReceivedActions()
    #expect(store.state.selection == .remoteKage(remoteA))
  }

  // MARK: - AppFeature mirror into RemoteKageFeature.

  private func makeAppStore(
    _ repositories: RepositoriesFeature.State,
    remoteSelection: RemoteKageSelection? = nil
  ) -> TestStoreOf<AppFeature> {
    var state = AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    state.remoteKage.selection = remoteSelection
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in }
      $0.worktreeInfoWatcher.send = { _ in }
    }
    store.exhaustivity = .off
    return store
  }

  @Test(.dependencies) func remoteSidebarSelectionIsForwardedToRemoteKage() async {
    let wt1 = makeWorktree("/tmp/repo/wt1")
    var repositories = makeState([makeRepository([wt1])])
    repositories.selection = .worktree(wt1.id)
    let store = makeAppStore(repositories)

    await store.send(.repositories(.selectionChanged([.remoteKage(remoteA)])))
    await store.receive(\.remoteKage.select, remoteA)
    await store.skipReceivedActions()
  }

  @Test(.dependencies) func localSidebarSelectionClearsTheRemoteKageSelection() async {
    let wt1 = makeWorktree("/tmp/repo/wt1")
    var repositories = makeState([makeRepository([wt1])])
    repositories.selection = .remoteKage(remoteA)
    let store = makeAppStore(repositories, remoteSelection: remoteA)

    await store.send(.repositories(.selectionChanged([.worktree(wt1.id)])))
    await store.receive(\.remoteKage.select, nil)
    await store.skipReceivedActions()
  }

  @Test(.dependencies) func selectingARemoteRowKeepsTheLastFocusedLocalWorktree() async {
    let wt1 = makeWorktree("/tmp/repo/wt1")
    var repositories = makeState([makeRepository([wt1])])
    repositories.selection = .worktree(wt1.id)
    repositories.$sidebar.withLock { $0.focusedWorktreeID = wt1.id }
    let store = makeAppStore(repositories)

    await store.send(.repositories(.selectionChanged([.remoteKage(remoteA)])))
    await store.skipReceivedActions()
    await store.finish()
    // Relaunch restores the last local worktree, as returning from the archived list does.
    #expect(store.state.repositories.sidebar.focusedWorktreeID == wt1.id)
  }
}
