import ComposableArchitecture
import SwiftUI

/// Sidebar toolbar button that opens a terminal in the home folder, outside any
/// project. See `RepositoriesFeature.homeTerminalReducer`.
struct HomeTerminalButton: View {
  let store: StoreOf<RepositoriesFeature>

  var body: some View {
    Button {
      store.send(.openHomeTerminal)
    } label: {
      Label("Home Terminal", systemImage: "house")
    }
    .labelStyle(.iconOnly)
    .help("Open a terminal in your home folder (~), outside any project")
  }
}
