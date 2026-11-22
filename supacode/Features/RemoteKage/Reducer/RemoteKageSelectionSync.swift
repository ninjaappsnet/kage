import ComposableArchitecture
import Foundation

/// Mirrors the sidebar's remote Kage selection (`repositories.selection`, the
/// single source of truth for what the sidebar highlights and the detail
/// shows) into `RemoteKageFeature` as `.select`, so its reducer knows which
/// remote worktree is on screen. Every path that changes the local selection
/// (a click, a hotkey, the palette, a deeplink, a reload) lands on a
/// `.repositories` action, so checking after those is enough.
struct RemoteKageSelectionSync: Reducer {
  typealias State = AppFeature.State
  typealias Action = AppFeature.Action

  func reduce(into state: inout State, action: Action) -> Effect<Action> {
    guard case .repositories = action else { return .none }
    let shown = state.repositories.selection?.remoteKageSelection
    guard shown != state.remoteKage.selection else { return .none }
    return .send(.remoteKage(.select(shown)))
  }
}
