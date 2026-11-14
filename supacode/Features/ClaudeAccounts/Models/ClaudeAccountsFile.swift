import Dependencies
import Foundation
import Sharing
import SupacodeSettingsShared

/// Persisted Claude account configuration, stored in
/// `~/.config/kage/claude-accounts.json`. Deliberately outside `config.json` and
/// `kage.json`: account choices are personal and must never be committed to a
/// repository, and a separate file keeps this fork-only feature off upstream's
/// settings schema.
nonisolated struct ClaudeAccountsFile: Codable, Equatable, Sendable {
  /// Non-main accounts, in display order.
  var accounts: [ClaudeAccount] = []
  /// Account new terminal tabs use when nothing more specific applies.
  var defaultAccountID: ClaudeAccountID = ClaudeAccount.mainID
  /// Repository root path → account. Overrides the default.
  var repositoryAccountIDs: [String: ClaudeAccountID] = [:]
  /// Terminal tab UUID → account, for tabs opened with "New Tab with Claude Account".
  /// Overrides everything. Kept so a tab restored after relaunch recreates its
  /// session under the same account.
  var tabAccountIDs: [String: ClaudeAccountID] = [:]
  /// User-scope MCP servers as of the last successful sync, the common ancestor for
  /// the three-way merge in `ClaudeMCPServerSync`. `nil` until the first sync.
  var mcpServersBaseline: [String: JSONValue]?
  /// Accounts seen logged in at least once. Only these get "log in again"
  /// reminders, so an account the user never finished setting up stays quiet.
  var loggedInAccountIDs: Set<ClaudeAccountID> = []
  /// Last login reminder per account, to send at most one a day.
  var lastReminderAt: [ClaudeAccountID: Date] = [:]

  init() {}

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accounts = try container.decodeIfPresent([ClaudeAccount].self, forKey: .accounts) ?? []
    defaultAccountID = try container.decodeIfPresent(String.self, forKey: .defaultAccountID) ?? ClaudeAccount.mainID
    repositoryAccountIDs = try container.decodeIfPresent([String: String].self, forKey: .repositoryAccountIDs) ?? [:]
    tabAccountIDs = try container.decodeIfPresent([String: String].self, forKey: .tabAccountIDs) ?? [:]
    mcpServersBaseline = try container.decodeIfPresent([String: JSONValue].self, forKey: .mcpServersBaseline)
    loggedInAccountIDs = try container.decodeIfPresent(Set<String>.self, forKey: .loggedInAccountIDs) ?? []
    lastReminderAt = try container.decodeIfPresent([String: Date].self, forKey: .lastReminderAt) ?? [:]
  }

  /// Main first, then the stored accounts.
  var allAccounts: [ClaudeAccount] {
    [ClaudeAccount.main()] + accounts
  }

  func account(id: ClaudeAccountID?) -> ClaudeAccount? {
    guard let id else { return nil }
    return allAccounts.first { $0.id == id }
  }

  /// The account a new session in `tabID` of the repository at `repositoryRootPath`
  /// runs under: tab assignment, then repository override, then default. An
  /// assignment naming a removed account falls through to the next level.
  func resolvedAccount(tabID: UUID?, repositoryRootPath: String?) -> ClaudeAccount {
    if let tabID, let account = account(id: tabAccountIDs[tabID.uuidString]) {
      return account
    }
    if let repositoryRootPath, let account = account(id: repositoryAccountIDs[repositoryRootPath]) {
      return account
    }
    return account(id: defaultAccountID) ?? ClaudeAccount.main()
  }

  /// Drops every reference to `accountID` so removed accounts leave no dangling choice.
  mutating func removeAccount(_ accountID: ClaudeAccountID) {
    guard accountID != ClaudeAccount.mainID else { return }
    accounts.removeAll { $0.id == accountID }
    if defaultAccountID == accountID { defaultAccountID = ClaudeAccount.mainID }
    repositoryAccountIDs = repositoryAccountIDs.filter { $0.value != accountID }
    tabAccountIDs = tabAccountIDs.filter { $0.value != accountID }
    loggedInAccountIDs.remove(accountID)
    lastReminderAt[accountID] = nil
  }

  /// Forgets tab assignments for tabs that no longer exist.
  mutating func pruneTabAssignments(keeping liveTabIDs: Set<UUID>) {
    let live = Set(liveTabIDs.map(\.uuidString))
    tabAccountIDs = tabAccountIDs.filter { live.contains($0.key) }
  }
}

nonisolated extension SupacodePaths {
  static var claudeAccountsFileURL: URL {
    configBaseDirectory.appending(path: "claude-accounts.json", directoryHint: .notDirectory)
  }

  /// Parent of every non-main account's config directory.
  static var claudeAccountsDirectory: URL {
    baseDirectory.appending(path: "claude-accounts", directoryHint: .isDirectory)
  }
}

/// Reads and writes `claude-accounts.json` through the shared settings-file storage
/// (in-memory in tests). Absent or undecodable both serve an empty file.
nonisolated struct ClaudeAccountsFileKey: SharedKey {
  private static let logger = SupaLogger("ClaudeAccounts")

  let url: URL

  init(url: URL = SupacodePaths.claudeAccountsFileURL) {
    self.url = url
  }

  var id: URL { url }

  func load(context _: LoadContext<ClaudeAccountsFile>, continuation: LoadContinuation<ClaudeAccountsFile>) {
    @Dependency(\.settingsFileStorage) var storage
    guard let data = try? storage.load(url) else {
      continuation.resumeReturningInitialValue()
      return
    }
    guard let file = try? JSONDecoder().decode(ClaudeAccountsFile.self, from: data) else {
      Self.logger.error("claude-accounts.json present but undecodable; serving an empty file.")
      continuation.resumeReturningInitialValue()
      return
    }
    continuation.resume(returning: file)
  }

  func subscribe(
    context _: LoadContext<ClaudeAccountsFile>,
    subscriber _: SharedSubscriber<ClaudeAccountsFile>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(_ value: ClaudeAccountsFile, context _: SaveContext, continuation: SaveContinuation) {
    @Dependency(\.settingsFileStorage) var storage
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try storage.save(try encoder.encode(value), url)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }
}

nonisolated extension SharedReaderKey where Self == ClaudeAccountsFileKey.Default {
  static var claudeAccountsFile: Self {
    Self[ClaudeAccountsFileKey(), default: ClaudeAccountsFile()]
  }
}
