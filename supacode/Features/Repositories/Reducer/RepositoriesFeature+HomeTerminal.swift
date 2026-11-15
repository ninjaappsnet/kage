import ComposableArchitecture
import Foundation
import OrderedCollections
import Sharing
import SupacodeSettingsShared

/// The sidebar's "Home Terminal" button: a terminal at `~` that belongs to no
/// project. Terminals always hang off a sidebar entry, so home is added as an
/// ordinary folder entry named "Home" the first time, and selected after that.
extension RepositoriesFeature {
  static var homeTerminalReducer: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .openHomeTerminal:
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        if let worktreeID = state.homeWorktreeID(home: home) {
          return .send(.selectWorktree(worktreeID, focusTerminal: true))
        }
        // Not `.openRepositories`: its nested-folder check is for folders picked
        // by hand, and the selection needs to wait for the load to finish.
        return .run { send in
          @Dependency(RepositoryPersistenceClient.self) var persistence
          let existing = RepositoryPathNormalizer.normalize(await persistence.loadRoots())
          let merged = RepositoryPathNormalizer.normalize(existing + [home.path(percentEncoded: false)])
          await persistence.saveRoots(merged)
          let roots = merged.map { URL(fileURLWithPath: $0) }
          let result = await RepositoriesFeature().loadRepositoriesData(roots)
          await send(.gitEnvironmentChanged(result.environmentError))
          await send(
            .openRepositoriesFinished(result.repositories, failures: result.failures, invalidRoots: [], roots: roots)
          )
          await send(.homeTerminalLoaded(home))
        }
        .cancellable(id: HomeTerminalCancelID.load, cancelInFlight: true)

      case .homeTerminalLoaded(let home):
        guard let repository = state.homeRepository(home: home),
          let worktreeID = state.homeWorktreeID(home: home)
        else { return .none }
        if state.sidebar.customTitle(for: repository) == nil {
          state.$sidebar.withLock { $0.sections[repository.id, default: .init()].title = "Home" }
        }
        return .send(.selectWorktree(worktreeID, focusTerminal: true))

      default:
        return .none
      }
    }
  }
}

private nonisolated enum HomeTerminalCancelID: Hashable, Sendable {
  case load
}

extension RepositoriesFeature.State {
  /// The local sidebar entry rooted exactly at `home`, git or folder.
  func homeRepository(home: URL) -> Repository? {
    let homePath = RepositoryPathNormalizer.normalize([home.path(percentEncoded: false)])
    return repositories.first { repository in
      repository.host == nil
        && RepositoryPathNormalizer.normalize([repository.rootURL.path(percentEncoded: false)]) == homePath
    }
  }

  /// The row to select for home: the folder's synthetic worktree, or the main
  /// worktree when `~` happens to be a git repository (a dotfiles checkout).
  func homeWorktreeID(home: URL) -> Worktree.ID? {
    guard let repository = homeRepository(home: home) else { return nil }
    return repository.isGitRepository ? repository.worktrees.first?.id : repository.folderRowID
  }
}
