import Foundation

/// Last line of defense before a file leaves the machine: settings can carry API
/// keys in an `env` block, and one leaked into a git history stays there. A file
/// that trips this is not synced, and the user is told which one.
nonisolated enum DotfilesSecretScanner {
  static func containsSecret(_ text: String) -> Bool {
    patterns.contains { text.contains($0) }
  }

  nonisolated(unsafe) private static let patterns: [Regex<Substring>] = [
    // Provider-specific prefixes.
    /sk-ant-[A-Za-z0-9_\-]{16,}/,
    /sk-(?:proj-)?[A-Za-z0-9]{32,}/,
    /gh[pousr]_[A-Za-z0-9]{30,}/,
    /github_pat_[A-Za-z0-9_]{30,}/,
    /AKIA[0-9A-Z]{16}/,
    /xox[abposr]-[A-Za-z0-9\-]{10,}/,
    /AIza[0-9A-Za-z_\-]{35}/,
    /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    // A long opaque value assigned to something called a key, token, secret or password.
    #/
      (?i)(?:api[_-]?key|access[_-]?token|auth[_-]?token|secret|password|passwd|bearer)
      ["']?\s*[:=]\s*["']?
      # A reference to an environment variable names a secret; it doesn't hold one.
      (?!process\.env\.|os\.environ|env\.)
      [A-Za-z0-9_\-.+\/=]{20,}
    /#,
  ]
}
