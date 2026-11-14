import Foundation

/// `claude auth status --json`, trimmed to what Kage shows and reminds about.
nonisolated struct ClaudeAuthStatus: Decodable, Equatable, Sendable {
  var loggedIn: Bool
  var authMethod: String?
  var email: String?
  var orgName: String?
  var subscriptionType: String?
  /// When the stored login stops refreshing and `/login` is needed again.
  var loginExpiresAt: Date?

  init(
    loggedIn: Bool,
    authMethod: String? = nil,
    email: String? = nil,
    orgName: String? = nil,
    subscriptionType: String? = nil,
    loginExpiresAt: Date? = nil
  ) {
    self.loggedIn = loggedIn
    self.authMethod = authMethod
    self.email = email
    self.orgName = orgName
    self.subscriptionType = subscriptionType
    self.loginExpiresAt = loginExpiresAt
  }

  private enum CodingKeys: String, CodingKey {
    case loggedIn, authMethod, email, orgName, subscriptionType, loginExpiresAt
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    loggedIn = try container.decodeIfPresent(Bool.self, forKey: .loggedIn) ?? false
    authMethod = try container.decodeIfPresent(String.self, forKey: .authMethod)
    email = try container.decodeIfPresent(String.self, forKey: .email)
    orgName = try container.decodeIfPresent(String.self, forKey: .orgName)
    subscriptionType = try container.decodeIfPresent(String.self, forKey: .subscriptionType)
    // A malformed timestamp drops the field, not the whole status.
    loginExpiresAt = (try? container.decodeIfPresent(String.self, forKey: .loginExpiresAt))
      .flatMap { $0 }
      .flatMap(Self.parseDate)
  }

  static func decode(_ json: String) throws -> Self {
    try JSONDecoder().decode(Self.self, from: Data(json.utf8))
  }

  private static func parseDate(_ string: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) { return date }
    return ISO8601DateFormatter().date(from: string)
  }

  /// How long before `loginExpiresAt` Kage starts reminding.
  static let reminderLeadTime: Duration = .seconds(3 * 24 * 60 * 60)

  enum Health: Equatable, Sendable {
    case loggedIn
    case expiringSoon(Date)
    case expired
    case loggedOut
  }

  func health(now: Date) -> Health {
    guard loggedIn else { return .loggedOut }
    guard let loginExpiresAt else { return .loggedIn }
    if loginExpiresAt <= now { return .expired }
    let lead = TimeInterval(Self.reminderLeadTime.components.seconds)
    return loginExpiresAt.timeIntervalSince(now) <= lead ? .expiringSoon(loginExpiresAt) : .loggedIn
  }
}
