import Foundation

/// Variables a restarted tab's new session gets from its environment rather
/// than from the typed relaunch line (`ClaudeLaunchReplay.Relaunch.environment`),
/// so a credential-looking value never lands in shell history or the scrollback.
/// Staged by the restart right before it replaces the tab's content and taken
/// by `ClaudeAccountEnvironment` when that content's surface is built, within
/// the same run loop turn; a stage that outlives `lifetime` is dropped.
@MainActor
enum ClaudeRelaunchEnvironment {
  static let lifetime: Duration = .seconds(5)

  private static var staged: [UUID: (variables: [String: String], at: ContinuousClock.Instant)] = [:]

  static func stage(_ variables: [String: String], forTab tabID: UUID, now: ContinuousClock.Instant = .now) {
    guard !variables.isEmpty else {
      staged[tabID] = nil
      return
    }
    staged[tabID] = (variables, now)
  }

  /// The variables staged for `tabID`, consumed, if still fresh.
  static func take(forTab tabID: UUID, now: ContinuousClock.Instant = .now) -> [String: String] {
    guard let entry = staged.removeValue(forKey: tabID), now - entry.at <= lifetime else { return [:] }
    return entry.variables
  }
}
