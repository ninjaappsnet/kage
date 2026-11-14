import Foundation
import Sharing

/// The environment a new terminal session gets so `claude` started in it runs as
/// the chosen account. Called once per surface at creation; a session that is
/// already running (a restored zmx session) keeps the account it started with.
nonisolated enum ClaudeAccountEnvironment {
  /// Variables to add for a session in `tabID` of a worktree whose repository root
  /// is `repositoryRootURL`. Empty for the main account, and for remote worktrees,
  /// whose sessions run on another machine where these local paths mean nothing.
  static func variables(
    tabID: UUID?,
    repositoryRootURL: URL?,
    isRemote: Bool,
    file: ClaudeAccountsFile
  ) -> [String: String] {
    guard !isRemote else { return [:] }
    let account = file.resolvedAccount(
      tabID: tabID,
      repositoryRootPath: repositoryRootURL.map { normalizedPath($0.path(percentEncoded: false)) }
    )
    guard let directory = account.configDirectoryPath else { return [:] }
    return [ClaudeAccount.configDirectoryVariable: directory]
  }

  /// Reads the persisted choices; the surface factory's entry point.
  @MainActor
  static func variables(tabID: UUID?, worktree: Worktree?) -> [String: String] {
    guard let worktree else { return [:] }
    @SharedReader(.claudeAccountsFile) var file
    return variables(
      tabID: tabID,
      repositoryRootURL: worktree.repositoryRootURL,
      isRemote: worktree.localWorkingDirectory == nil,
      file: file
    )
  }

  /// One spelling per path, whichever side (Settings list, live worktree, a
  /// directory URL with its trailing slash) produced it. Load-bearing for account
  /// directories: Claude Code keys the Keychain login to the exact
  /// `CLAUDE_CONFIG_DIR` string, so `/a/b` and `/a/b/` would be two logins.
  static func normalizedPath(_ path: String) -> String {
    var normalized = URL(filePath: path).standardizedFileURL.path(percentEncoded: false)
    while normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
    return normalized
  }
}
