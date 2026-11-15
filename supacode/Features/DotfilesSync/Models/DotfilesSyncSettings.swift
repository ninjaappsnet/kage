import ComposableArchitecture
import Foundation
import Sharing
import SupacodeSettingsShared

/// Settings → Sync choices, kept per machine in `~/.config/kage/dotfiles-sync.json`
/// (never in the synced repository itself, which would sync the switch that
/// turns syncing off).
nonisolated struct DotfilesSyncSettings: Codable, Equatable, Sendable {
  var isEnabled = false
  /// Clone URL of the user's private dotfiles repository.
  var remoteURL = ""

  var trimmedRemoteURL: String { remoteURL.trimmingCharacters(in: .whitespacesAndNewlines) }
}

nonisolated extension SupacodePaths {
  static var dotfilesSyncSettingsURL: URL {
    configBaseDirectory.appending(path: "dotfiles-sync.json", directoryHint: .notDirectory)
  }

  /// This machine's clone of the dotfiles repository.
  static var dotfilesRepositoryDirectory: URL {
    baseDirectory.appending(path: "dotfiles", directoryHint: .isDirectory)
  }

  /// Remote copies of files whose edits could not be merged, by repository path.
  static var dotfilesConflictsDirectory: URL {
    baseDirectory.appending(path: "dotfiles-conflicts", directoryHint: .isDirectory)
  }
}

/// Reads and writes `dotfiles-sync.json` through the shared settings-file storage
/// (in-memory in tests). Absent or undecodable both serve the defaults.
nonisolated struct DotfilesSyncSettingsKey: SharedKey {
  let url: URL

  init(url: URL = SupacodePaths.dotfilesSyncSettingsURL) {
    self.url = url
  }

  var id: URL { url }

  func load(context _: LoadContext<DotfilesSyncSettings>, continuation: LoadContinuation<DotfilesSyncSettings>) {
    @Dependency(\.settingsFileStorage) var storage
    guard let data = try? storage.load(url),
      let settings = try? JSONDecoder().decode(DotfilesSyncSettings.self, from: data)
    else {
      continuation.resumeReturningInitialValue()
      return
    }
    continuation.resume(returning: settings)
  }

  func subscribe(
    context _: LoadContext<DotfilesSyncSettings>,
    subscriber _: SharedSubscriber<DotfilesSyncSettings>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(_ value: DotfilesSyncSettings, context _: SaveContext, continuation: SaveContinuation) {
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

nonisolated extension SharedReaderKey where Self == DotfilesSyncSettingsKey.Default {
  static var dotfilesSyncSettings: Self {
    Self[DotfilesSyncSettingsKey(), default: DotfilesSyncSettings()]
  }
}
