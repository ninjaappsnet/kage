import ComposableArchitecture
import SwiftUI

extension EnvironmentValues {
  /// The worktree whose tab strips sit below, for tab menus that need more than
  /// its id (its repository and whether it is remote). Nil where no worktree
  /// layout provides it (pane windows, previews).
  @Entry var claudeAccountsWorktree: Worktree?
}

/// "Restart Tab with Claude Account" in a tab's context menu. Renders nothing
/// until a second account exists, and for tabs with no plain shell to restart
/// (script tabs, file viewers). The tab's current account is checked.
struct ClaudeAccountRestartTabMenu: View {
  let tab: TabItem

  @Environment(\.claudeAccountsStore) private var store
  @Environment(\.claudeAccountsWorktree) private var worktree

  var body: some View {
    if let store, store.file.allAccounts.count > 1, tab.content.kind == .terminal, !tab.isLocked {
      let currentID = ClaudeTabRestart.currentAccountID(
        tabID: tab.id.rawValue,
        surfaceAccountID: ClaudeSurfaceAccounts.byContentID[tab.content.id.rawValue],
        repositoryRootURL: worktree?.repositoryRootURL,
        file: store.file
      )
      Divider()
      Menu("Restart Tab with Claude Account", systemImage: "arrow.clockwise") {
        ForEach(store.file.allAccounts) { account in
          let isCurrent = account.id == currentID
          Toggle(
            ClaudeAccountsFeature.State.menuTitle(for: account, usage: store.usages[account.id]),
            isOn: Binding(
              get: { isCurrent },
              set: { isOn in
                guard isOn, let worktree else { return }
                store.send(.restartTabRequested(account.id, worktree, tabID: tab.id))
              }
            )
          )
          .disabled(isCurrent)
          .help(
            isCurrent
              ? "This tab already runs as \(account.name)"
              : "End this tab's session and start a new one where claude runs as \(account.name)"
          )
        }
      }
      // Remote sessions run on another machine, where account folders mean nothing.
      .disabled(worktree == nil || worktree?.isMissing == true || worktree?.localWorkingDirectory == nil)
    }
  }
}

/// Presents the restart confirmation over the main window. Settings has its own
/// alert slot, so the two never present at once.
struct ClaudeAccountRestartTabAlertModifier: ViewModifier {
  @Bindable var store: StoreOf<ClaudeAccountsFeature>

  func body(content: Content) -> some View {
    content.alert($store.scope(state: \.restartTabAlert, action: \.restartTabAlert))
  }
}

extension View {
  func claudeAccountRestartTabAlert(store: StoreOf<ClaudeAccountsFeature>) -> some View {
    modifier(ClaudeAccountRestartTabAlertModifier(store: store))
  }
}
