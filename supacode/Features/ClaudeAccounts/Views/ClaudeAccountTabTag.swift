import Sharing
import SupacodeSettingsShared
import SwiftUI

/// The Claude account a terminal tab's session runs under, shown after the tab
/// title once more than one account exists. Reads the account each surface
/// actually started with, so it stays right after the default or a repository
/// override changes, and follows renames live. Renders nothing for content
/// that isn't a terminal session.
struct ClaudeAccountTabTag: View {
  let contentID: UUID

  @SharedReader(.claudeAccountsFile) private var file

  var body: some View {
    if let label = Self.label(
      contentID: contentID, file: file, accountIDs: ClaudeSurfaceAccountRegistry.shared.accountIDs)
    {
      Text(label)
        .appFont(.caption2)
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(.quaternary, in: .capsule)
        .fixedSize()
        .layoutPriority(1)
        .help("Claude Code in this tab runs as \(label)")
        .accessibilityLabel("Claude account \(label)")
    }
  }

  /// The account name to show, or nil with a single account (nothing to tell
  /// apart) or for a surface whose account is unknown or was removed.
  static func label(
    contentID: UUID,
    file: ClaudeAccountsFile,
    accountIDs: [UUID: ClaudeAccountID]
  ) -> String? {
    guard file.allAccounts.count > 1, let account = file.account(id: accountIDs[contentID]) else { return nil }
    return account.name
  }
}
