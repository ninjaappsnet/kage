import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Recovery for the relocation's one unrecoverable end state: the `.relocated`
/// marker stamped over a store that holds nothing, with the real data already
/// archived into `.backup`. Without this the app can never re-seed — the marker
/// suppresses the migration and the archived file is invisible to it.
@MainActor
struct SettingsStoreRecoveryTests {
  @Test(.dependencies) func restoresArchivedSettingsOverAVacantStore() throws {
    var archived = SettingsFile.default
    archived.repositoryRoots = ["/Users/me/code/acme/"]
    let defaults = UserDefaults.inMemory
    // A sidebar value that decodes but holds nothing is the same casualty: it was
    // written by the launch that started from the vacant store.
    defaults.set(try JSONEncoder().encode(SidebarState()), forKey: SidebarKey.storageKey)
    let files = try vacantStore(archivedSettings: archived)

    let repaired = withDependencies {
      $0.settingsFileStorage = files.settingsStorage()
      $0.defaultAppStorage = defaults
    } operation: {
      SettingsStoreRecovery.repairVacantStore(fileSystem: files.system)
    }

    #expect(repaired)
    // The archived settings are live again and the marker is gone, so the
    // relocation re-seeds from real data on this same launch.
    #expect(files.data(at: SupacodePaths.legacySettingsURL) != nil)
    #expect(files.data(at: backup("settings.json")) == nil)
    #expect(files.data(at: SupacodePaths.relocationMarkerURL) == nil)
    // The empty sidebar value is cleared so the seed refills it from `sidebar.json`.
    #expect(defaults.data(forKey: SidebarKey.storageKey) == nil)
    // A durable marker records the repair, so a user who later empties the sidebar
    // on purpose is never "restored" a second time.
    #expect(files.data(at: SupacodePaths.storeRepairMarkerURL) != nil)
  }

  @Test(.dependencies) func leavesAStoreThatStillHasRepositories() throws {
    var archived = SettingsFile.default
    archived.repositoryRoots = ["/Users/me/code/acme/"]
    var live = RoutesFile()
    live.local = ["/Users/me/code/beta/"]
    let files = try vacantStore(archivedSettings: archived, routes: live)

    let repaired = withDependencies {
      $0.settingsFileStorage = files.settingsStorage()
      $0.defaultAppStorage = .inMemory
    } operation: {
      SettingsStoreRecovery.repairVacantStore(fileSystem: files.system)
    }

    #expect(!repaired)
    #expect(files.data(at: backup("settings.json")) != nil)
    #expect(files.data(at: SupacodePaths.relocationMarkerURL) != nil)
  }

  @Test(.dependencies) func leavesAnEmptyButCustomizedStoreAlone() throws {
    // Zero repositories is a legitimate state. Only a store that is *also* pure
    // defaults can be told apart from a user who removed every repository.
    var archived = SettingsFile.default
    archived.repositoryRoots = ["/Users/me/code/acme/"]
    var customized = GlobalSettings.default
    customized.defaultEditorID = "vscode"
    let files = try vacantStore(archivedSettings: archived, global: customized)

    let repaired = withDependencies {
      $0.settingsFileStorage = files.settingsStorage()
      $0.defaultAppStorage = .inMemory
    } operation: {
      SettingsStoreRecovery.repairVacantStore(fileSystem: files.system)
    }

    #expect(!repaired)
    #expect(files.data(at: backup("settings.json")) != nil)
  }

  @Test(.dependencies) func doesNotRepairTwice() throws {
    var archived = SettingsFile.default
    archived.repositoryRoots = ["/Users/me/code/acme/"]
    let files = try vacantStore(archivedSettings: archived)
    files.set(Data(), at: SupacodePaths.storeRepairMarkerURL)

    let repaired = withDependencies {
      $0.settingsFileStorage = files.settingsStorage()
      $0.defaultAppStorage = .inMemory
    } operation: {
      SettingsStoreRecovery.repairVacantStore(fileSystem: files.system)
    }

    #expect(!repaired)
    #expect(files.data(at: backup("settings.json")) != nil)
  }

  @Test(.dependencies) func leavesTheStoreAloneWhenNothingWasArchived() throws {
    let files = try vacantStore(archivedSettings: nil)

    let repaired = withDependencies {
      $0.settingsFileStorage = files.settingsStorage()
      $0.defaultAppStorage = .inMemory
    } operation: {
      SettingsStoreRecovery.repairVacantStore(fileSystem: files.system)
    }

    #expect(!repaired)
    #expect(files.data(at: SupacodePaths.relocationMarkerURL) != nil)
  }

  @Test(.dependencies) func restoresAnArchivedSidebarWhenTheLiveOneIsGone() throws {
    var archived = SettingsFile.default
    archived.repositoryRoots = ["/Users/me/code/acme/"]
    let files = try vacantStore(archivedSettings: archived)
    files.set(Data("sidebar".utf8), at: backup("sidebar.json"))

    withDependencies {
      $0.settingsFileStorage = files.settingsStorage()
      $0.defaultAppStorage = .inMemory
    } operation: {
      _ = SettingsStoreRecovery.repairVacantStore(fileSystem: files.system)
    }

    #expect(files.data(at: SupacodePaths.legacySidebarURL) == Data("sidebar".utf8))
  }

  // MARK: - Root cause: the marker must never be stamped over a vacant store.

  @Test(.dependencies) func seedRewritesAVacantStoreThatLooksComplete() throws {
    // The exact shape that stranded the data: all three files present and
    // decodable, but empty, while the legacy file still holds every repository.
    var legacy = SettingsFile.default
    legacy.repositoryRoots = ["/Users/me/code/acme/"]
    let files = try FakeStoreFS(files: [
      SupacodePaths.configURL: JSONEncoder().encode(GlobalSettings.default),
      SupacodePaths.routesURL: JSONEncoder().encode(RoutesFile()),
      SupacodePaths.reposURL: JSONEncoder().encode([String: RepositorySettings]()),
      SupacodePaths.legacySettingsURL: JSONEncoder().encode(legacy),
    ])

    try withDependencies {
      $0.settingsFileStorage = files.settingsStorage()
      $0.defaultAppStorage = .inMemory
    } operation: {
      _ = SettingsRelocationMigrator.seedSettingsFromLegacy(fileSystem: files.system)
      let routes = try JSONDecoder().decode(
        RoutesFile.self, from: #require(files.data(at: SupacodePaths.routesURL)))
      #expect(routes.local == ["/Users/me/code/acme/"])
    }
  }

  @Test(.dependencies) func markerIsWithheldWhileTheStoreIsVacantAndLegacyHasRepositories() throws {
    var legacy = SettingsFile.default
    legacy.repositoryRoots = ["/Users/me/code/acme/"]
    // A store that cannot be rewritten (every save fails) must not be marked done.
    let files = try FakeStoreFS(files: [
      SupacodePaths.configURL: JSONEncoder().encode(GlobalSettings.default),
      SupacodePaths.routesURL: JSONEncoder().encode(RoutesFile()),
      SupacodePaths.reposURL: JSONEncoder().encode([String: RepositorySettings]()),
      SupacodePaths.legacySettingsURL: JSONEncoder().encode(legacy),
    ])

    let problems = withDependencies {
      $0.settingsFileStorage = files.settingsStorage(failingSaves: [
        SupacodePaths.configURL, SupacodePaths.routesURL, SupacodePaths.reposURL,
      ])
      $0.defaultAppStorage = .inMemory
    } operation: {
      _ = SettingsRelocationMigrator.seedSettingsFromLegacy(fileSystem: files.system)
      return SettingsRelocationMigrator.finishSeeding(fileSystem: files.system)
    }

    #expect(files.data(at: SupacodePaths.relocationMarkerURL) == nil)
    #expect(!problems.isEmpty)
    // The legacy file is the only real copy left, so it must stay put.
    #expect(files.data(at: SupacodePaths.legacySettingsURL) != nil)
  }

  // MARK: - Helpers.

  private func backup(_ name: String) -> URL {
    SupacodePaths.backupDirectory.appending(path: name, directoryHint: .notDirectory)
  }

  /// The stranded state: marker stamped, all three store files present but empty,
  /// the real settings sitting in `.backup`.
  private func vacantStore(
    archivedSettings: SettingsFile?,
    global: GlobalSettings = .default,
    routes: RoutesFile = RoutesFile()
  ) throws -> FakeStoreFS {
    var files: [URL: Data] = [
      SupacodePaths.relocationMarkerURL: Data(),
      SupacodePaths.configURL: try JSONEncoder().encode(global),
      SupacodePaths.routesURL: try JSONEncoder().encode(routes),
      SupacodePaths.reposURL: try JSONEncoder().encode([String: RepositorySettings]()),
    ]
    if let archivedSettings {
      files[backup("settings.json")] = try JSONEncoder().encode(archivedSettings)
    }
    return FakeStoreFS(files: files)
  }
}

/// Flat in-memory file tree shared by `RelocationFileSystem` and the settings
/// storage, so a write through either is visible to the other.
nonisolated final class FakeStoreFS: @unchecked Sendable {
  private let lock = NSLock()
  private var files: [URL: Data]

  init(files: [URL: Data] = [:]) {
    self.files = files
  }

  func data(at url: URL) -> Data? {
    withLock { files[url] }
  }

  func set(_ data: Data?, at url: URL) {
    withLock { files[url] = data }
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  var system: RelocationFileSystem {
    RelocationFileSystem(
      fileExists: { url in self.withLock { self.files[url] != nil } },
      readData: { url in self.withLock { self.files[url] } },
      writeData: { data, url in self.withLock { self.files[url] = data } },
      isSymbolicLink: { _ in false },
      moveItem: { source, destination in
        try self.withLock {
          guard let data = self.files[source] else { throw CocoaError(.fileNoSuchFile) }
          self.files[destination] = data
          self.files[source] = nil
        }
      },
      createDirectory: { _ in },
      contentsOfDirectory: { directory in
        let path = directory.standardizedFileURL.path(percentEncoded: false)
        return self.withLock {
          self.files.keys.filter {
            $0.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false) == path
          }
        }
      }
    )
  }

  func settingsStorage(failingSaves: Set<URL> = []) -> SettingsFileStorage {
    SettingsFileStorage(
      load: { url in
        guard let data = self.withLock({ self.files[url] }) else { throw CocoaError(.fileReadNoSuchFile) }
        return data
      },
      save: { data, url in
        guard !failingSaves.contains(url) else { throw CocoaError(.fileWriteUnknown) }
        self.withLock { self.files[url] = data }
      }
    )
  }
}
