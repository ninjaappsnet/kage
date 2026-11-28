import Foundation

/// What the remote worktree view offers for the host's Claude accounts. Pure.
nonisolated enum RemoteKageClaudeAccounts {
  /// The accounts the account menus list: none until the host reports a second
  /// one (a single account leaves nothing to choose), or when it predates them.
  static func menuAccounts(_ accounts: [HostSnapshot.ClaudeAccountInfo]?) -> [HostSnapshot.ClaudeAccountInfo] {
    guard let accounts, accounts.count > 1 else { return [] }
    return accounts
  }

  /// The account the tab's session runs as: the one it started under, else the
  /// host's default for a tab that predates the report. Nil when the account it
  /// names is gone from the host.
  static func currentAccountID(of tab: HostSnapshot.Tab, accounts: [HostSnapshot.ClaudeAccountInfo]) -> String? {
    if let id = tab.claudeAccountID {
      return accounts.contains { $0.id == id } ? id : nil
    }
    return accounts.first(where: \.isDefault)?.id
  }

  /// The account name the tab strip shows after the title, when there is a choice.
  static func tagName(of tab: HostSnapshot.Tab, accounts: [HostSnapshot.ClaudeAccountInfo]) -> String? {
    guard accounts.count > 1, let id = tab.claudeAccountID else { return nil }
    return accounts.first { $0.id == id }?.name
  }
}
