import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Settings → Claude Accounts: several Claude Code logins sharing one `~/.claude`.
///
/// Owns account creation (directory + links, see `ClaudeAccountLayout`), in-app
/// login, login-health reminders, and the user MCP server sync. Which account a
/// terminal session uses is resolved at surface creation by
/// `ClaudeAccountEnvironment`, from the choices stored here.
@Reducer
struct ClaudeAccountsFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.claudeAccountsFile) var file = ClaudeAccountsFile()
    var statuses: [ClaudeAccountID: StatusEntry] = [:]
    /// Last plan usage fetched per logged-in account. A failed fetch keeps the
    /// previous value: the endpoint is undocumented and a stale number beats none.
    var usages: [ClaudeAccountID: UsageSnapshot] = [:]
    /// Why the last usage fetch failed, per account; cleared by the next success.
    var usageFailures: [ClaudeAccountID: ClaudeUsageError] = [:]
    /// When Kage last had Claude Code renew each account's access token.
    var accessTokenRenewals: [ClaudeAccountID: Date] = [:]
    var newAccountName = ""
    var isAddAccountPresented = false
    var login: LoginState?
    var mcpSync: MCPSyncState = .idle
    var errorMessage: String?
    @Presents var alert: AlertState<Alert>?
    /// Restart-tab confirmation, presented by the main window (not Settings).
    @Presents var restartTabAlert: AlertState<RestartTabAlert>?

    var isNewAccountNameValid: Bool {
      let name = newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
      return !name.isEmpty && !file.allAccounts.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
  }

  enum StatusEntry: Equatable, Sendable {
    case loading
    case loaded(ClaudeAuthStatus)
    case failed(String)
  }

  struct UsageSnapshot: Equatable, Sendable {
    var usage: ClaudeUsage?
    var fetchedAt: Date
  }

  enum MCPSyncState: Equatable, Sendable {
    case idle
    case syncing
    case synced(Date)
    case failed(String)
  }

  struct LoginState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
      case running
      case succeeded
      case failed(String)
    }

    var accountID: ClaudeAccountID
    var transcript = ""
    var code = ""
    var phase: Phase = .running

    /// The fallback URL the CLI prints when the browser didn't open by itself.
    var authorizationURL: URL? {
      transcript
        .split(whereSeparator: \.isWhitespace)
        .first { $0.hasPrefix("https://") }
        .flatMap { URL(string: String($0)) }
    }

    var isWaitingForCode: Bool {
      phase == .running && transcript.contains("Paste code")
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case tick
    case refreshStatuses
    case statusLoaded(ClaudeAccountID, Result<ClaudeAuthStatus, Error>)
    case refreshUsage(ClaudeAccountID)
    case usageLoaded(ClaudeAccountID, Result<ClaudeUsage, Error>)
    /// The sidebar usage panel came on screen: keep its numbers fresh while it shows.
    case usagePanelAppeared
    case usagePanelDisappeared
    case refreshLoggedInUsages
    case accessTokenRenewed(ClaudeAccountID, Result<Void, Error>)
    case addAccountButtonTapped
    case addAccountCancelled
    case addAccountConfirmed
    case accountPrepared(ClaudeAccount, Result<ClaudeAccountLayout.Report, Error>)
    case renameAccount(ClaudeAccountID, String)
    case removeAccountButtonTapped(ClaudeAccountID)
    case setDefaultAccount(ClaudeAccountID)
    case setRepositoryAccount(repositoryRootPath: String, ClaudeAccountID?)
    case loginButtonTapped(ClaudeAccountID)
    case loginEvent(ClaudeLoginSession.Event)
    case loginFailedToStart(String)
    case loginCodeChanged(String)
    case loginCodeSubmitted
    case loginDismissed
    case logoutButtonTapped(ClaudeAccountID)
    case logoutCompleted(ClaudeAccountID, Result<Void, Error>)
    case syncMCPServersButtonTapped
    case mcpSyncCompleted(Result<ClaudeMCPServerSync.Servers, Error>)
    case newTabRequested(ClaudeAccountID, Worktree)
    /// Restart a tab under another account; nil targets the selected tab.
    case restartTabRequested(ClaudeAccountID, Worktree, tabID: TabID?)
    case restartTabAlert(PresentationAction<RestartTabAlert>)
    case alert(PresentationAction<Alert>)
    /// From a viewing Mac (`kage host claude-tab new`): the tab about to be
    /// created with this id runs Claude Code as the account.
    case tabAssignmentRequested(tabID: UUID, ClaudeAccountID)
    /// A restart already confirmed (by this Mac's alert, or by the viewing Mac
    /// that asked through `kage host claude-tab restart`).
    case restartTabConfirmed(ClaudeAccountID, Worktree, tabID: TabID, focus: Bool)
  }

  enum Alert: Equatable {
    case confirmRemove(ClaudeAccountID)
  }

  /// How often statuses, reminders and the MCP sync re-run in the background.
  nonisolated static let refreshInterval: Duration = .seconds(30 * 60)
  /// Minimum gap between two usage requests for the same account, however often
  /// Settings is opened: the endpoint rate-limits.
  nonisolated static let usageMinimumInterval: TimeInterval = 60
  /// How often the sidebar usage panel re-fetches while it is visible.
  nonisolated static let usagePanelRefreshInterval: Duration = .seconds(5 * 60)
  /// Minimum gap between two access-token renewals for the same account.
  nonisolated static let accessTokenRenewalInterval: TimeInterval = 60 * 60
  /// Minimum gap between two reminders about the same account.
  nonisolated static let reminderInterval: TimeInterval = 24 * 60 * 60

  private nonisolated enum CancelID: Hashable, Sendable {
    case periodicRefresh
    case usage(ClaudeAccountID)
    case usagePanel
    case login
    case mcpSync
  }

  @Dependency(ClaudeAccountsClient.self) private var client
  @Dependency(TerminalClient.self) private var terminalClient
  @Dependency(SystemNotificationClient.self) private var notifications
  @Dependency(\.continuousClock) private var clock
  @Dependency(\.date.now) private var now
  @Dependency(\.uuid) private var uuid
  @Dependency(\.defaultAppStorage) private var defaultAppStorage

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        // Tab assignments outlive their tabs; drop the ones no saved layout holds.
        if case .file(let layouts) = LayoutsFile.readPersisted(from: defaultAppStorage) {
          state.$file.withLock { _ = $0.pruneTabAssignments(toTabsIn: layouts) }
        }
        let accounts = state.file.accounts
        return .merge(
          // Re-link on every launch: Claude Code replacing a linked file with a
          // real one (an atomic save) would otherwise silently stop sharing it.
          .run { [client] send in
            for account in accounts {
              guard let directory = account.configDirectoryURL else { continue }
              await send(.accountPrepared(account, Result { try await client.prepareDirectory(directory) }))
            }
            await send(.refreshStatuses)
            await send(.syncMCPServersButtonTapped)
          },
          .run { [clock] send in
            for await _ in clock.timer(interval: Self.refreshInterval) {
              await send(.tick)
            }
          }
          .cancellable(id: CancelID.periodicRefresh, cancelInFlight: true)
        )

      case .tick:
        return .merge(.send(.refreshStatuses), .send(.syncMCPServersButtonTapped))

      case .refreshStatuses:
        let accounts = state.file.allAccounts
        for account in accounts where state.statuses[account.id] == nil {
          state.statuses[account.id] = .loading
        }
        return .run { [client] send in
          await withTaskGroup(of: Void.self) { group in
            for account in accounts {
              group.addTask {
                await send(.statusLoaded(account.id, Result { try await client.authStatus(account) }))
              }
            }
          }
        }

      case .statusLoaded(let id, .success(let status)):
        state.statuses[id] = .loaded(status)
        if status.loggedIn, !state.file.loggedInAccountIDs.contains(id) {
          state.$file.withLock { _ = $0.loggedInAccountIDs.insert(id) }
        }
        let reminder = remindIfNeeded(state: &state, accountID: id, status: status)
        guard status.loggedIn else {
          // Another login may come next; never show its predecessor's numbers.
          state.usages[id] = nil
          return .merge(reminder, .cancel(id: CancelID.usage(id)))
        }
        return .merge(reminder, .send(.refreshUsage(id)))

      case .refreshUsage(let id):
        guard let account = state.file.account(id: id) else { return .none }
        if let last = state.usages[id]?.fetchedAt, now.timeIntervalSince(last) < Self.usageMinimumInterval {
          return .none
        }
        // Stamped up front so a burst of refreshes sends one request.
        state.usages[id, default: UsageSnapshot(usage: nil, fetchedAt: now)].fetchedAt = now
        return .run { [client] send in
          await send(.usageLoaded(id, Result { try await client.usage(account) }))
        }
        .cancellable(id: CancelID.usage(id), cancelInFlight: true)

      case .usageLoaded(let id, .success(let usage)):
        guard state.file.account(id: id) != nil else { return .none }
        state.usages[id] = UsageSnapshot(usage: usage, fetchedAt: now)
        state.usageFailures[id] = nil
        return .none

      case .usageLoaded(let id, .failure(let error)):
        guard state.file.account(id: id) != nil else { return .none }
        // Kept beside the last good usage, so the panel can say why it is missing.
        state.usageFailures[id] = error as? ClaudeUsageError
        return renewAccessTokenIfNeeded(id, after: error, &state)

      case .usagePanelAppeared:
        return .run { [clock] send in
          await send(.refreshLoggedInUsages)
          for await _ in clock.timer(interval: Self.usagePanelRefreshInterval) {
            await send(.refreshLoggedInUsages)
          }
        }
        .cancellable(id: CancelID.usagePanel, cancelInFlight: true)

      case .usagePanelDisappeared:
        return .cancel(id: CancelID.usagePanel)

      case .accessTokenRenewed(let id, .success):
        // The fetch this follows failed: try again now, past the once-a-minute throttle.
        state.usages[id]?.fetchedAt = .distantPast
        return .send(.refreshUsage(id))

      case .accessTokenRenewed(let id, .failure(let error)):
        Self.logger.warning("Renewing the access token of Claude account \(id) failed: \(error.localizedDescription)")
        return .none

      case .refreshLoggedInUsages:
        let ids = state.file.allAccounts.map(\.id).filter { id in
          if case .loaded(let status) = state.statuses[id] { return status.loggedIn }
          return false
        }
        return .merge(ids.map { .send(.refreshUsage($0)) })

      case .statusLoaded(let id, .failure(let error)):
        state.statuses[id] = .failed(error.localizedDescription)
        return .none

      case .addAccountButtonTapped:
        state.newAccountName = ""
        state.isAddAccountPresented = true
        return .none

      case .addAccountCancelled:
        state.isAddAccountPresented = false
        return .none

      case .addAccountConfirmed:
        guard state.isNewAccountNameValid else { return .none }
        let name = state.newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = uuid().uuidString
        let directory = Self.uniqueDirectory(
          for: name, existing: Set(state.file.accounts.compactMap(\.configDirectoryPath)))
        let account = ClaudeAccount(
          id: id, name: name,
          configDirectoryPath: ClaudeAccountEnvironment.normalizedPath(directory.path(percentEncoded: false)))
        state.isAddAccountPresented = false
        state.$file.withLock { $0.accounts.append(account) }
        state.statuses[id] = .loading
        return .run { [client] send in
          await send(.accountPrepared(account, Result { try await client.prepareDirectory(directory) }))
          await send(.loginButtonTapped(id))
        }

      case .accountPrepared(_, .success):
        return .none

      case .accountPrepared(let account, .failure(let error)):
        state.errorMessage = "Couldn't set up \(account.name)'s folder: \(error.localizedDescription)"
        return .none

      case .renameAccount(let id, let name):
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        state.$file.withLock { file in
          if id == ClaudeAccount.mainID {
            file.mainAccountName = trimmed
            return
          }
          guard let index = file.accounts.firstIndex(where: { $0.id == id }) else { return }
          file.accounts[index].name = trimmed
        }
        return .none

      case .removeAccountButtonTapped(let id):
        guard let account = state.file.account(id: id), !account.isMain else { return .none }
        state.alert = AlertState {
          TextState("Remove \(account.name)?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmRemove(id)) {
            TextState("Log Out and Remove")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState(
            """
            Kage logs this account out and stops using it. Its folder stays at \
            \(account.configDirectoryPath ?? "") so nothing is lost; shared history and \
            memory live in ~/.claude and are not affected.
            """
          )
        }
        return .none

      case .alert(.presented(.confirmRemove(let id))):
        guard let account = state.file.account(id: id) else { return .none }
        state.$file.withLock { $0.removeAccount(id) }
        state.statuses[id] = nil
        state.usages[id] = nil
        return .run { [client] _ in
          try? await client.logout(account)
        }

      case .alert:
        return .none

      case .setDefaultAccount(let id):
        guard state.file.account(id: id) != nil else { return .none }
        state.$file.withLock { $0.defaultAccountID = id }
        return .none

      case .setRepositoryAccount(let repositoryRootPath, let id):
        let key = ClaudeAccountEnvironment.normalizedPath(repositoryRootPath)
        state.$file.withLock { $0.repositoryAccountIDs[key] = id }
        return .none

      case .loginButtonTapped(let id):
        guard let account = state.file.account(id: id) else { return .none }
        state.login = LoginState(accountID: id)
        return .run { [client] send in
          let events: AsyncStream<ClaudeLoginSession.Event>
          do {
            events = try await client.startLogin(account)
          } catch {
            await send(.loginFailedToStart(error.localizedDescription))
            return
          }
          for await event in events {
            await send(.loginEvent(event))
          }
        }
        .cancellable(id: CancelID.login, cancelInFlight: true)

      case .loginEvent(.output(let text)):
        state.login?.transcript += text
        return .none

      case .loginEvent(.exited(let status)):
        guard let accountID = state.login?.accountID else { return .none }
        if status == 0 {
          state.login?.phase = .succeeded
          state.statuses[accountID] = .loading
          return .merge(.send(.refreshStatuses), .send(.syncMCPServersButtonTapped))
        }
        state.login?.phase = .failed("claude auth login exited with status \(status).")
        return .none

      case .loginFailedToStart(let message):
        state.login?.phase = .failed(message)
        return .none

      case .loginCodeChanged(let code):
        state.login?.code = code
        return .none

      case .loginCodeSubmitted:
        guard let login = state.login, login.phase == .running else { return .none }
        let code = login.code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return .none }
        state.login?.code = ""
        return .run { [client] _ in
          await client.sendLoginInput(code)
        }

      case .loginDismissed:
        let wasRunning = state.login?.phase == .running
        state.login = nil
        return wasRunning
          ? .merge(.cancel(id: CancelID.login), .run { [client] _ in await client.cancelLogin() }) : .none

      case .logoutButtonTapped(let id):
        guard let account = state.file.account(id: id) else { return .none }
        state.statuses[id] = .loading
        return .run { [client] send in
          await send(.logoutCompleted(id, Result { try await client.logout(account) }))
        }

      case .logoutCompleted(let id, .success):
        // Deliberate: no reminder for an account the user logged out themselves.
        state.$file.withLock { _ = $0.loggedInAccountIDs.remove(id) }
        return .send(.refreshStatuses)

      case .logoutCompleted(_, .failure(let error)):
        state.errorMessage = error.localizedDescription
        return .send(.refreshStatuses)

      case .syncMCPServersButtonTapped:
        guard state.mcpSync != .syncing else { return .none }
        let accounts = state.file.allAccounts
        let baseline = state.file.mcpServersBaseline
        state.mcpSync = .syncing
        return .run { [client] send in
          await send(
            .mcpSyncCompleted(
              Result {
                try await Self.syncMCPServers(accounts: accounts, baseline: baseline, client: client)
              }
            )
          )
        }
        .cancellable(id: CancelID.mcpSync, cancelInFlight: true)

      case .mcpSyncCompleted(.success(let merged)):
        state.$file.withLock { $0.mcpServersBaseline = merged }
        state.mcpSync = .synced(now)
        return .none

      case .mcpSyncCompleted(.failure(let error)):
        state.mcpSync = .failed(error.localizedDescription)
        return .none

      case .newTabRequested(let accountID, let worktree):
        guard state.file.account(id: accountID) != nil, !worktree.isMissing else { return .none }
        let tabID = uuid()
        state.$file.withLock { $0.tabAccountIDs[tabID.uuidString] = accountID }
        return .run { [terminalClient] _ in
          await terminalClient.send(.createTab(worktree, runSetupScriptIfNew: false, id: tabID))
        }

      case .restartTabRequested(let accountID, let worktree, let tabID):
        return reduceRestartTabRequested(&state, accountID: accountID, worktree: worktree, tabID: tabID)

      case .restartTabAlert(let action):
        return reduceRestartTabAlert(&state, action: action)

      case .tabAssignmentRequested(let tabID, let accountID):
        guard state.file.account(id: accountID) != nil else { return .none }
        state.$file.withLock { $0.tabAccountIDs[tabID.uuidString] = accountID }
        return .none

      case .restartTabConfirmed(let accountID, let worktree, let tabID, let focus):
        return reduceRestartTabConfirmed(&state, accountID: accountID, worktree: worktree, tabID: tabID, focus: focus)
      }
    }
  }

  /// Notifies when an account needs logging in again, at most once a day per
  /// account. Accounts that were never logged in, or that the user logged out
  /// themselves, stay quiet: there is nothing to remind them about.
  private static let logger = SupaLogger("ClaudeAccounts")

  /// An expired access token while the login itself is valid: Claude Code renews
  /// it only when it next needs it, so an account no session is using shows no
  /// usage. Have Claude Code renew it (`ClaudeAccessTokenRenewal`), at most once
  /// an hour per account, so a renewal that doesn't help never loops.
  private func renewAccessTokenIfNeeded(
    _ id: ClaudeAccountID,
    after error: Error,
    _ state: inout State
  ) -> Effect<Action> {
    guard (error as? ClaudeUsageError) == .tokenExpired,
      case .loaded(let status) = state.statuses[id], status.loggedIn,
      let account = state.file.account(id: id)
    else { return .none }
    if let last = state.accessTokenRenewals[id], now.timeIntervalSince(last) < Self.accessTokenRenewalInterval {
      return .none
    }
    state.accessTokenRenewals[id] = now
    return .run { [client] send in
      await send(.accessTokenRenewed(id, Result { try await client.renewAccessToken(account) }))
    }
  }

  private func remindIfNeeded(state: inout State, accountID: ClaudeAccountID, status: ClaudeAuthStatus) -> Effect<
    Action
  > {
    guard let account = state.file.account(id: accountID) else { return .none }
    let health = status.health(now: now)
    let message: String
    switch health {
    case .loggedIn:
      return .none
    case .expiringSoon(let date):
      let when = date.formatted(.relative(presentation: .named))
      message = "The \(account.name) Claude login expires \(when). Log in again in Settings → Claude Accounts."
    case .expired, .loggedOut:
      guard state.file.loggedInAccountIDs.contains(accountID) else { return .none }
      message = "The \(account.name) Claude login has expired. Log in again in Settings → Claude Accounts."
    }
    if let last = state.file.lastReminderAt[accountID], now.timeIntervalSince(last) < Self.reminderInterval {
      return .none
    }
    let sentAt = now
    state.$file.withLock { $0.lastReminderAt[accountID] = sentAt }
    return .run { [notifications] _ in
      await notifications.send("Claude login needs attention", message, nil)
    }
  }

  /// Reads every account's servers, merges, and applies the edits. Main goes first
  /// so it wins conflicts. A read failure aborts before anything is written.
  private static func syncMCPServers(
    accounts: [ClaudeAccount],
    baseline: ClaudeMCPServerSync.Servers?,
    client: ClaudeAccountsClient
  ) async throws -> ClaudeMCPServerSync.Servers {
    var current: [(id: ClaudeAccountID, servers: ClaudeMCPServerSync.Servers)] = []
    for account in accounts {
      current.append((account.id, try await client.readMCPServers(account)))
    }
    let plan = ClaudeMCPServerSync.plan(baseline: baseline, accounts: current)
    for account in accounts {
      let operations = plan.operations[account.id] ?? []
      guard !operations.isEmpty else { continue }
      try await client.applyMCPOperations(account, operations)
    }
    return plan.merged
  }

  /// `~/.kage/claude-accounts/<slug>`, suffixed when taken. The path is fixed for
  /// the account's lifetime because Claude Code keys the Keychain login to it.
  static func uniqueDirectory(
    for name: String,
    existing: Set<String>,
    root: URL = SupacodePaths.claudeAccountsDirectory
  ) -> URL {
    let slug = Self.slug(name)
    let existing = Set(existing.map(ClaudeAccountEnvironment.normalizedPath))
    var candidate = root.appending(path: slug, directoryHint: .isDirectory)
    var suffix = 2
    while existing.contains(ClaudeAccountEnvironment.normalizedPath(candidate.path(percentEncoded: false)))
      || FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false))
    {
      candidate = root.appending(path: "\(slug)-\(suffix)", directoryHint: .isDirectory)
      suffix += 1
    }
    return candidate
  }

  static func slug(_ name: String) -> String {
    let lowered = name.lowercased()
    var result = ""
    var lastWasDash = false
    for scalar in lowered.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
        result.unicodeScalars.append(scalar)
        lastWasDash = false
      } else if !lastWasDash, !result.isEmpty {
        result.append("-")
        lastWasDash = true
      }
    }
    while result.hasSuffix("-") { result.removeLast() }
    return result.isEmpty ? "account" : result
  }
}
