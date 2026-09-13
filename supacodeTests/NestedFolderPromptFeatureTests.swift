import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
struct NestedFolderPromptFeatureTests {
  private let candidate = NestedFolderCandidate(
    folderURL: URL(fileURLWithPath: "/tmp/parent/shoot-assistant"),
    parentRootURL: URL(fileURLWithPath: "/tmp/parent")
  )

  private func makeState() -> NestedFolderPromptFeature.State {
    NestedFolderPromptFeature.State(candidates: [candidate])
  }

  /// Non-destructive default: register the folder as-is, and keep it out of the
  /// parent repo's `git status` through the local-only exclude file.
  @Test func defaultsToAddingAPlainFolderAndIgnoringLocally() {
    let state = makeState()

    #expect(state.addAction == .addAsFolder)
    #expect(state.ignoreTarget == .localExclude)
  }

  @Test func addAsFolderNeverRunsGitInit() async {
    let initCalls = LockIsolated<[URL]>([])
    let ignoreCalls = LockIsolated<[NestedFolderIgnoreTarget]>([])
    let store = TestStore(initialState: makeState()) {
      NestedFolderPromptFeature()
    } withDependencies: {
      $0.folderRepositorySetup.initializeRepository = { url in initCalls.withValue { $0.append(url) } }
      $0.folderRepositorySetup.ignoreFolder = { _, target in
        ignoreCalls.withValue { $0.append(target) }
      }
    }

    await store.send(.addButtonTapped) { $0.isSubmitting = true }
    await store.receive(\.delegate.addFolders)

    #expect(initCalls.value.isEmpty)
    #expect(ignoreCalls.value == [.localExclude])
  }

  @Test func createGitRepositoryRunsGitInitBeforeHandingTheFolderBack() async {
    let initCalls = LockIsolated<[URL]>([])
    var initial = makeState()
    initial.addAction = .createGitRepository
    initial.ignoreTarget = .doNotIgnore
    let store = TestStore(initialState: initial) {
      NestedFolderPromptFeature()
    } withDependencies: {
      $0.folderRepositorySetup.initializeRepository = { url in initCalls.withValue { $0.append(url) } }
      $0.folderRepositorySetup.ignoreFolder = { _, _ in
        Issue.record("ignoreFolder must not run when the user chose not to ignore")
      }
    }

    await store.send(.addButtonTapped) { $0.isSubmitting = true }
    await store.receive(\.delegate.addFolders)

    #expect(initCalls.value == [candidate.folderURL])
  }

  @Test func gitignoreTargetIsForwardedToTheClient() async {
    let ignoreCalls = LockIsolated<[NestedFolderIgnoreTarget]>([])
    var initial = makeState()
    initial.ignoreTarget = .gitignore
    let store = TestStore(initialState: initial) {
      NestedFolderPromptFeature()
    } withDependencies: {
      $0.folderRepositorySetup.initializeRepository = { _ in }
      $0.folderRepositorySetup.ignoreFolder = { _, target in
        ignoreCalls.withValue { $0.append(target) }
      }
    }

    await store.send(.addButtonTapped) { $0.isSubmitting = true }
    await store.receive(\.delegate.addFolders)

    #expect(ignoreCalls.value == [.gitignore])
  }

  /// A failed `git init` must not silently register a half-set-up folder: the
  /// sheet stays open with the reason.
  @Test func setupFailureKeepsTheSheetOpenWithAMessage() async {
    struct Boom: Error {}
    var initial = makeState()
    initial.addAction = .createGitRepository
    let store = TestStore(initialState: initial) {
      NestedFolderPromptFeature()
    } withDependencies: {
      $0.folderRepositorySetup.initializeRepository = { _ in throw Boom() }
      $0.folderRepositorySetup.ignoreFolder = { _, _ in }
    }

    await store.send(.addButtonTapped) { $0.isSubmitting = true }
    await store.receive(\.setupFailed) {
      $0.isSubmitting = false
      $0.errorMessage = "Kage couldn't set up shoot-assistant."
    }
  }

  @Test func cancelDelegatesWithoutTouchingTheFilesystem() async {
    let store = TestStore(initialState: makeState()) {
      NestedFolderPromptFeature()
    } withDependencies: {
      $0.folderRepositorySetup.initializeRepository = { _ in
        Issue.record("cancel must not run git init")
      }
      $0.folderRepositorySetup.ignoreFolder = { _, _ in
        Issue.record("cancel must not write an ignore entry")
      }
    }

    await store.send(.cancelButtonTapped)
    await store.receive(\.delegate.cancel)
  }
}
