import Foundation
import SupacodeSettingsShared

/// Restarting a terminal tab: its content is replaced by a fresh one under a new
/// content id (so a new zmx session, never a reattach of the old), keeping the
/// tab itself. Fork-owned; the layout side is `LayoutFeature.replaceTabContent`.
nonisolated enum TerminalTabRestart {
  /// A command the new shell runs when `agent` was present on the old surface,
  /// so an agent session carries over the restart (`claude --continue`).
  nonisolated struct Resume: Equatable, Sendable {
    var agent: SkillAgent
    var command: String
  }

  /// The new shell's initial input: the resume command, terminated so it
  /// submits, when its agent was on the old surface; nil otherwise.
  static func initialInput(resume: Resume?, agentsOnSurface: Set<SkillAgent>) -> String? {
    guard let resume, agentsOnSurface.contains(resume.agent) else { return nil }
    let command = resume.command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else { return nil }
    return command + "\n"
  }

  /// The replacement content: a fresh terminal in the old one's folder. The
  /// input rides the live-only launch override, which persistence strips, so a
  /// later relaunch never replays it.
  static func seed(workingDirectory: String?, initialInput: String?) -> ContentState {
    .terminal(
      TerminalContentState(
        workingDirectory: workingDirectory,
        launch: initialInput.map { LaunchOverride(initialInput: $0) }
      )
    )
  }

  /// The folder a terminal snapshot last reported; nil for other content kinds.
  static func workingDirectory(of state: ContentState) -> String? {
    guard case .terminal(let terminal) = state else { return nil }
    return terminal.workingDirectory
  }
}
