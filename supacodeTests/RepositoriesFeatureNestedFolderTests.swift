import ComposableArchitecture
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

@MainActor
struct RepositoriesFeatureNestedFolderTests {
  private let parentURL = URL(fileURLWithPath: "/tmp/nested-parent")
  private let nestedURL = URL(fileURLWithPath: "/tmp/nested-parent/shoot-assistant")

  private func makeStore(
    persistedRoots: [String]
  ) -> TestStoreOf<RepositoriesFeature> {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { persistedRoots }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.gitClient.repoRoot = { _ in URL(fileURLWithPath: "/tmp/nested-parent") }
      $0.gitClient.rootDirectoryExists = { _ in true }
      $0.gitClient.isGitRepository = { url in
        url.standardizedFileURL.path(percentEncoded: false) == "/tmp/nested-parent"
      }
      $0.gitClient.worktrees = { root in
        [
          Worktree(
            id: WorktreeID(root.path(percentEncoded: false)),
            kind: .git,
            name: "main",
            detail: "",
            workingDirectory: root,
            repositoryRootURL: root,
            isAttached: true
          )
        ]
      }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off
    return store
  }

  /// The reported bug. Adding `parent/shoot-assistant` used to resolve to
  /// `parent`, dedupe against the existing row, and finish with no sidebar
  /// change and no message.
  @Test func addingAFolderInsideAnAlreadyAddedRepoPromptsInsteadOfSilentlyDoingNothing() async {
    let store = makeStore(persistedRoots: ["/tmp/nested-parent"])

    await store.send(.openRepositories([nestedURL]))
    await store.receive(\.presentNestedFolderPrompt)
    await store.finish()

    let prompt = store.state.nestedFolderPrompt
    #expect(prompt?.candidates.count == 1)
    #expect(prompt?.candidates.first?.folderURL == nestedURL.standardizedFileURL)
    #expect(prompt?.candidates.first?.parentRootURL == parentURL.standardizedFileURL)
    // The parent was already there; nothing new was registered behind the sheet.
    #expect(store.state.repositoryRoots == [parentURL.standardizedFileURL])
  }

  /// The unregistered-parent case keeps the upstream convenience: pick any
  /// subdirectory, get the repo, no dialog.
  @Test func addingAFolderInsideAnUnknownRepoAddsTheRepoWithoutPrompting() async {
    let store = makeStore(persistedRoots: [])

    await store.send(.openRepositories([nestedURL]))
    await store.skipReceivedActions()
    await store.finish()

    #expect(store.state.nestedFolderPrompt == nil)
    #expect(store.state.repositoryRoots == [parentURL.standardizedFileURL])
  }

  /// Confirming the sheet registers the picked path verbatim — it must not go
  /// back through `repoRoot`, or it would collapse into the parent again.
  @Test func confirmingThePromptRegistersThePickedFolderVerbatim() async {
    let store = makeStore(persistedRoots: ["/tmp/nested-parent"])
    store.dependencies.gitClient.isGitRepository = { _ in false }

    await store.send(.addResolvedRoots([nestedURL]))
    await store.skipReceivedActions()
    await store.finish()

    #expect(store.state.repositoryRoots.contains(nestedURL.standardizedFileURL))
    #expect(store.state.repositories[id: RepositoryID(nestedURL.path(percentEncoded: false))] != nil)
  }

  @Test func promptDelegateDismissesAndForwardsTheFolders() async {
    var initial = RepositoriesFeature.State()
    initial.nestedFolderPrompt = NestedFolderPromptFeature.State(
      candidates: [
        NestedFolderCandidate(folderURL: nestedURL, parentRootURL: parentURL)
      ]
    )
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.loadRoots = { [] }
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.gitClient.rootDirectoryExists = { _ in true }
      $0.gitClient.isGitRepository = { _ in false }
      $0.analyticsClient.capture = { _, _ in }
    }
    store.exhaustivity = .off

    await store.send(.nestedFolderPrompt(.presented(.delegate(.addFolders([nestedURL])))))
    #expect(store.state.nestedFolderPrompt == nil)
    await store.receive(\.addResolvedRoots)
    await store.finish()
  }

  @Test func promptCancelJustDismisses() async {
    var initial = RepositoriesFeature.State()
    initial.nestedFolderPrompt = NestedFolderPromptFeature.State(
      candidates: [
        NestedFolderCandidate(folderURL: nestedURL, parentRootURL: parentURL)
      ]
    )
    let store = TestStore(initialState: initial) { RepositoriesFeature() }
    store.exhaustivity = .off

    await store.send(.nestedFolderPrompt(.presented(.delegate(.cancel))))
    #expect(store.state.nestedFolderPrompt == nil)
    await store.finish()
  }
}
