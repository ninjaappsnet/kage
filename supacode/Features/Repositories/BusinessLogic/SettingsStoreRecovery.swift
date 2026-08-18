import Dependencies
import Foundation
import OrderedCollections
import SupacodeSettingsShared

nonisolated extension SettingsRelocationMigrator {
  /// True when the split store decodes but holds nothing a user could have put
  /// there: no repositories, no per-repo settings, and globals still at their
  /// defaults. Zero repositories alone is a legitimate state — pairing it with
  /// untouched globals is what separates "the migration wrote defaults" from "the
  /// user removed everything".
  static func storeIsVacant() -> Bool {
    @Dependency(\.settingsFileStorage) var storage
    let decoder = JSONDecoder()
    guard
      let configData = try? storage.load(SupacodePaths.configURL),
      let global = try? decoder.decode(GlobalSettings.self, from: configData),
      global == .default,
      let routesData = try? storage.load(SupacodePaths.routesURL),
      let routes = try? decoder.decode(RoutesFile.self, from: routesData),
      routes.local.isEmpty, routes.remote.isEmpty,
      let repositoriesData = try? storage.load(SupacodePaths.reposURL),
      let repositories = try? decoder.decode([String: RepositorySettings].self, from: repositoriesData)
    else { return false }
    return repositories.isEmpty
  }

  /// True when the legacy `settings.json` still lists repositories the split store
  /// doesn't have. This is the shape that stranded real data: three files present
  /// and decodable — so `settingsStoreComplete()` reads as done — yet empty.
  static func storeLacksLegacyRepositories(fileSystem: RelocationFileSystem) -> Bool {
    guard
      let data = fileSystem.readData(SupacodePaths.legacySettingsURL),
      let legacy = try? JSONDecoder().decode(SettingsFile.self, from: data),
      !legacy.repositoryRoots.isEmpty || !legacy.remoteRepositoryRoots.isEmpty
    else { return false }
    @Dependency(\.settingsFileStorage) var storage
    guard
      let routesData = try? storage.load(SupacodePaths.routesURL),
      let routes = try? JSONDecoder().decode(RoutesFile.self, from: routesData)
    else { return true }
    return routes.local.isEmpty && routes.remote.isEmpty
  }
}

/// Recovers from the one relocation end state the app cannot climb out of on its
/// own: the `.relocated` marker stamped over a store that holds nothing, with the
/// real `settings.json` already archived into `.backup`. The marker suppresses the
/// migration on every later launch, and nothing else ever reads `.backup`, so the
/// user's repositories are invisible to the app while sitting intact on disk.
///
/// Runs before `SettingsRelocationMigrator` and simply undoes the bad state:
/// restore the archived files, drop the marker, and let the normal migration
/// re-seed from real data on this same launch.
@MainActor
enum SettingsStoreRecovery {
  private static let logger = SupaLogger("Settings")

  /// Returns whether it restored anything. Never throws; a step that fails leaves
  /// the archive untouched and retries next launch.
  @discardableResult
  static func repairVacantStore(fileSystem: RelocationFileSystem = .live) -> Bool {
    // Only a *completed* relocation can strand data this way; an unfinished one
    // still re-seeds by itself.
    guard fileSystem.fileExists(SupacodePaths.relocationMarkerURL) else { return false }
    // One repair per install: a user who empties their repository list on purpose
    // must not be handed the old one back on the next launch.
    guard !fileSystem.fileExists(SupacodePaths.storeRepairMarkerURL) else { return false }
    // A legacy file still in place means the relocation never finished retiring it,
    // so it will be picked up normally.
    guard !fileSystem.fileExists(SupacodePaths.legacySettingsURL) else { return false }
    guard SettingsRelocationMigrator.storeIsVacant() else { return false }
    let archivedSettings = archived("settings.json")
    guard
      let data = fileSystem.readData(archivedSettings),
      let settings = try? JSONDecoder().decode(SettingsFile.self, from: data),
      !settings.repositoryRoots.isEmpty || !settings.remoteRepositoryRoots.isEmpty
    else { return false }

    do {
      try fileSystem.moveItem(archivedSettings, SupacodePaths.legacySettingsURL)
    } catch {
      logger.error("Failed to restore the archived settings.json: \(error)")
      return false
    }
    // The sidebar / layout archives are only restored when nothing live exists:
    // a newer file on disk is the better copy.
    restoreArchived("sidebar.json", to: SupacodePaths.legacySidebarURL, fileSystem: fileSystem)
    restoreArchived("layouts.json", to: SupacodePaths.legacyLayoutsURL, fileSystem: fileSystem)
    clearVacantUserDefaults()
    retireMarker(fileSystem: fileSystem)
    do {
      try fileSystem.writeData(Data(), SupacodePaths.storeRepairMarkerURL)
    } catch {
      logger.error("Failed to write the store-repair marker: \(error)")
    }
    logger.info("Restored the archived settings over an empty settings store; the migration will re-seed.")
    return true
  }

  private static func archived(_ name: String) -> URL {
    SupacodePaths.backupDirectory.appending(path: name, directoryHint: .notDirectory)
  }

  private static func restoreArchived(_ name: String, to destination: URL, fileSystem: RelocationFileSystem) {
    let source = archived(name)
    guard fileSystem.fileExists(source), !fileSystem.fileExists(destination) else { return }
    do {
      try fileSystem.moveItem(source, destination)
    } catch {
      logger.warning("Failed to restore the archived \(name): \(error)")
    }
  }

  /// Drops the sidebar / layout values the vacant launch wrote, so the re-seed
  /// refills them from the restored files. A value that holds real state is kept:
  /// it is newer than anything archived.
  private static func clearVacantUserDefaults() {
    @Dependency(\.defaultAppStorage) var defaults
    if let data = defaults.data(forKey: SidebarKey.storageKey),
      let sidebar = try? JSONDecoder().decode(SidebarState.self, from: data),
      sidebar.sections.isEmpty, sidebar.workspaces.isEmpty
    {
      defaults.removeObject(forKey: SidebarKey.storageKey)
    }
    if let data = defaults.data(forKey: LayoutsFile.userDefaultsKey),
      let layouts = try? JSONDecoder().decode(LayoutsFile.self, from: data),
      layouts.worktrees.isEmpty
    {
      defaults.removeObject(forKey: LayoutsFile.userDefaultsKey)
    }
    defaults.synchronize()
  }

  /// Retires the marker by moving it aside rather than deleting it, so the record
  /// that a relocation once ran survives in `.backup`.
  private static func retireMarker(fileSystem: RelocationFileSystem) {
    let destination = archived("relocated-before-repair")
    do {
      try fileSystem.createDirectory(SupacodePaths.backupDirectory)
      try fileSystem.moveItem(SupacodePaths.relocationMarkerURL, destination)
    } catch {
      logger.error("Failed to clear the relocation marker: \(error)")
    }
  }
}
