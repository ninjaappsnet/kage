import Foundation

/// How much of its plan limits a Claude account has used, as reported by the
/// endpoint behind Claude Code's `/usage` (`api.anthropic.com/api/oauth/usage`).
///
/// The endpoint is undocumented, so everything here fails soft: an unknown or
/// missing window decodes as nil, and callers show nothing rather than an error.
nonisolated struct ClaudeUsage: Equatable, Sendable {
  struct Window: Equatable, Sendable {
    /// 0 to 100, as the endpoint reports it. Not clamped: `percentLabel` is.
    var percentUsed: Double
    var resetsAt: Date?

    /// Whole percent, clamped to 0...100: "42%".
    var percentLabel: String {
      "\(Int(min(max(percentUsed, 0), 100).rounded()))%"
    }
  }

  /// The rolling five-hour session window; absent on plans and moments without one.
  var fiveHour: Window?
  /// The weekly window across all models.
  var sevenDay: Window?

  static func decode(_ data: Data) throws -> Self {
    let payload = try JSONDecoder().decode(Payload.self, from: data)
    return Self(fiveHour: payload.fiveHour?.window, sevenDay: payload.sevenDay?.window)
  }

  private struct Payload: Decodable {
    var fiveHour: RawWindow?
    var sevenDay: RawWindow?

    private enum CodingKeys: String, CodingKey {
      case fiveHour = "five_hour"
      case sevenDay = "seven_day"
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      // One malformed window must not hide the other.
      fiveHour = (try? container.decodeIfPresent(RawWindow.self, forKey: .fiveHour)) ?? nil
      sevenDay = (try? container.decodeIfPresent(RawWindow.self, forKey: .sevenDay)) ?? nil
    }
  }

  private struct RawWindow: Decodable {
    var utilization: Double?
    var resetsAt: String?

    private enum CodingKeys: String, CodingKey {
      case utilization
      case resetsAt = "resets_at"
    }

    var window: Window? {
      utilization.map { Window(percentUsed: $0, resetsAt: resetsAt.flatMap(ClaudeUsage.parseDate)) }
    }
  }

  /// ISO 8601 with any number of fractional digits; the endpoint sends
  /// microseconds, which `ISO8601DateFormatter` rejects outright.
  static func parseDate(_ string: String) -> Date? {
    guard let dot = string.firstIndex(of: "."), let timeStart = string.firstIndex(of: "T"), dot > timeStart else {
      return ISO8601DateFormatter().date(from: string)
    }
    let digits = string[string.index(after: dot)...].prefix { $0.isNumber }
    let zone = string[string.index(after: dot)...].dropFirst(digits.count)
    guard !digits.isEmpty, let whole = ISO8601DateFormatter().date(from: String(string[..<dot] + zone)),
      let fraction = Double("0." + digits)
    else { return nil }
    return whole.addingTimeInterval(fraction)
  }
}

nonisolated enum ClaudeUsageError: LocalizedError, Equatable {
  /// No stored login for the account.
  case notLoggedIn
  /// The stored access token has expired. Kage never refreshes it (refreshing
  /// rotates the login Claude Code itself depends on); the next `claude` run does.
  case tokenExpired
  case httpStatus(Int)

  var errorDescription: String? {
    switch self {
    case .notLoggedIn: "Not logged in."
    case .tokenExpired: "Usage is updated the next time Claude Code runs with this account."
    case .httpStatus(let status): "The usage request failed (HTTP \(status))."
    }
  }
}

extension ClaudeAccountsFeature.State {
  /// An account's name for menus, with its weekly usage when known: "Work — 42% weekly".
  func menuTitle(for account: ClaudeAccount) -> String {
    Self.menuTitle(for: account, usage: usages[account.id])
  }

  static func menuTitle(for account: ClaudeAccount, usage: ClaudeAccountsFeature.UsageSnapshot?) -> String {
    guard let weekly = usage?.usage?.sevenDay else { return account.name }
    return "\(account.name) — \(weekly.percentLabel) weekly"
  }
}
