import Foundation
import Testing

@testable import supacode

/// The File Explorer roots at the focused terminal's pwd, so these lock the
/// exact points where the resolver must decline and fall back to the worktree
/// root instead of rooting the tree somewhere wrong.
@MainActor
struct TerminalFocusedPwdTests {
  @Test func noFocusedContentResolvesToNil() {
    let resolved = TerminalFocusedPwd.resolve(focusedContentID: nil) { _ in "/tmp/repo/wt" }

    #expect(resolved == nil)
  }

  @Test func hibernatedSurfaceReportsNoPwd() {
    let resolved = TerminalFocusedPwd.resolve(focusedContentID: UUID()) { _ in nil }

    #expect(resolved == nil)
  }

  /// A shell that has not sent OSC 7 yet reads back as empty, which would
  /// otherwise resolve to the process cwd rather than the worktree.
  @Test func emptyPwdResolvesToNil() {
    let resolved = TerminalFocusedPwd.resolve(focusedContentID: UUID()) { _ in "" }

    #expect(resolved == nil)
  }

  @Test func reportedPwdResolvesToADirectoryURL() {
    let resolved = TerminalFocusedPwd.resolve(focusedContentID: UUID()) { _ in "/tmp/repo/wt/Sources" }

    #expect(resolved == URL(filePath: "/tmp/repo/wt/Sources", directoryHint: .isDirectory))
  }

  /// `cd ..` reports the traversal literally; the explorer keys its tree off
  /// the URL, so an unstandardized path would fork the node identity.
  @Test func traversalInThePwdIsStandardized() {
    let resolved = TerminalFocusedPwd.resolve(focusedContentID: UUID()) { _ in "/tmp/repo/wt/Sources/.." }

    #expect(resolved == URL(filePath: "/tmp/repo/wt", directoryHint: .isDirectory))
  }

  /// The lookup is keyed by the focused id, not by "any live surface": a split
  /// with two shells in different directories must follow the focused one.
  @Test func lookupUsesTheFocusedContentID() {
    let focused = UUID()
    let other = UUID()

    let resolved = TerminalFocusedPwd.resolve(focusedContentID: focused) { id in
      id == focused ? "/tmp/repo/wt/focused" : "/tmp/repo/wt/other"
    }

    #expect(resolved == URL(filePath: "/tmp/repo/wt/focused", directoryHint: .isDirectory))
  }
}
