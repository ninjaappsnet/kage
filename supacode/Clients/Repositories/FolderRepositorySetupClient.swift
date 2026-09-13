import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Filesystem side effects behind the nested-folder prompt: turning a picked
/// folder into its own git repository, and keeping it out of the enclosing
/// repository's status output.
nonisolated struct FolderRepositorySetupClient: Sendable {
  var initializeRepository: @Sendable (URL) async throws -> Void
  var ignoreFolder: @Sendable (NestedFolderCandidate, NestedFolderIgnoreTarget) async throws -> Void
}

extension FolderRepositorySetupClient: DependencyKey {
  static let liveValue = FolderRepositorySetupClient(
    initializeRepository: { folderURL in
      _ = try await Self.runGit(["-C", folderURL.path(percentEncoded: false), "init"])
    },
    ignoreFolder: { candidate, target in
      switch target {
      case .doNotIgnore:
        return
      case .gitignore:
        try Self.appendPattern(
          candidate.ignorePattern,
          to: candidate.parentRootURL.appending(path: ".gitignore")
        )
      case .localExclude:
        let infoDirectory = try await Self.gitCommonDirectory(for: candidate.parentRootURL)
          .appending(path: "info", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: infoDirectory, withIntermediateDirectories: true)
        try Self.appendPattern(candidate.ignorePattern, to: infoDirectory.appending(path: "exclude"))
      }
    }
  )

  static let testValue = FolderRepositorySetupClient(
    initializeRepository: unimplemented("FolderRepositorySetupClient.initializeRepository"),
    ignoreFolder: unimplemented("FolderRepositorySetupClient.ignoreFolder")
  )

  /// `--git-common-dir` rather than `--git-dir` so a linked worktree writes to
  /// the repository's shared `info/exclude` instead of a per-worktree one.
  nonisolated private static func gitCommonDirectory(for repositoryRoot: URL) async throws -> URL {
    let output = try await runGit(
      ["-C", repositoryRoot.path(percentEncoded: false), "rev-parse", "--git-common-dir"]
    )
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return repositoryRoot.appending(path: ".git", directoryHint: .isDirectory)
    }
    // git answers relative to the repository root when it can.
    return trimmed.hasPrefix("/")
      ? URL(fileURLWithPath: trimmed, isDirectory: true)
      : repositoryRoot.appending(path: trimmed, directoryHint: .isDirectory)
  }

  /// Appends once. Re-running the prompt for the same folder must not stack
  /// duplicate lines in a file the user may have hand-edited.
  nonisolated private static func appendPattern(_ pattern: String, to fileURL: URL) throws {
    let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    let lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
    guard !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == pattern }) else {
      return
    }
    var updated = existing
    if !updated.isEmpty, !updated.hasSuffix("\n") { updated += "\n" }
    updated += "\(pattern)\n"
    try updated.write(to: fileURL, atomically: true, encoding: .utf8)
  }

  nonisolated private static func runGit(_ arguments: [String]) async throws -> String {
    try await ShellClient.live.run(
      URL(fileURLWithPath: "/usr/bin/env"),
      ["git"] + arguments,
      nil
    ).stdout
  }
}

extension DependencyValues {
  var folderRepositorySetup: FolderRepositorySetupClient {
    get { self[FolderRepositorySetupClient.self] }
    set { self[FolderRepositorySetupClient.self] = newValue }
  }
}
