import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Asks what to do with folders that resolved to an already-tracked parent
/// repository, instead of deduping them away in silence.
@Reducer
struct NestedFolderPromptFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    var candidates: [NestedFolderCandidate]
    var addAction: NestedFolderAddAction = .addAsFolder
    var ignoreTarget: NestedFolderIgnoreTarget = .localExclude
    var isSubmitting = false
    var errorMessage: String?

    var id: String { candidates.map(\.id).joined(separator: "\n") }

    /// Every candidate shares a parent in the common single-pick case; the
    /// summary falls back to a count when a multi-select spans repositories.
    var parentSummary: String {
      let names = Set(candidates.map(\.parentName)).sorted()
      return names.count == 1 ? names[0] : "\(names.count) repositories"
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case cancelButtonTapped
    case addButtonTapped
    case setupFailed(String)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case cancel
    case addFolders([URL])
  }

  @Dependency(FolderRepositorySetupClient.self) private var folderRepositorySetup

  nonisolated private static let logger = SupaLogger("NestedFolderPrompt")

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        state.errorMessage = nil
        return .none

      case .cancelButtonTapped:
        return .send(.delegate(.cancel))

      case .addButtonTapped:
        guard !state.isSubmitting else { return .none }
        let candidates = state.candidates
        let addAction = state.addAction
        let ignoreTarget = state.ignoreTarget
        state.isSubmitting = true
        state.errorMessage = nil
        return .run { [folderRepositorySetup] send in
          for candidate in candidates {
            do {
              if addAction == .createGitRepository {
                try await folderRepositorySetup.initializeRepository(candidate.folderURL)
              }
              if ignoreTarget != .doNotIgnore {
                try await folderRepositorySetup.ignoreFolder(candidate, ignoreTarget)
              }
            } catch {
              Self.logger.error(
                "Nested folder setup failed for \(candidate.id): \(error.localizedDescription)"
              )
              await send(.setupFailed("Kage couldn't set up \(candidate.folderName)."))
              return
            }
          }
          await send(.delegate(.addFolders(candidates.map(\.folderURL))))
        }

      case .setupFailed(let message):
        state.isSubmitting = false
        state.errorMessage = message
        return .none

      case .delegate:
        return .none
      }
    }
  }
}
