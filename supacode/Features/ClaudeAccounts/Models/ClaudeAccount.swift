import Foundation

/// Stable identifier of a `ClaudeAccount`; `ClaudeAccount.mainID` for `~/.claude`.
typealias ClaudeAccountID = String

/// One Claude Code login Kage can start terminal sessions under.
///
/// The main account is the user's ordinary `~/.claude` and is never stored: it is
/// implied, and sessions using it get no `CLAUDE_CONFIG_DIR` at all. Every other
/// account owns a config directory under `~/.kage/claude-accounts/`, whose
/// history, memory, settings, plugins and skills are links back into `~/.claude`
/// (see `ClaudeAccountLayout`), so only the login and account identity differ.
nonisolated struct ClaudeAccount: Codable, Equatable, Hashable, Identifiable, Sendable {
  /// Reserved identifier for the implied `~/.claude` account.
  static let mainID: ClaudeAccountID = "main"

  var id: ClaudeAccountID
  var name: String
  /// Absolute path of the account's config directory; `nil` for the main account.
  /// Never moves after creation: Claude Code keys the Keychain login to this path.
  var configDirectoryPath: String?

  var isMain: Bool { id == Self.mainID }

  var configDirectoryURL: URL? {
    configDirectoryPath.map { URL(filePath: $0, directoryHint: .isDirectory) }
  }

  static func main() -> Self {
    Self(id: mainID, name: "Main", configDirectoryPath: nil)
  }

  /// `~/.claude`, the hub every other account links into.
  static func hubDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    homeDirectory.appending(path: ".claude", directoryHint: .isDirectory)
  }

  /// Where Claude Code keeps this account's `.claude.json` (identity, user MCP servers).
  /// The main account's lives beside the hub, not inside it.
  func globalStateURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
    if let configDirectoryURL {
      return configDirectoryURL.appending(path: ".claude.json", directoryHint: .notDirectory)
    }
    return homeDirectory.appending(path: ".claude.json", directoryHint: .notDirectory)
  }

  /// Claude Code reads its config directory from this variable.
  static let configDirectoryVariable = "CLAUDE_CONFIG_DIR"
}
