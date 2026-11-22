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
