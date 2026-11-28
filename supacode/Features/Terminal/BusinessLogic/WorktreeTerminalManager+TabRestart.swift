import ComposableArchitecture
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared

/// Fork-owned: the terminal side of `TerminalClient.Command.restartTab`.
extension WorktreeTerminalManager {
  private static let restartLogger = SupaLogger("TerminalTabRestart")

  /// Replaces the tab's terminal with a fresh shell under a new content id, so
  /// the surface factory resolves its environment again (the tab's Claude
  /// account included) and zmx starts a new session instead of reattaching the
  /// old one, which `LayoutFeature.replaceTabContent` kills. The tab keeps its
  /// id, title and position. When `resume`'s agent was on the old surface, the
  /// new shell runs its command. `focus` false (a restart asked for by a viewing
  /// Mac) leaves this Mac's selected tab and keyboard focus alone.
  func restartTab(in worktree: Worktree, tabID: TabID, resume: TerminalTabRestart.Resume?, focus: Bool = true) {
    // A remote session's environment lives on the other machine.
    guard worktree.localWorkingDirectory != nil else {
      Self.restartLogger.warning("restartTab refused for remote worktree \(worktree.id)")
      return
    }
    guard let tab = layoutState(for: worktree.id)?.layout.pane(containingTab: tabID)?.tabs[id: tabID] else {
      Self.restartLogger.warning("restartTab: tab \(tabID.rawValue) not found in worktree \(worktree.id)")
      return
    }
    // A script tab owns its command, and other kinds have no shell to restart.
    guard !tab.isLocked, tab.content.kind == .terminal else {
      Self.restartLogger.warning("restartTab refused for tab \(tabID.rawValue): not a plain terminal")
      return
    }
    let oldContentID = tab.content.id
    let live = ContentRuntime.liveValue.content(for: oldContentID)
    // The live surface knows the shell's current folder; a dormant or
    // never-woken one falls back to what the layout recorded.
    let workingDirectory = TerminalTabRestart.workingDirectory(of: (live?.snapshot() ?? tab.content).state)
    // Presence records are not gated by the badge setting, unlike the chrome.
    let agents = appStore?.withState { $0.agentPresence.bySurface[oldContentID.rawValue] } ?? []
    // Read before the replace below ends the process: Claude Code comes back the
    // way it was started (variables, flags, the same conversation).
    let relaunch = ClaudeTabRestart.relaunch(
      resume: resume,
      agentsOnSurface: agents,
      pids: appStore?.withState {
        $0.agentPresence.records[.init(agent: .claude, surfaceID: oldContentID.rawValue)]?.pids
      } ?? []
    )
    let input = TerminalTabRestart.initialInput(
      resume: resume, agentsOnSurface: agents, relaunchCommand: relaunch?.command)
    if let relaunch, input != nil {
      ClaudeRelaunchEnvironment.stage(relaunch.environment, forTab: tabID.rawValue)
    }
    // The reported title dies with the old chrome; hand it to the tab so the
    // label does not flash back to its creation-time name.
    if let title = live?.chrome?.reportedTitle, !title.isEmpty {
      sendLayout(worktree.id, .runtime(.titleCommitted(id: oldContentID, title: title)))
    }
    let host = host(for: worktree)
    sendLayout(
      worktree.id,
      .replaceTabContent(
        id: tabID, content: TerminalTabRestart.seed(workingDirectory: workingDirectory, initialInput: input))
    )
    guard focus else { return }
    sendLayout(worktree.id, .selectTab(id: tabID))
    host.focusSelectedTab()
  }
}
