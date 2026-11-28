import Foundation

/// How Kage gets an account's expired access token renewed: by Claude Code
/// itself, never by Kage.
///
/// Renewing spends the refresh token and Anthropic rotates it, so whoever renews
/// must store the new pair where every session of that account finds it. Claude
/// Code does that under its own per-account lock and writes the Keychain entry;
/// running sessions of the same account re-read that entry before renewing
/// themselves and take the newer token. Kage renewing on its own would race them
/// and could leave a session holding a spent refresh token, which logs it out.
///
/// `claude doctor` makes no model request (it uses no plan quota) and renews an
/// expired token on start. Checked on Claude Code 2.1.332, 2026-11-28. Nothing
/// documents that, so a release that stops doing it only leaves the usage
/// panel's "Updates when Claude Code next runs as this account" in place.
nonisolated enum ClaudeAccessTokenRenewal {
  static let arguments = ["doctor"]
  /// It takes about 1.5 s; a run past this is stuck (say, waiting for a terminal).
  static let timeLimit: Duration = .seconds(60)
}
