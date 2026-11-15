import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import OrderedCollections
import Testing

@testable import supacode

@MainActor
struct HomeTerminalTests {
  private static func folderRepository(at url: URL) -> Repository {
    Repository(
      id: RepositoryID(url.path(percentEncoded: false)),
      rootURL: url,
      name: url.lastPathComponent,
      worktrees: IdentifiedArray(uniqueElements: [
        Worktree(
          id: Repository.folderWorktreeID(for: url),
          name: url.lastPathComponent,
          detail: "",
          workingDirectory: url,
          repositoryRootURL: url
        )
      ]),
      isGitRepository: false
    )
  }

  @Test(.dependencies) func homeAlreadyInTheSidebarIsSelected() async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let repository = Self.folderRepository(at: home)
    let saved = LockIsolated(0)
    let store = TestStore(initialState: RepositoriesFeature.State(reconciledRepositories: [repository])) {
      RepositoriesFeature()
    } withDependencies: {
      $0[RepositoryPersistenceClient.self].saveRoots = { _ in saved.withValue { $0 += 1 } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.openHomeTerminal)
    await store.receive(\.selectWorktree)
    #expect(store.state.selectedWorktreeID == Repository.folderWorktreeID(for: home))
    #expect(saved.value == 0)
  }

  @Test(.dependencies) func loadedHomeIsTitledAndSelected() async {
    let home = URL(fileURLWithPath: "/tmp/kage-home-test", isDirectory: true)
    let repository = Self.folderRepository(at: home)
    let store = TestStore(initialState: RepositoriesFeature.State(reconciledRepositories: [repository])) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.homeTerminalLoaded(home))
    await store.receive(\.selectWorktree)
    #expect(store.state.sidebar.sections[repository.id]?.title == "Home")
    #expect(store.state.selectedWorktreeID == Repository.folderWorktreeID(for: home))
  }

  @Test(.dependencies) func aCustomTitleIsKept() async {
    let home = URL(fileURLWithPath: "/tmp/kage-home-test", isDirectory: true)
    let repository = Self.folderRepository(at: home)
    var state = RepositoriesFeature.State(reconciledRepositories: [repository])
    state.$sidebar.withLock { $0.sections[repository.id, default: .init()].title = "My Home" }
    let store = TestStore(initialState: state) { RepositoriesFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.homeTerminalLoaded(home))
    await store.receive(\.selectWorktree)
    #expect(store.state.sidebar.sections[repository.id]?.title == "My Home")
  }
}
