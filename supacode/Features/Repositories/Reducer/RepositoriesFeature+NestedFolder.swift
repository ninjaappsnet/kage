import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// `RepositoriesFeature.swift` keeps its `CancelID` file-private (and
/// `AppFeature.swift` declares one of its own), so this flow carries its own
/// cancellation group rather than promoting either to module scope.
nonisolated private enum NestedFolderCancelID {
  case load
}

extension RepositoriesFeature {
  /// Handles folders that resolved to an already-tracked parent repository.
  /// Split out of the main reducer so the prompt's child `ifLet` runs before the
  /// delegate handler nils the presented state (mirrors the clone-form pattern).
  var nestedFolderPromptReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .presentNestedFolderPrompt(let candidates):
        guard !candidates.isEmpty else { return .none }
        state.nestedFolderPrompt = NestedFolderPromptFeature.State(candidates: candidates)
        return .none

      case .nestedFolderPrompt(.presented(.delegate(.cancel))):
        state.nestedFolderPrompt = nil
        return .none

      case .nestedFolderPrompt(.presented(.delegate(.addFolders(let urls)))):
        state.nestedFolderPrompt = nil
        return .send(.addResolvedRoots(urls))

      case .addResolvedRoots(let urls):
        guard !urls.isEmpty else { return .none }
        // Declared here rather than as a stored property: the main reducer's
        // `@Dependency` members are private to its own file.
        @Dependency(RepositoryPersistenceClient.self) var repositoryPersistence
        state.alert = nil
        // Deliberately skips `gitClient.repoRoot`: these paths were already
        // resolved (and possibly `git init`ed) by the prompt, and re-resolving a
        // plain folder would walk right back up to the parent repository.
        return .run { [repositoryPersistence] send in
          let loadedPaths = await repositoryPersistence.loadRoots()
          let existingRootPaths = RepositoryPathNormalizer.normalize(loadedPaths)
          let addedPaths = RepositoryPathNormalizer.normalize(
            urls.map { $0.standardizedFileURL.path(percentEncoded: false) }
          )
          let mergedPaths = RepositoryPathNormalizer.normalize(existingRootPaths + addedPaths)
          let mergedRoots = mergedPaths.map { URL(fileURLWithPath: $0) }
          await repositoryPersistence.saveRoots(mergedPaths)
          let loadResult = await loadRepositoriesData(mergedRoots)
          await send(.gitEnvironmentChanged(loadResult.environmentError))
          // `.openRepositoriesFinished` rather than `.repositoriesLoaded`: only
          // the former makes a brand-new repo inherit the active workspace, which
          // is the whole point of adding it while a workspace filter is on.
          await send(
            .openRepositoriesFinished(
              loadResult.repositories,
              failures: loadResult.failures,
              invalidRoots: [],
              roots: mergedRoots
            )
          )
        }
        .cancellable(id: NestedFolderCancelID.load, cancelInFlight: true)

      default:
        return .none
      }
    }
  }
}
