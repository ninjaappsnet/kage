import Foundation

/// Resolves the directory the File Explorer should root at: the pwd the shell
/// last reported over OSC 7 for the worktree's focused terminal.
///
/// Lives in this fork-owned file, as an extension rather than a method on
/// upstream's `WorktreeTerminalManager`, so an upstream rework of the terminal
/// layer costs one adapter here instead of a conflict inside their file (see
/// "Minimizing Upstream Merge Conflicts" in AGENTS.md).
enum TerminalFocusedPwd {
  /// Pure core: a focused content id plus a pwd lookup in, a directory URL out.
  /// `nil` when nothing is focused, the surface is hibernated, or the shell has
  /// not reported a pwd yet — callers fall back to the worktree root.
  static func resolve(focusedContentID: UUID?, pwd: (UUID) -> String?) -> URL? {
    guard let focusedContentID,
      let reported = pwd(focusedContentID),
      !reported.isEmpty
    else { return nil }
    return URL(filePath: reported, directoryHint: .isDirectory).standardizedFileURL
  }
}

extension WorktreeTerminalManager {
  /// pwd of the focused surface for a worktree, if its content host already
  /// exists. Deliberately does NOT create the host (unlike `host(for:)`) so a
  /// read from a view body can't clobber setup-script gating. The file explorer
  /// reads this to track `cd`s in the active terminal; `nil` before the terminal
  /// is created or before the shell reports a pwd.
  ///
  /// Reading `bridge.state.pwd` (an `@Observable`) here lets SwiftUI re-render
  /// the explorer when the pwd changes.
  func focusedSurfacePwd(for worktreeID: Worktree.ID) -> URL? {
    guard let host = hostIfExists(for: worktreeID) else { return nil }
    return TerminalFocusedPwd.resolve(focusedContentID: host.focusedContentID) { contentID in
      host.liveSurface(contentID)?.bridge.state.pwd
    }
  }
}
