import Foundation

/// Which copy wins when two machines hold different versions of something
/// that isn't merged automatically.
///
/// Only Claude memory (merged by the model) and JSON settings (merged key by
/// key) reconcile on their own. Everything else (skills, agents, commands,
/// hooks, rules, CLAUDE.md, config.toml) is mostly installed or hand-picked
/// content where a line merge of two versions makes no sense, so the user picks
/// which machine's copy wins.
nonisolated enum DotfilesVersionChoice: String, Codable, Equatable, Sendable {
  /// This machine's copy replaces the synced one.
  case keepLocal
  /// The synced copy replaces this machine's (which is saved aside).
  case useRepository
}

/// Something whose copies differ, waiting for the user's choice: a whole skill
/// folder, or a single file.
nonisolated struct DotfilesVersionConflict: Equatable, Sendable, Identifiable {
  /// `agents/skills/microsoft-foundry` or `claude/CLAUDE.md`.
  var unit: String
  /// Files inside it that differ (repository paths).
  var paths: [String]

  var id: String { unit }
  var isSkill: Bool { unit.split(separator: "/").dropFirst().first == "skills" }
  /// `microsoft-foundry`, or `CLAUDE.md`.
  var name: String { String(unit.split(separator: "/").last ?? Substring(unit)) }
  /// `Claude skill`, `Codex`, `Claude`…
  var origin: String {
    let root = unit.split(separator: "/").first.map(String.init) ?? ""
    let tool = ["claude": "Claude", "agents": "Shared", "codex": "Codex", "kage": "Kage"][root] ?? root
    return isSkill ? "\(tool) skill" : tool
  }
}

nonisolated enum DotfilesConflictUnit {
  /// What the user chooses between for a repository path: the skill folder
  /// (`<root>/skills/<name>`, its nested-checkout marker included) for anything
  /// in a skill, the file itself for other files, and nil for what merges on
  /// its own (Claude memory, JSON).
  static func unit(of path: String) -> String? {
    if path.hasPrefix(DotfilesMemoryLayout.prefix + "/") || path.hasSuffix(".json") { return nil }
    let parts = path.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false)
    guard parts.count >= 3, parts[1] == "skills", !parts[2].isEmpty else { return path }
    var name = String(parts[2])
    if name.hasSuffix(DotfilesMemoryLayout.nestedRepositorySuffix) {
      name.removeLast(DotfilesMemoryLayout.nestedRepositorySuffix.count)
    }
    return "\(parts[0])/skills/\(name)"
  }
}

/// Where a pass is, for the status line and its progress bar.
nonisolated struct DotfilesSyncProgress: Equatable, Sendable {
  var message: String
  /// 0...1.
  var fraction: Double
}
