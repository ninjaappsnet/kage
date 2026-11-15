import ComposableArchitecture
import SwiftUI

/// File → New Tab with Claude Account ▸ <account>. Hidden until a second account
/// exists, since with only the main account there is nothing to choose.
struct ClaudeAccountCommands: Commands {
  @Bindable var store: StoreOf<AppFeature>

  var body: some Commands {
    CommandGroup(after: .newItem) {
      let accounts = store.claudeAccounts.file.allAccounts
      if accounts.count > 1 {
        let worktree = store.repositories.worktree(for: store.repositories.selectedWorktreeID)
        Menu("New Tab with Claude Account") {
          ForEach(accounts) { account in
            Button(store.claudeAccounts.menuTitle(for: account)) {
              guard let worktree else { return }
              store.send(.claudeAccounts(.newTabRequested(account.id, worktree)))
            }
            .help("Open a terminal tab where claude runs as \(account.name)")
          }
        }
        .disabled(worktree == nil || worktree?.isMissing == true || worktree?.localWorkingDirectory == nil)
        // Acts on the selected tab, resolved when chosen: reading the layout here
        // would rebuild the menu on every layout change, so no current-account check.
        Menu("Restart Tab with Claude Account") {
          ForEach(accounts) { account in
            Button(store.claudeAccounts.menuTitle(for: account)) {
              guard let worktree else { return }
              store.send(.claudeAccounts(.restartTabRequested(account.id, worktree, tabID: nil)))
            }
            .help("End the selected tab's session and start a new one where claude runs as \(account.name)")
          }
        }
        .disabled(worktree == nil || worktree?.isMissing == true || worktree?.localWorkingDirectory == nil)
      }
    }
  }
}
