import Foundation
import Testing

@testable import supacode

struct NestedFolderResolutionTests {
  private let parent = URL(fileURLWithPath: "/Users/me/dev/wbm")
  private let nested = URL(fileURLWithPath: "/Users/me/dev/wbm/shoot-assistant")

  /// The reported bug: `wt root` walks up to the enclosing repo, that repo is
  /// already a Kage row, so the add deduped to nothing and failed silently.
  @Test func promptsWhenPickedFolderResolvesToAnAlreadyAddedParent() {
    let outcome = NestedFolderResolution.resolve(
      pickedURL: nested,
      resolvedRoot: parent,
      existingRootPaths: ["/Users/me/dev/wbm"]
    )

    #expect(
      outcome
        == .nested(
          NestedFolderCandidate(
            folderURL: nested.standardizedFileURL,
            parentRootURL: parent.standardizedFileURL
          )
        )
    )
  }

  /// Picking a subdirectory of a repo Kage doesn't know yet keeps the upstream
  /// convenience: it adds the repo, no dialog.
  @Test func usesResolvedRootWhenParentIsNotAddedYet() {
    let outcome = NestedFolderResolution.resolve(
      pickedURL: nested,
      resolvedRoot: parent,
      existingRootPaths: []
    )

    #expect(outcome == .root(parent.standardizedFileURL))
  }

  /// A nested folder that is its own repo (`wbm/ContentAPI`) resolves to itself,
  /// so it never reaches the prompt.
  @Test func usesResolvedRootWhenPickedFolderIsItsOwnRoot() {
    let outcome = NestedFolderResolution.resolve(
      pickedURL: nested,
      resolvedRoot: nested,
      existingRootPaths: ["/Users/me/dev/wbm"]
    )

    #expect(outcome == .root(nested.standardizedFileURL))
  }

  /// `URL` renders directories with a trailing slash in some code paths; the
  /// match has to survive that or every re-add would prompt.
  @Test func trailingSlashDoesNotDefeatTheRootMatch() {
    let outcome = NestedFolderResolution.resolve(
      pickedURL: URL(fileURLWithPath: "/Users/me/dev/wbm/", isDirectory: true),
      resolvedRoot: parent,
      existingRootPaths: ["/Users/me/dev/wbm"]
    )

    #expect(outcome == .root(parent.standardizedFileURL))
  }

  @Test func ignorePatternAnchorsToTheParentRepositoryRoot() {
    let candidate = NestedFolderCandidate(
      folderURL: nested,
      parentRootURL: parent
    )

    #expect(candidate.ignorePattern == "/shoot-assistant/")
  }

  @Test func ignorePatternCoversFoldersNestedSeveralLevelsDown() {
    let candidate = NestedFolderCandidate(
      folderURL: URL(fileURLWithPath: "/Users/me/dev/wbm/apps/shoot"),
      parentRootURL: parent
    )

    #expect(candidate.ignorePattern == "/apps/shoot/")
  }
}
