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

  /// The surface factory's entry point. A tab or split opened from a live surface
  /// takes that surface's account and keeps it as the tab's own assignment, so it
  /// survives a relaunch; everything else resolves as `variables(tabID:...)` does.
  @MainActor
  static func variables(request: ContentRequest, worktree: Worktree?) -> [String: String] {
    guard let worktree, worktree.localWorkingDirectory != nil else { return [:] }
    @Shared(.claudeAccountsFile) var file
    let tabID = request.tabID.rawValue
    let requested = request.origin == .tab ? ClaudeSurfaceAccounts.takeRequestedAccount() : nil
    if let inherited = inheritedAccountID(
      tabID: tabID,
      origin: request.origin,
      inheritedFrom: request.inheritedFrom?.rawValue,
      requested: requested,
      file: file,
      surfaceAccounts: ClaudeSurfaceAccounts.byContentID
    ) {
      $file.withLock { $0.tabAccountIDs[tabID.uuidString] = inherited }
    }
    let account = file.resolvedAccount(
      tabID: tabID,
      repositoryRootPath: normalizedPath(worktree.repositoryRootURL.path(percentEncoded: false))
    )
    ClaudeSurfaceAccounts.byContentID[request.contentID.rawValue] = account.id
    // A restart's carried-over secrets (`ClaudeRelaunchEnvironment`); the
    // account's own directory always wins.
    let relaunched = ClaudeRelaunchEnvironment.take(forTab: tabID)
    guard let directory = account.configDirectoryPath else { return relaunched }
    return relaunched.merging([ClaudeAccount.configDirectoryVariable: directory]) { _, account in account }
  }

  /// The account a new tab or split takes: the one explicitly `requested` from the
  /// tab strip menu, else the account of the surface it was opened from. Nil when
  /// the tab has its own assignment, is a restore, or the account is unknown or gone.
  static func inheritedAccountID(
    tabID: UUID,
    origin: ContentOrigin,
    inheritedFrom: UUID?,
    requested: ClaudeAccountID? = nil,
    file: ClaudeAccountsFile,
    surfaceAccounts: [UUID: ClaudeAccountID]
  ) -> ClaudeAccountID? {
    guard origin != .restored, file.tabAccountIDs[tabID.uuidString] == nil else { return nil }
    let accountID = requested ?? inheritedFrom.flatMap { surfaceAccounts[$0] }
    guard let accountID, file.account(id: accountID) != nil else { return nil }
    return accountID
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

/// The account each surface built this launch started under, by content id. In
/// memory only: after a relaunch, restored surfaces record themselves again as
/// they are rebuilt.
@MainActor
enum ClaudeSurfaceAccounts {
  static var byContentID: [UUID: ClaudeAccountID] {
    get { ClaudeSurfaceAccountRegistry.shared.accountIDs }
    set { ClaudeSurfaceAccountRegistry.shared.accountIDs = newValue }
  }

  /// How long a tab strip request waits for its tab. The tab is built within a
  /// run loop turn or two; a request that outlives this was for a tab that never
  /// came, and must not land on an unrelated one later.
  static let requestLifetime: Duration = .seconds(5)

  private static var requested: (accountID: ClaudeAccountID, at: ContinuousClock.Instant)?

  /// Makes the next new tab start under `accountID`; see `takeRequestedAccount`.
  static func requestAccountForNextTab(_ accountID: ClaudeAccountID) {
    requested = (accountID, .now)
  }

  /// The pending request, consumed, if it is still fresh.
  static func takeRequestedAccount(now: ContinuousClock.Instant = .now) -> ClaudeAccountID? {
    defer { requested = nil }
    guard let requested, now - requested.at <= requestLifetime else { return nil }
    return requested.accountID
  }
}

/// Observable storage behind `ClaudeSurfaceAccounts.byContentID`, so a tab's
/// account tag appears once its surface is built. Written only at surface
/// creation, so observing the whole map costs nothing in steady state.
@MainActor
@Observable
final class ClaudeSurfaceAccountRegistry {
  static let shared = ClaudeSurfaceAccountRegistry()

  var accountIDs: [UUID: ClaudeAccountID] = [:]

  nonisolated deinit {}
}
