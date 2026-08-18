import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// One-shot move of an upstream-branded tree (`~/.supacode`, `~/.config/supacode`,
/// `<repo>/supacode.json`) onto the fork's own brand, including the worktree
/// storage under `repos/` — which only moves when git can be repaired at the new
/// location.
@MainActor
struct KageBrandMigratorTests {
  // MARK: - Config + base directories.

  @Test(.dependencies) func movesConfigAndBaseDirectoryContents() {
    let files = FakeBrandFS(files: [
      legacyConfig("config.json"): Data("config".utf8),
      legacyConfig("routes.json"): Data("routes".utf8),
      legacyConfig(".relocated"): Data(),
      legacyBase("settings.json"): Data("settings".utf8),
      legacyBase(".backup/settings.json"): Data("archived".utf8),
    ])

    let report = withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      KageBrandMigrator.run(fileSystem: files.system, git: FakeBrandGit().client)
    }

    #expect(report.problems.isEmpty)
    #expect(files.data(at: SupacodePaths.configURL) == Data("config".utf8))
    #expect(files.data(at: SupacodePaths.routesURL) == Data("routes".utf8))
    #expect(files.data(at: SupacodePaths.relocationMarkerURL) != nil)
    #expect(files.data(at: SupacodePaths.legacySettingsURL) == Data("settings".utf8))
    #expect(
      files.data(at: SupacodePaths.backupDirectory.appending(path: "settings.json"))
        == Data("archived".utf8))
    // Nothing is left behind at the legacy locations.
    #expect(files.data(at: legacyConfig("config.json")) == nil)
    #expect(files.data(at: legacyBase("settings.json")) == nil)
  }

  @Test(.dependencies) func keepsAnAlreadyBrandedFileOverTheLegacyOne() {
    let files = FakeBrandFS(files: [
      legacyConfig("config.json"): Data("legacy".utf8),
      SupacodePaths.configURL: Data("current".utf8),
    ])

    withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      _ = KageBrandMigrator.run(fileSystem: files.system, git: FakeBrandGit().client)
    }

    // The branded store is the live one: a stale legacy copy must never clobber it.
    #expect(files.data(at: SupacodePaths.configURL) == Data("current".utf8))
    #expect(files.data(at: legacyConfig("config.json")) == Data("legacy".utf8))
  }

  @Test(.dependencies) func doesNothingWhenNoLegacyTreeExists() {
    let files = FakeBrandFS(files: [SupacodePaths.configURL: Data("config".utf8)])

    let report = withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      KageBrandMigrator.run(fileSystem: files.system, git: FakeBrandGit().client)
    }

    #expect(report == BrandMigrationReport())
    #expect(files.moveCount == 0)
  }

  // MARK: - Worktree storage.

  @Test(.dependencies) func movesWorktreeStorageRepairsGitAndRewritesStoredPaths() throws {
    let defaults = UserDefaults.inMemory
    let git = FakeBrandGit()
    let legacyWorktree = legacyBase("repos/acme/feature-x")
    let routes = RoutesFile(local: ["/Users/me/code/acme/"], remote: [])
    let layouts = [
      "worktrees": [legacyWorktree.path(percentEncoded: false) + "/": ["tabs": ["one"]]]
    ]
    let files = FakeBrandFS(files: [
      legacyBase("repos/acme/feature-x/.git"): Data("gitdir: /Users/me/code/acme/.git/worktrees/x".utf8),
      legacyConfig("routes.json"): try JSONEncoder().encode(routes),
    ])
    defaults.set(
      try JSONSerialization.data(withJSONObject: layouts), forKey: LayoutsFile.userDefaultsKey)

    let report = withDependencies {
      $0.defaultAppStorage = defaults
    } operation: {
      KageBrandMigrator.run(fileSystem: files.system, git: git.client)
    }

    #expect(report.movedWorktreeRepositories == ["acme"])
    #expect(report.failedWorktreeRepositories.isEmpty)
    // The tree moved under the branded base.
    let movedWorktree = SupacodePaths.reposDirectory.appending(path: "acme/feature-x")
    #expect(files.data(at: movedWorktree.appending(path: ".git")) != nil)
    #expect(files.data(at: legacyWorktree.appending(path: ".git")) == nil)
    // git was asked to repair the worktree at its new location.
    #expect(git.repaired == [movedWorktree.path(percentEncoded: false) + "/"])
    // Stored worktree paths follow the move.
    let rewritten = try #require(defaults.data(forKey: LayoutsFile.userDefaultsKey))
    let object = try #require(JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
    let worktrees = try #require(object["worktrees"] as? [String: Any])
    #expect(worktrees.keys.first?.hasPrefix(movedWorktree.path(percentEncoded: false)) == true)
  }

  @Test(.dependencies) func rollsBackAWorktreeRepositoryGitCannotRepair() {
    let git = FakeBrandGit(healthy: false)
    let files = FakeBrandFS(files: [
      legacyBase("repos/acme/feature-x/.git"): Data("gitdir: elsewhere".utf8)
    ])

    let report = withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      KageBrandMigrator.run(fileSystem: files.system, git: git.client)
    }

    #expect(report.movedWorktreeRepositories.isEmpty)
    #expect(report.failedWorktreeRepositories == ["acme"])
    #expect(report.problems.count == 1)
    // Rolled back: the worktree still lives (and works) at its legacy path.
    #expect(files.data(at: legacyBase("repos/acme/feature-x/.git")) != nil)
    #expect(files.data(at: SupacodePaths.reposDirectory.appending(path: "acme/feature-x/.git")) == nil)
  }

  @Test(.dependencies) func rewritesTheWorktreeBaseOverrideOnceEveryRepositoryMoved() throws {
    var global = GlobalSettings.default
    global.defaultWorktreeBaseDirectoryPath =
      SupacodePaths.legacyBrandReposDirectory.path(percentEncoded: false)
    let files = FakeBrandFS(files: [
      legacyConfig("config.json"): try JSONEncoder().encode(global),
      legacyBase("repos/acme/feature-x/.git"): Data("gitdir: /Users/me/code/acme/.git/worktrees/x".utf8),
    ])

    withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      _ = KageBrandMigrator.run(fileSystem: files.system, git: FakeBrandGit().client)
    }

    // The storage directory itself moved, so a base pointing at it follows.
    let rewritten = try JSONDecoder().decode(
      GlobalSettings.self, from: #require(files.data(at: SupacodePaths.configURL)))
    #expect(
      rewritten.defaultWorktreeBaseDirectoryPath?.hasPrefix(
        SupacodePaths.reposDirectory.path(percentEncoded: false)) == true)
  }

  // MARK: - Per-repository settings file.

  @Test(.dependencies) func convertsPerRepositorySettingsFileToTheKageBrand() throws {
    let root = URL(filePath: "/Users/me/code/acme/", directoryHint: .isDirectory)
    let other = URL(filePath: "/Users/me/code/beta/", directoryHint: .isDirectory)
    let routes = RoutesFile(
      local: [root.path(percentEncoded: false), other.path(percentEncoded: false)], remote: [])
    let files = FakeBrandFS(files: [
      legacyConfig("routes.json"): try JSONEncoder().encode(routes),
      SupacodePaths.legacyBrandRepositorySettingsURL(for: root): Data("repo-settings".utf8),
      SupacodePaths.legacyBrandRepositorySettingsURL(for: other): Data("stale".utf8),
      SupacodePaths.repositorySettingsURL(for: other): Data("current".utf8),
    ])

    let report = withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      KageBrandMigrator.run(fileSystem: files.system, git: FakeBrandGit().client)
    }

    #expect(report.convertedRepositorySettings == [root.path(percentEncoded: false)])
    #expect(files.data(at: SupacodePaths.repositorySettingsURL(for: root)) == Data("repo-settings".utf8))
    #expect(files.data(at: SupacodePaths.legacyBrandRepositorySettingsURL(for: root)) == nil)
    // A repo that already owns a `kage.json` keeps it, and its stale file stays put.
    #expect(files.data(at: SupacodePaths.repositorySettingsURL(for: other)) == Data("current".utf8))
    #expect(files.data(at: SupacodePaths.legacyBrandRepositorySettingsURL(for: other)) == Data("stale".utf8))
  }

  // MARK: - Idempotence.

  @Test(.dependencies) func secondRunIsANoOp() {
    let files = FakeBrandFS(files: [legacyConfig("config.json"): Data("config".utf8)])
    let git = FakeBrandGit()

    withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      _ = KageBrandMigrator.run(fileSystem: files.system, git: git.client)
      let movesAfterFirstRun = files.moveCount
      let report = KageBrandMigrator.run(fileSystem: files.system, git: git.client)
      #expect(report == BrandMigrationReport())
      #expect(files.moveCount == movesAfterFirstRun)
    }
  }

  // MARK: - Helpers.

  private func legacyBase(_ path: String) -> URL {
    SupacodePaths.legacyBrandBaseDirectory.appending(path: path)
  }

  private func legacyConfig(_ path: String) -> URL {
    SupacodePaths.legacyBrandConfigBaseDirectory.appending(path: path)
  }
}

/// In-memory tree keyed by path. A directory exists when any file sits under it,
/// and a move relocates every descendant, so directory moves behave like the real
/// `FileManager` ones the migrator relies on.
private nonisolated final class FakeBrandFS: @unchecked Sendable {
  private let lock = NSLock()
  private var files: [String: Data]
  private(set) var moveCount = 0

  init(files: [URL: Data] = [:]) {
    self.files = Dictionary(uniqueKeysWithValues: files.map { (Self.key($0.key), $0.value) })
  }

  func data(at url: URL) -> Data? {
    withLock { files[Self.key(url)] }
  }

  /// Directory URLs carry a trailing slash; paths in the tree never do, so every
  /// lookup normalizes before comparing.
  private static func key(_ url: URL) -> String {
    let path = url.standardizedFileURL.path(percentEncoded: false)
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  private func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  var system: BrandFileSystem {
    BrandFileSystem(
      fileExists: { url in
        let key = Self.key(url)
        return self.withLock { self.files[key] != nil || self.files.keys.contains { $0.hasPrefix(key + "/") } }
      },
      isDirectory: { url in
        let key = Self.key(url)
        return self.withLock { self.files.keys.contains { $0.hasPrefix(key + "/") } }
      },
      contentsOfDirectory: { url in
        let key = Self.key(url) + "/"
        return self.withLock {
          var names: Set<String> = []
          for path in self.files.keys where path.hasPrefix(key) {
            let remainder = String(path.dropFirst(key.count))
            if let name = remainder.split(separator: "/").first {
              names.insert(String(name))
            }
          }
          return names.sorted().map { url.appending(path: $0) }
        }
      },
      createDirectory: { _ in },
      moveItem: { source, destination in
        let sourceKey = Self.key(source)
        let destinationKey = Self.key(destination)
        try self.withLock {
          let moved = self.files.keys.filter { $0 == sourceKey || $0.hasPrefix(sourceKey + "/") }
          guard !moved.isEmpty else { throw CocoaError(.fileNoSuchFile) }
          for path in moved {
            self.files[destinationKey + path.dropFirst(sourceKey.count)] = self.files.removeValue(forKey: path)
          }
          self.moveCount += 1
        }
      },
      readData: { url in self.withLock { self.files[Self.key(url)] } },
      writeData: { data, url in self.withLock { self.files[Self.key(url)] = data } }
    )
  }
}

/// Records the worktrees git was asked to repair. `healthy` drives the post-repair
/// verification that decides whether a move sticks or rolls back.
private nonisolated final class FakeBrandGit: @unchecked Sendable {
  private let lock = NSLock()
  private let healthy: Bool
  private var repairedPaths: [String] = []

  init(healthy: Bool = true) {
    self.healthy = healthy
  }

  var repaired: [String] {
    lock.lock()
    defer { lock.unlock() }
    return repairedPaths
  }

  var client: BrandGitClient {
    BrandGitClient(
      repairWorktree: { url in
        self.lock.lock()
        self.repairedPaths.append(url.path(percentEncoded: false))
        self.lock.unlock()
        return self.healthy
      },
      isWorktreeHealthy: { _ in self.healthy }
    )
  }
}
