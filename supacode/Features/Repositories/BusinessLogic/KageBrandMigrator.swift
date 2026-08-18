import Dependencies
import Foundation
import SupacodeSettingsShared

/// Injectable file-system seam for the brand migration. Directory-aware, unlike
/// `RelocationFileSystem`: this migration moves whole trees (`.backup`, `repos`),
/// not individual config files.
struct BrandFileSystem: Sendable {
  var fileExists: @Sendable (URL) -> Bool
  var isDirectory: @Sendable (URL) -> Bool
  var contentsOfDirectory: @Sendable (URL) -> [URL]
  var createDirectory: @Sendable (URL) throws -> Void
  var moveItem: @Sendable (URL, URL) throws -> Void
  var readData: @Sendable (URL) -> Data?
  var writeData: @Sendable (Data, URL) throws -> Void

  static let live = BrandFileSystem(
    fileExists: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) },
    isDirectory: { url in
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(
        atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
      return exists && isDirectory.boolValue
    },
    contentsOfDirectory: { url in
      (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    },
    createDirectory: { url in
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    },
    moveItem: { source, destination in
      try FileManager.default.moveItem(at: source, to: destination)
    },
    readData: { url in try? Data(contentsOf: url) },
    writeData: { data, url in try SymlinkPreservingFileWriter.write(data, to: url) }
  )
}

/// The two git operations a worktree move needs: re-point the main repository's
/// administrative files at the new location, then prove the worktree still works
/// there. A move that can't be proven is rolled back.
struct BrandGitClient: Sendable {
  var repairWorktree: @Sendable (URL) -> Bool
  var isWorktreeHealthy: @Sendable (URL) -> Bool

  static let live = BrandGitClient(
    repairWorktree: { url in Self.git(["-C", url.path(percentEncoded: false), "worktree", "repair"]) },
    isWorktreeHealthy: { url in
      Self.git(["-C", url.path(percentEncoded: false), "rev-parse", "--git-dir"])
    }
  )

  /// Runs git synchronously and reports whether it exited cleanly. The migration
  /// runs before the app has a UI, so a hung git would hang launch: anything that
  /// doesn't finish promptly counts as a failure and the move is rolled back.
  private nonisolated static func git(_ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return false
    }
    let deadline = Date().addingTimeInterval(15)
    while process.isRunning, Date() < deadline {
      usleep(20_000)
    }
    guard !process.isRunning else {
      process.terminate()
      return false
    }
    return process.terminationStatus == 0
  }
}

/// What `KageBrandMigrator.run` did this launch. Empty means there was nothing
/// upstream-branded left to move.
struct BrandMigrationReport: Equatable, Sendable {
  var movedConfigFiles: [String] = []
  var movedBaseEntries: [String] = []
  var movedWorktreeRepositories: [String] = []
  /// Repositories whose worktrees git could not repair at the new location; each
  /// was moved back and still works where it was.
  var failedWorktreeRepositories: [String] = []
  var convertedRepositorySettings: [String] = []
  var problems: [String] = []
}

/// Moves an upstream-branded config tree onto this fork's brand:
/// `~/.supacode` → `~/.kage`, `~/.config/supacode` → `~/.config/kage`, and each
/// repository's `supacode.json` → `kage.json`.
///
/// Ordering matters: this runs *before* `SettingsRelocationMigrator`, so that
/// migration only ever sees branded paths and a user coming from any upstream
/// build (pre- or post-relocation) lands in the same place.
///
/// Every step is independently guarded and idempotent: a destination that already
/// exists is never overwritten (the branded copy is the live one), and a step that
/// fails leaves its source untouched for the next launch. The one destructive
/// step — moving the worktree storage under `repos/`, which invalidates the
/// absolute paths git records — is verified per repository and rolled back when
/// git can't be repaired at the new location.
@MainActor
enum KageBrandMigrator {
  private static let logger = SupaLogger("Settings")

  @discardableResult
  static func run(
    fileSystem: BrandFileSystem = .live,
    git: BrandGitClient = .live
  ) -> BrandMigrationReport {
    var report = BrandMigrationReport()
    report.movedConfigFiles = moveEntries(
      from: SupacodePaths.legacyBrandConfigBaseDirectory,
      to: SupacodePaths.configBaseDirectory,
      skipping: [],
      fileSystem: fileSystem
    )
    // `repos` holds real worktrees, not config: it moves separately, under git's
    // supervision.
    report.movedBaseEntries = moveEntries(
      from: SupacodePaths.legacyBrandBaseDirectory,
      to: SupacodePaths.baseDirectory,
      skipping: ["repos"],
      fileSystem: fileSystem
    )
    let worktrees = migrateWorktreeStorage(fileSystem: fileSystem, git: git)
    report.movedWorktreeRepositories = worktrees.moved
    report.failedWorktreeRepositories = worktrees.failed
    report.problems += worktrees.problems
    if !worktrees.moved.isEmpty {
      rewriteStoredPaths(
        forRepositories: worktrees.moved,
        // Only once every repository made it does the storage directory itself
        // count as moved: a user whose worktree base points at the legacy `repos`
        // dir must keep pointing there while anything still lives in it.
        includingStorageRoot: worktrees.failed.isEmpty,
        fileSystem: fileSystem
      )
    }
    report.convertedRepositorySettings = convertRepositorySettingsFiles(fileSystem: fileSystem)
    return report
  }

  // MARK: - Config + base directories.

  /// Moves every entry of `source` into `destination`, skipping names handled
  /// elsewhere. A name that already exists at the destination is left behind: the
  /// branded file is the live one, and a stale legacy copy must never clobber it.
  private static func moveEntries(
    from source: URL,
    to destination: URL,
    skipping: Set<String>,
    fileSystem: BrandFileSystem
  ) -> [String] {
    guard fileSystem.isDirectory(source) else { return [] }
    var moved: [String] = []
    for entry in fileSystem.contentsOfDirectory(source).sorted(by: { $0.path < $1.path }) {
      let name = entry.lastPathComponent
      guard !skipping.contains(name) else { continue }
      let target = destination.appending(path: name)
      guard !fileSystem.fileExists(target) else {
        logger.info("Keeping \(name) already present under the Kage directory; legacy copy left in place.")
        continue
      }
      do {
        try fileSystem.createDirectory(destination)
        try fileSystem.moveItem(entry, target)
        moved.append(name)
      } catch {
        logger.warning("Failed to move \(name) into the Kage directory: \(error)")
      }
    }
    return moved
  }

  // MARK: - Worktree storage.

  private struct WorktreeMigration {
    var moved: [String] = []
    var failed: [String] = []
    var problems: [String] = []
  }

  /// Moves `~/.supacode/repos/<repo>` trees to `~/.kage/repos/<repo>`, one
  /// repository at a time. git records absolute paths in both directions, so each
  /// moved repository is repaired and then re-verified; anything that doesn't come
  /// back healthy is moved back, leaving a working (if legacy-located) worktree.
  private static func migrateWorktreeStorage(
    fileSystem: BrandFileSystem,
    git: BrandGitClient
  ) -> WorktreeMigration {
    let legacyRepos = SupacodePaths.legacyBrandReposDirectory
    guard fileSystem.isDirectory(legacyRepos) else { return WorktreeMigration() }
    var result = WorktreeMigration()
    for repository in fileSystem.contentsOfDirectory(legacyRepos).sorted(by: { $0.path < $1.path }) {
      let name = repository.lastPathComponent
      guard fileSystem.isDirectory(repository) else { continue }
      let destination = SupacodePaths.reposDirectory.appending(path: name, directoryHint: .isDirectory)
      guard !fileSystem.fileExists(destination) else {
        logger.info("Worktree storage for \(name) already exists under the Kage directory; skipping.")
        continue
      }
      do {
        try fileSystem.createDirectory(SupacodePaths.reposDirectory)
        try fileSystem.moveItem(repository, destination)
      } catch {
        logger.warning("Failed to move worktree storage for \(name): \(error)")
        result.failed.append(name)
        result.problems.append(
          "Your worktrees for \(name) could not be moved, so they stay in ~/\(KageBrand.legacyBaseDirectoryName).")
        continue
      }
      if repairWorktrees(in: destination, fileSystem: fileSystem, git: git) {
        result.moved.append(name)
      } else {
        rollBack(destination, to: repository, fileSystem: fileSystem, git: git)
        result.failed.append(name)
        result.problems.append(
          "Your worktrees for \(name) could not be relinked after the move, so they were left where they were.")
      }
    }
    return result
  }

  /// Repairs every worktree directly under a moved repository directory and
  /// reports whether all of them came back healthy.
  private static func repairWorktrees(
    in repositoryDirectory: URL,
    fileSystem: BrandFileSystem,
    git: BrandGitClient
  ) -> Bool {
    let worktrees = fileSystem.contentsOfDirectory(repositoryDirectory)
      .filter { fileSystem.isDirectory($0) }
      .map { URL(filePath: $0.path(percentEncoded: false), directoryHint: .isDirectory) }
    guard !worktrees.isEmpty else { return true }
    var healthy = true
    for worktree in worktrees {
      if !git.repairWorktree(worktree) || !git.isWorktreeHealthy(worktree) {
        logger.error("git could not repair the moved worktree at \(worktree.path(percentEncoded: false)).")
        healthy = false
      }
    }
    return healthy
  }

  /// Puts a repository's worktrees back where they were and repairs them there, so
  /// a failed move is a no-op rather than a broken checkout.
  private static func rollBack(
    _ destination: URL,
    to source: URL,
    fileSystem: BrandFileSystem,
    git: BrandGitClient
  ) {
    do {
      try fileSystem.moveItem(destination, source)
    } catch {
      logger.error("Failed to roll back the worktree move for \(source.lastPathComponent): \(error)")
      return
    }
    for worktree in fileSystem.contentsOfDirectory(source) where fileSystem.isDirectory(worktree) {
      _ = git.repairWorktree(URL(filePath: worktree.path(percentEncoded: false), directoryHint: .isDirectory))
    }
  }

  // MARK: - Stored paths.

  /// Rewrites every stored copy of a moved worktree path — the settings store on
  /// disk and the sidebar / layout state in UserDefaults — so worktree ids keep
  /// resolving after the move. Worktree ids *are* paths, so a missed rewrite
  /// silently orphans a row.
  private static func rewriteStoredPaths(
    forRepositories repositories: [String],
    includingStorageRoot: Bool,
    fileSystem: BrandFileSystem
  ) {
    let legacyRepos = directoryPrefix(SupacodePaths.legacyBrandReposDirectory.path(percentEncoded: false))
    let brandedRepos = directoryPrefix(SupacodePaths.reposDirectory.path(percentEncoded: false))
    // Per-repository prefixes first; the bare storage root is the fallback, so a
    // repository that stayed behind keeps its own path.
    var replacements = repositories.map { name in
      (legacyRepos + name + "/", brandedRepos + name + "/")
    }
    if includingStorageRoot {
      replacements.append((String(legacyRepos.dropLast()), String(brandedRepos.dropLast())))
    }
    for url in [SupacodePaths.configURL, SupacodePaths.routesURL, SupacodePaths.reposURL] {
      guard let data = fileSystem.readData(url),
        let rewritten = rewritingPaths(in: data, replacements: replacements)
      else { continue }
      do {
        try fileSystem.writeData(rewritten, url)
      } catch {
        logger.warning("Failed to rewrite moved worktree paths in \(url.lastPathComponent): \(error)")
      }
    }
    @Dependency(\.defaultAppStorage) var defaults
    for key in [SidebarKey.storageKey, LayoutsFile.userDefaultsKey, "worktreeOrderByRepository"] {
      guard let data = defaults.data(forKey: key),
        let rewritten = rewritingPaths(in: data, replacements: replacements)
      else { continue }
      defaults.set(rewritten, forKey: key)
    }
    // Pre-`sidebarState` keys are plain string arrays of repository ids.
    for key in ["repositoryOrderIDs", "sidebarCollapsedRepositoryIDs"] {
      guard let stored = defaults.array(forKey: key) as? [String] else { continue }
      let rewritten = stored.map { Self.rewriting($0, replacements) }
      guard rewritten != stored else { continue }
      defaults.set(rewritten, forKey: key)
    }
    defaults.synchronize()
  }

  private static func directoryPrefix(_ path: String) -> String {
    path.hasSuffix("/") ? path : path + "/"
  }

  /// Rewrites every string in a JSON document that starts with a moved path,
  /// keys included — worktree state is keyed *by* path. Returns `nil` when the
  /// document holds no moved path, so untouched files are never rewritten.
  static func rewritingPaths(in data: Data, replacements: [(String, String)]) -> Data? {
    guard !replacements.isEmpty,
      let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return nil }
    var changed = false
    let rewritten = rewrite(object, replacements, &changed)
    guard changed else { return nil }
    return try? JSONSerialization.data(
      withJSONObject: rewritten, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
  }

  private static func rewrite(_ value: Any, _ replacements: [(String, String)], _ changed: inout Bool) -> Any {
    switch value {
    case let string as String:
      let rewritten = Self.rewriting(string, replacements)
      if rewritten != string { changed = true }
      return rewritten
    case let array as [Any]:
      return array.map { rewrite($0, replacements, &changed) }
    case let dictionary as [String: Any]:
      var result: [String: Any] = [:]
      result.reserveCapacity(dictionary.count)
      for (key, nested) in dictionary {
        let rewrittenKey = Self.rewriting(key, replacements)
        if rewrittenKey != key { changed = true }
        result[rewrittenKey] = rewrite(nested, replacements, &changed)
      }
      return result
    default:
      return value
    }
  }

  private static func rewriting(_ string: String, _ replacements: [(String, String)]) -> String {
    for (legacy, branded) in replacements where string.hasPrefix(legacy) {
      return branded + string.dropFirst(legacy.count)
    }
    return string
  }

  // MARK: - Per-repository settings file.

  /// Renames each known repository's `supacode.json` to `kage.json`. A repository
  /// that already owns a `kage.json` keeps it — that file is the live one, and its
  /// stale sibling stays put rather than overwriting it.
  private static func convertRepositorySettingsFiles(fileSystem: BrandFileSystem) -> [String] {
    var converted: [String] = []
    for root in repositoryRoots(fileSystem: fileSystem) {
      let rootURL = URL(filePath: root, directoryHint: .isDirectory)
      let legacy = SupacodePaths.legacyBrandRepositorySettingsURL(for: rootURL)
      let branded = SupacodePaths.repositorySettingsURL(for: rootURL)
      guard fileSystem.fileExists(legacy), !fileSystem.fileExists(branded) else { continue }
      do {
        try fileSystem.moveItem(legacy, branded)
        converted.append(root)
      } catch {
        logger.warning("Failed to convert \(legacy.path(percentEncoded: false)) to kage.json: \(error)")
      }
    }
    return converted
  }

  /// Local repository roots, from the split store when it exists and the legacy
  /// monolith when it doesn't — this runs before the relocation, so a user coming
  /// from a pre-split build has only `settings.json`.
  private static func repositoryRoots(fileSystem: BrandFileSystem) -> [String] {
    let decoder = JSONDecoder()
    if let data = fileSystem.readData(SupacodePaths.routesURL),
      let routes = try? decoder.decode(RoutesFile.self, from: data)
    {
      return routes.local
    }
    if let data = fileSystem.readData(SupacodePaths.legacySettingsURL),
      let legacy = try? decoder.decode(SettingsFile.self, from: data)
    {
      return legacy.repositoryRoots
    }
    return []
  }
}
