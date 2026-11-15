import ComposableArchitecture
import SwiftUI

extension EnvironmentValues {
  /// The Claude Accounts store, for menus deep in the terminal views that offer
  /// accounts. Nil where the app does not provide it (previews, tests).
  @Entry var claudeAccountsStore: StoreOf<ClaudeAccountsFeature>?
}

/// "New Tab with Claude Account" at the top of a tab strip's split menu. Opens the
/// tab through the strip's own new-tab path, so it lands in the same pane and
/// working directory as `+`, only under the chosen account. Renders nothing until
/// a second account exists.
struct ClaudeAccountNewTabMenuSection: View {
  let newTab: () -> Void

  @Environment(\.claudeAccountsStore) private var store

  var body: some View {
    if let store, store.file.allAccounts.count > 1 {
      Menu("New Tab with Claude Account", systemImage: "person.crop.circle") {
        ForEach(store.file.allAccounts) { account in
          Button(ClaudeAccountsFeature.State.menuTitle(for: account, usage: store.usages[account.id])) {
            ClaudeSurfaceAccounts.requestAccountForNextTab(account.id)
            newTab()
          }
          .help("Open a terminal tab here where claude runs as \(account.name)")
        }
      }
      Divider()
    }
  }
}
