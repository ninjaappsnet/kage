import CryptoKit
import Foundation

/// Read-only access to the login Claude Code stores for an account in the login
/// Keychain, used only to ask Anthropic how much of the plan limits it has used.
///
/// Claude Code writes the item through `/usr/bin/security`, which therefore sits
/// on the item's access list, so reading it through the same tool needs no
/// Keychain prompt. Kage never writes the item and never refreshes the token:
/// refreshing rotates the refresh token, which would log Claude Code out.
nonisolated enum ClaudeCredentials {
  struct OAuthToken: Equatable, Sendable {
    var accessToken: String
    var expiresAt: Date?

    func isExpired(now: Date) -> Bool {
      guard let expiresAt else { return false }
      return expiresAt <= now
    }
  }

  /// `Claude Code-credentials` for `~/.claude`; other config directories get a
  /// suffix of the first 8 hex digits of sha256 of the exact `CLAUDE_CONFIG_DIR`
  /// string, which is why account paths are stored without a trailing slash.
  static func keychainService(for account: ClaudeAccount) -> String {
    let base = "Claude Code-credentials"
    guard let path = account.configDirectoryPath else { return base }
    let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    return "\(base)-\(digest.prefix(8))"
  }

  static func parseToken(_ json: String) -> OAuthToken? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let oauth = object["claudeAiOauth"] as? [String: Any],
      let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty
    else { return nil }
    let expiresAt = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    return OAuthToken(accessToken: accessToken, expiresAt: expiresAt)
  }

  /// The stored token, or nil when the account has no login in the Keychain.
  static func readToken(for account: ClaudeAccount) async -> OAuthToken? {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", keychainService(for: account), "-w"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    return await withCheckedContinuation { continuation in
      process.terminationHandler = { process in
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, let json = String(data: data, encoding: .utf8) else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: parseToken(json.trimmingCharacters(in: .whitespacesAndNewlines)))
      }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(returning: nil)
      }
    }
  }

  static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

  /// The account's current usage. Throws `ClaudeUsageError` for a missing or
  /// expired login and for any non-200 answer.
  static func fetchUsage(for account: ClaudeAccount, now: Date = .now) async throws -> ClaudeUsage {
    guard let token = await readToken(for: account) else { throw ClaudeUsageError.notLoggedIn }
    guard !token.isExpired(now: now) else { throw ClaudeUsageError.tokenExpired }
    var request = URLRequest(url: usageURL, timeoutInterval: 20)
    request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw ClaudeUsageError.httpStatus(status) }
    return try ClaudeUsage.decode(data)
  }
}
