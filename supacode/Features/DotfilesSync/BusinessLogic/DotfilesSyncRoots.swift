import Foundation

/// What gets synced. Everything is opt-in: a file outside these lists never
/// reaches the repository, which is what keeps logins (`.claude.json`, the
/// Keychain, Codex's `auth.json`), transcripts, caches and databases local.
nonisolated struct DotfilesSyncRoot: Equatable, Sendable {
  /// Folder in the repository, e.g. `claude`.
  var repoPrefix: String
  /// Folder relative to the home directory, e.g. `.claude`.
  var localPath: String
  /// Top-level files synced by exact name.
  var files: [String]
  /// Top-level files synced by extension (`md`, `sh`).
  var fileExtensions: [String] = []
  /// Top-level folders synced whole (minus the global excludes).
  var directories: [String] = []
  /// Paths inside `directories`, relative to the root, left out.
  var excludedPaths: [String] = []

  static func defaults(kageConfigPath: String?) -> [Self] {
    var roots = [
      Self(
        repoPrefix: "claude",
        localPath: ".claude",
        files: ["settings.json", "CLAUDE.md", "keybindings.json"],
        fileExtensions: ["md", "sh"],
        directories: ["agents", "commands", "output-styles", "hooks", "skills"],
        // Skills Claude itself syncs from claude.ai.
        excludedPaths: ["skills/synced"]
      ),
      Self(repoPrefix: "agents", localPath: ".agents", files: [], directories: ["skills"]),
      Self(
        repoPrefix: "codex",
        localPath: ".codex",
        files: ["AGENTS.md", "config.toml", "hooks.json"],
        directories: ["rules", "skills", "prompts"],
        // Skills Codex ships and updates itself.
        excludedPaths: ["skills/.system"]
      ),
    ]
    if let kageConfigPath {
      roots.append(Self(repoPrefix: "kage", localPath: kageConfigPath, files: ["config.ghostty"]))
    }
    return roots
  }

  /// Names skipped at any depth inside a synced folder.
  static let excludedNames: Set<String> = [".DS_Store", ".trash", "node_modules", "__pycache__", ".git"]
  static let excludedSuffixes = [".bak", ".tmp", "~", ".swp", ".log", ".orig"]
  /// Larger files are skipped: this is for settings and notes, not assets.
  static let maximumFileSize = 1_000_000

  static func isExcluded(name: String) -> Bool {
    excludedNames.contains(name) || excludedSuffixes.contains { name.hasSuffix($0) }
  }
}

/// Repository layout for per-project Claude memory: `claude-memory/<project key>/…`.
nonisolated enum DotfilesMemoryLayout {
  static let prefix = "claude-memory"
  /// Marker standing in for a nested git checkout (a skill installed by
  /// `git clone`): it holds the clone URL, and other machines clone it.
  static let nestedRepositorySuffix = ".kage-git-repo"
  /// Top-level folders of the repository the sync owns; anything else in it
  /// (README, .gitattributes) is left alone.
  static func managedPrefixes(roots: [DotfilesSyncRoot]) -> [String] {
    roots.map(\.repoPrefix) + [prefix]
  }
}
