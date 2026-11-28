import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// "Restart Tab with Claude Account": switches an open tab to another account.
/// The account is fixed when the tab's shell starts (`CLAUDE_CONFIG_DIR` is in the
/// session environment), so switching means a new session: the tab's assignment
/// is stored first, then the terminal replaces the tab's content, and the new
/// surface resolves the assignment in `ClaudeAccountEnvironment`.
nonisolated enum ClaudeTabRestart {
  /// Claude Code running on the old surface resumes in the new shell. History
  /// (`projects/`) is shared by every account. This plain command is the
  /// fallback: `relaunch(...)` normally replays the running process instead.
  static let resume = TerminalTabRestart.Resume(agent: .claude, command: "claude --continue")

  /// The old surface's Claude Code launch replayed (`ClaudeLaunchReplay`): the
  /// variables and flags it was started with and `--resume <its session>`. Nil
  /// when the restart resumes no Claude, or the process can't be read.
  @MainActor
  static func relaunch(
    resume: TerminalTabRestart.Resume?,
    agentsOnSurface: Set<SkillAgent>,
    pids: Set<pid_t>
  ) -> ClaudeLaunchReplay.Relaunch? {
    guard resume?.agent == .claude, agentsOnSurface.contains(.claude), !pids.isEmpty else { return nil }
    return ClaudeProcessInspector.relaunch(pids: pids)
  }

  /// The account the tab's session runs as: the one its live surface started
  /// under, else what a new session in the tab would resolve to.
  static func currentAccountID(
    tabID: UUID,
    surfaceAccountID: ClaudeAccountID?,
    repositoryRootURL: URL?,
    file: ClaudeAccountsFile
  ) -> ClaudeAccountID {
    if let surfaceAccountID, file.account(id: surfaceAccountID) != nil {
      return surfaceAccountID
    }
    return file.resolvedAccount(
      tabID: tabID,
      repositoryRootPath: repositoryRootURL.map {
        ClaudeAccountEnvironment.normalizedPath($0.path(percentEncoded: false))
      }
    ).id
  }

  static func alert(
    account: ClaudeAccount,
    worktree: Worktree,
    tabID: TabID
  ) -> AlertState<ClaudeAccountsFeature.RestartTabAlert> {
    AlertState {
      TextState("Restart Tab as \(account.name)?")
    } actions: {
      ButtonState(role: .destructive, action: .confirm(account.id, worktree, tabID)) {
        TextState("Restart Tab")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState(
        """
        Restarting ends this tab's terminal session and stops everything running in it, \
        such as dev servers and builds. A new shell starts in the same folder as \(account.name). \
        If Claude Code is running, it resumes the same conversation there as \(account.name), \
        started the way it was before.
        """
      )
    }
  }
}

extension ClaudeAccountsFeature {
  nonisolated enum RestartTabAlert: Equatable, Sendable {
    case confirm(ClaudeAccountID, Worktree, TabID)
  }

  /// Validates the target and asks first. `tabID` nil targets the worktree's
  /// selected tab (the File menu).
  func reduceRestartTabRequested(
    _ state: inout State,
    accountID: ClaudeAccountID,
    worktree: Worktree,
    tabID: TabID?
  ) -> Effect<Action> {
    @Dependency(TerminalClient.self) var terminalClient
    guard let account = state.file.account(id: accountID),
      !worktree.isMissing,
      worktree.localWorkingDirectory != nil,
      let tabID = tabID ?? terminalClient.selectedTabID(worktree.id),
      // Exists and is not a locked script tab.
      terminalClient.tabCanRename(worktree.id, tabID)
    else { return .none }
    state.restartTabAlert = ClaudeTabRestart.alert(account: account, worktree: worktree, tabID: tabID)
    return .none
  }

  func reduceRestartTabAlert(_ state: inout State, action: PresentationAction<RestartTabAlert>) -> Effect<Action> {
    state.restartTabAlert = nil
    guard case .presented(.confirm(let accountID, let worktree, let tabID)) = action,
      state.file.account(id: accountID) != nil
    else { return .none }
    return restartTab(&state, accountID: accountID, worktree: worktree, tabID: tabID, focus: true)
  }

  /// A viewing Mac's restart: it confirmed on its side, so no alert here, but
  /// the same checks as a local request.
  func reduceRestartTabConfirmed(
    _ state: inout State,
    accountID: ClaudeAccountID,
    worktree: Worktree,
    tabID: TabID,
    focus: Bool
  ) -> Effect<Action> {
    @Dependency(TerminalClient.self) var terminalClient
    guard state.file.account(id: accountID) != nil,
      !worktree.isMissing,
      worktree.localWorkingDirectory != nil,
      terminalClient.tabCanRename(worktree.id, tabID)
    else { return .none }
    return restartTab(&state, accountID: accountID, worktree: worktree, tabID: tabID, focus: focus)
  }

  private func restartTab(
    _ state: inout State,
    accountID: ClaudeAccountID,
    worktree: Worktree,
    tabID: TabID,
    focus: Bool
  ) -> Effect<Action> {
    @Dependency(TerminalClient.self) var terminalClient
    // Stored before the restart: the new surface reads it as it is built. Main
    // is stored explicitly too, so a repository override cannot win the tab back.
    state.$file.withLock { $0.tabAccountIDs[tabID.rawValue.uuidString] = accountID }
    return .run { [terminalClient] _ in
      await terminalClient.send(.restartTab(worktree, tabID: tabID, resume: ClaudeTabRestart.resume, focus: focus))
    }
  }
}
