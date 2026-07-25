import Sharing
import SwiftUI

/// Closes the file preview whenever the sidebar's active workspace changes.
///
/// `WorktreeDetailView` already closes the viewer when the selected worktree
/// changes, but a workspace switch can land on "nothing selected" (the new
/// workspace has no visible rows). That tears the detail branch down instead of
/// changing its selection, so the selection-driven `onChange` never fires and
/// the panel reappears still holding a file from the workspace the user left.
///
/// Observing `@Shared(.sidebar)` from a modifier rather than from
/// `WorktreeDetailView` itself keeps that hot body out of the sidebar's
/// invalidation surface: only this modifier's body re-runs when an unrelated
/// pin / collapse / archive mutation lands, and the content it wraps is passed
/// through untouched.
struct CloseFileViewerOnWorkspaceSwitch: ViewModifier {
  @Shared(.sidebar) private var sidebar: SidebarState
  private let close: () -> Void

  init(close: @escaping () -> Void) {
    self.close = close
  }

  func body(content: Content) -> some View {
    content.onChange(of: sidebar.activeWorkspaceID) { _, _ in close() }
  }
}
