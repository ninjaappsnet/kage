import Dependencies
import Foundation
import Sharing
import SupacodeSettingsShared

/// Another Mac running Kage that this Mac views (Settings → Remote Hosts).
nonisolated struct RemoteKageHost: Codable, Equatable, Sendable, Identifiable, Hashable {
  var id: UUID
  /// Human-friendly name shown in the sidebar, e.g. "Mini 1".
  var name: String
  /// SSH login user.
  var username: String
  /// DNS name or IP address.
  var address: String

  init(id: UUID = UUID(), name: String, username: String, address: String) {
    self.id = id
    self.name = name
    self.username = username
    self.address = address
  }

  /// `user@address` for ssh. Only valid for a host that passed validation.
  var sshDestination: String { "\(username)@\(address)" }
}

// MARK: - Validation

/// Why a host field was rejected. The values reach ssh's argv, so validation is
/// strict: a field can never be read by ssh as an option (leading hyphen) or carry
/// whitespace, shell metacharacters or non-ASCII text.
nonisolated enum RemoteKageHostIssue: Equatable, Sendable {
  case required
  case duplicate
  case leadingHyphen
  case invalid

  /// `invalid` is field specific, so the caller supplies its wording.
  func message(invalid invalidText: String) -> String {
    switch self {
    case .required: "Required."
    case .duplicate: "Another host already uses this name."
    case .leadingHyphen: "Must not start with a hyphen."
    case .invalid: invalidText
    }
  }
}

nonisolated extension RemoteKageHost {
  /// `others` are the hosts the name must differ from (exclude the one being edited).
  static func validateName(_ raw: String, among others: [RemoteKageHost]) -> RemoteKageHostIssue? {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return .required }
    let lowered = name.lowercased()
    if others.contains(where: {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lowered
    }) {
      return .duplicate
    }
    return nil
  }

  /// `[A-Za-z0-9._-]`, not starting with `-`.
  static func validateUsername(_ raw: String) -> RemoteKageHostIssue? {
    let username = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !username.isEmpty else { return .required }
    guard !username.hasPrefix("-") else { return .leadingHyphen }
    let allowed = username.unicodeScalars.allSatisfy { isASCIILetterOrDigit($0) || $0 == "." || $0 == "_" || $0 == "-" }
    return allowed ? nil : .invalid
  }

  /// A DNS name, an IPv4 address or an IPv6 address (optionally in brackets).
  static func validateAddress(_ raw: String) -> RemoteKageHostIssue? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .required }
    guard !trimmed.hasPrefix("-") else { return .leadingHyphen }
    let hasOpen = trimmed.hasPrefix("[")
    let hasClose = trimmed.hasSuffix("]")
    guard hasOpen == hasClose else { return .invalid }
    let address = normalizedAddress(trimmed)
    guard !address.isEmpty else { return .invalid }
    let valid: Bool
    if hasOpen {
      valid = isIPv6(address)
    } else if address.contains(":") {
      valid = isIPv6(address)
    } else if address.unicodeScalars.allSatisfy({ $0 == "." || ("0"..."9").contains($0) }) {
      valid = isIPv4(address)
    } else {
      valid = isDNSName(address)
    }
    return valid ? nil : .invalid
  }

  /// The form that is stored and handed to ssh: trimmed, IPv6 without brackets.
  static func normalizedAddress(_ raw: String) -> String {
    var address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if address.hasPrefix("["), address.hasSuffix("]"), address.count >= 2 {
      address = String(address.dropFirst().dropLast())
    }
    return address
  }

  private static func isASCIILetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
  }

  private static func isDNSName(_ name: String) -> Bool {
    guard name.utf8.count <= 253 else { return false }
    let labels = name.split(separator: ".", omittingEmptySubsequences: false)
    return labels.allSatisfy { label in
      !label.isEmpty
        && label.utf8.count <= 63
        && !label.hasPrefix("-")
        && !label.hasSuffix("-")
        && label.unicodeScalars.allSatisfy { isASCIILetterOrDigit($0) || $0 == "-" }
    }
  }

  private static func isIPv4(_ address: String) -> Bool {
    let parts = address.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4
      && parts.allSatisfy { part in
        (1...3).contains(part.count)
          && part.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
          && (Int(part) ?? 256) <= 255
      }
  }

  private static func isIPv6(_ address: String) -> Bool {
    func groups(_ text: Substring) -> [Substring] {
      text.isEmpty ? [] : text.split(separator: ":", omittingEmptySubsequences: false)
    }
    func isGroup(_ group: Substring) -> Bool {
      (1...4).contains(group.count) && group.unicodeScalars.allSatisfy { $0.properties.isASCIIHexDigit }
    }
    let halves = address.components(separatedBy: "::")
    switch halves.count {
    case 1:
      let all = groups(address[...])
      return all.count == 8 && all.allSatisfy(isGroup)
    case 2:
      let all = groups(halves[0][...]) + groups(halves[1][...])
      return all.count <= 7 && all.allSatisfy(isGroup)
    default:
      return false
    }
  }
}

/// Persisted in `~/.config/kage/remote-hosts.json`, outside upstream's settings
/// schema (fork-only feature).
nonisolated struct RemoteKageHostsFile: Codable, Equatable, Sendable {
  var hosts: [RemoteKageHost] = []

  init(hosts: [RemoteKageHost] = []) {
    self.hosts = hosts
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    hosts = try container.decodeIfPresent([RemoteKageHost].self, forKey: .hosts) ?? []
  }
}

nonisolated extension SupacodePaths {
  static var remoteKageHostsFileURL: URL {
    configBaseDirectory.appending(path: "remote-hosts.json", directoryHint: .notDirectory)
  }
}

/// Reads and writes `remote-hosts.json` through the shared settings-file storage
/// (in-memory in tests). Absent or undecodable both serve an empty file.
nonisolated struct RemoteKageHostsFileKey: SharedKey {
  private static let logger = SupaLogger("RemoteKage")

  let url: URL

  init(url: URL = SupacodePaths.remoteKageHostsFileURL) {
    self.url = url
  }

  var id: URL { url }

  func load(context _: LoadContext<RemoteKageHostsFile>, continuation: LoadContinuation<RemoteKageHostsFile>) {
    @Dependency(\.settingsFileStorage) var storage
    guard let data = try? storage.load(url) else {
      continuation.resumeReturningInitialValue()
      return
    }
    guard let file = try? JSONDecoder().decode(RemoteKageHostsFile.self, from: data) else {
      Self.logger.error("remote-hosts.json present but undecodable; serving an empty file.")
      continuation.resumeReturningInitialValue()
      return
    }
    continuation.resume(returning: file)
  }

  func subscribe(
    context _: LoadContext<RemoteKageHostsFile>,
    subscriber _: SharedSubscriber<RemoteKageHostsFile>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(_ value: RemoteKageHostsFile, context _: SaveContext, continuation: SaveContinuation) {
    @Dependency(\.settingsFileStorage) var storage
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try storage.save(try encoder.encode(value), url)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }
}

nonisolated extension SharedReaderKey where Self == RemoteKageHostsFileKey.Default {
  static var remoteKageHostsFile: Self {
    Self[RemoteKageHostsFileKey(), default: RemoteKageHostsFile()]
  }
}
