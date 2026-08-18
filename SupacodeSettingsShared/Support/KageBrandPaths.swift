import Foundation

/// Directory and file names this fork owns on disk.
///
/// Upstream stores its config under its own name (`~/.supacode`,
/// `~/.config/supacode`, `<repo>/supacode.json`). Kage ships as its own app with
/// its own bundle id, so it stores config under its own brand and migrates an
/// upstream-branded tree across on launch (`KageBrandMigrator`). Both names stay
/// resolvable: the legacy ones are read (and retired) by the migration, the
/// current ones by everything else.
///
/// `SupacodePaths` derives every path from these, so the brand lives in exactly
/// one place.
public nonisolated enum KageBrand {
  /// `~/<baseDirectoryName>` — worktree storage, backups, legacy config files.
  public static let baseDirectoryName = ".kage"
  /// `$XDG_CONFIG_HOME/<configDirectoryName>` — the split settings store.
  public static let configDirectoryName = "kage"
  /// Per-repository settings file committed inside the user's repository.
  public static let repositorySettingsFileName = "kage.json"

  public static let legacyBaseDirectoryName = ".supacode"
  public static let legacyConfigDirectoryName = "supacode"
  public static let legacyRepositorySettingsFileName = "supacode.json"
}

/// Upstream-branded locations, named only so the migration can find and retire
/// them. Nothing else should read these.
nonisolated extension SupacodePaths {
  public static var legacyBrandBaseDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: KageBrand.legacyBaseDirectoryName, directoryHint: .isDirectory)
  }

  public static var legacyBrandReposDirectory: URL {
    legacyBrandBaseDirectory.appending(path: "repos", directoryHint: .isDirectory)
  }

  /// Mirrors `configBaseDirectory`'s `$XDG_CONFIG_HOME` handling, under the
  /// upstream directory name.
  public static var legacyBrandConfigBaseDirectory: URL {
    let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let root: URL
    if let xdg, xdg.hasPrefix("/") {
      root = URL(filePath: xdg, directoryHint: .isDirectory)
    } else {
      root = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config", directoryHint: .isDirectory)
    }
    return root.appending(path: KageBrand.legacyConfigDirectoryName, directoryHint: .isDirectory)
  }

  public static func legacyBrandRepositorySettingsURL(for rootURL: URL) -> URL {
    rootURL.standardizedFileURL
      .appending(path: KageBrand.legacyRepositorySettingsFileName, directoryHint: .notDirectory)
  }

  /// Durable marker for `SettingsStoreRecovery`: written once it has restored an
  /// archived `settings.json` over a vacant store, so a user who later empties
  /// their repository list on purpose is never handed the old one back.
  public static var storeRepairMarkerURL: URL {
    configBaseDirectory.appending(path: ".store-repaired", directoryHint: .notDirectory)
  }
}
