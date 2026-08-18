import Foundation
import Testing

@testable import SupacodeSettingsShared

/// The fork stores its config under its own brand (`~/.kage`, `~/.config/kage`,
/// `<repo>/kage.json`) while still being able to name the upstream locations it
/// migrates away from.
struct KageBrandPathsTests {
  private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

  @Test func baseDirectoryUsesTheKageBrand() {
    #expect(SupacodePaths.baseDirectory == home.appending(path: ".kage", directoryHint: .isDirectory))
    #expect(
      SupacodePaths.legacyBrandBaseDirectory
        == home.appending(path: ".supacode", directoryHint: .isDirectory))
  }

  @Test func configDirectoryUsesTheKageBrand() {
    // No XDG_CONFIG_HOME in the test environment, so both resolve under `~/.config`.
    let configRoot = home.appending(path: ".config", directoryHint: .isDirectory)
    #expect(
      SupacodePaths.configBaseDirectory == configRoot.appending(path: "kage", directoryHint: .isDirectory))
    #expect(
      SupacodePaths.legacyBrandConfigBaseDirectory
        == configRoot.appending(path: "supacode", directoryHint: .isDirectory))
  }

  @Test func repositorySettingsFileUsesTheKageBrand() {
    let root = URL(filePath: "/tmp/repo", directoryHint: .isDirectory)
    #expect(SupacodePaths.repositorySettingsURL(for: root).lastPathComponent == "kage.json")
    #expect(SupacodePaths.legacyBrandRepositorySettingsURL(for: root).lastPathComponent == "supacode.json")
  }

  @Test func derivedPathsFollowTheBrandedBase() {
    #expect(
      SupacodePaths.reposDirectory == SupacodePaths.baseDirectory.appending(path: "repos", directoryHint: .isDirectory))
    #expect(
      SupacodePaths.backupDirectory
        == SupacodePaths.baseDirectory.appending(path: ".backup", directoryHint: .isDirectory))
    #expect(SupacodePaths.legacySettingsURL == SupacodePaths.baseDirectory.appending(path: "settings.json"))
    #expect(SupacodePaths.configURL == SupacodePaths.configBaseDirectory.appending(path: "config.json"))
    #expect(
      SupacodePaths.legacyBrandReposDirectory
        == SupacodePaths.legacyBrandBaseDirectory.appending(path: "repos", directoryHint: .isDirectory))
  }
}
