import Foundation

/// Upstream added its own file explorer as an inspector pane (supabitapp/supacode#769).
/// This fork already has a file explorer and viewer as docked panels, so shipping both
/// would give users two unrelated ways to browse the same worktree.
///
/// Upstream's implementation stays in the codebase — deleting it would turn every future
/// sync into a conflict — but nothing exposes it: no toolbar button, no menu command, no
/// announcement card. Flip this to `true` to bring all three back at once.
enum UpstreamFileExplorerAvailability {
  static let isEnabled = false
}
