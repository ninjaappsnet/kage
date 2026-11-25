import CoreGraphics
import Foundation

/// What the remote file explorer column shows for the host's channel status.
nonisolated enum RemoteKageFilesPresentation: Equatable, Sendable {
  /// The docked explorer, with a "Connecting…" overlay until the first answer.
  /// An offline link still shows it: the tree keeps its last listing and the
  /// panel's own banner says why it stopped updating.
  case explorer(isConnecting: Bool)
  /// Nothing to browse until Kage is updated on one side.
  case unavailable(title: String, message: String, systemImage: String)

  static func resolve(status: RemoteKageServeSession.Status?, hostName: String) -> Self {
    switch status {
    case nil, .idle, .connecting:
      return .explorer(isConnecting: true)
    case .connected, .unavailable(.offline):
      return .explorer(isConnecting: false)
    case .unavailable(.needsUpdate):
      return .unavailable(
        title: "Update Kage on \(hostName)",
        message:
          "Browsing files on \(hostName) needs a newer Kage there. Update Kage on that Mac, then reopen the explorer.",
        systemImage: "arrow.down.circle"
      )
    case .unavailable(.hostIsNewer):
      return .unavailable(
        title: "Update Kage on This Mac",
        message: "\(hostName) runs a newer Kage whose file protocol this Mac doesn't understand yet.",
        systemImage: "arrow.down.circle"
      )
    }
  }
}

/// How a click in the remote explorer lands in the right-hand viewer pane,
/// which shows one file at a time.
nonisolated enum RemoteKageFileViewerOpening: Equatable, Sendable {
  case open
  /// Already on screen: keep the buffer (and any unsaved edits) as it is.
  case alreadyShown
  /// Another file would replace unsaved edits: ask first.
  case confirmDiscard

  static let minimumWidth: CGFloat = 280
  static let maximumWidth: CGFloat = 1400
  static let defaultWidth: CGFloat = 520

  static func decide(requested: URL, shown: URL?, isDirty: Bool) -> Self {
    guard let shown else { return .open }
    if shown.standardizedFileURL == requested.standardizedFileURL { return .alreadyShown }
    return isDirty ? .confirmDiscard : .open
  }

  static func clampedWidth(_ width: CGFloat) -> CGFloat {
    min(max(width, minimumWidth), maximumWidth)
  }
}

/// Pure decisions behind the remote worktree's files UI.
enum RemoteKageFiles {
  /// The explorer's root: the selected tab's folder, else the worktree.
  static func explorerRootURL(tabs: [HostSnapshot.Tab], selectedTabID: String?, worktreePath: String) -> URL {
    URL(
      filePath: RemoteKageWorktreeDetail.explorerRoot(
        tabs: tabs,
        selectedTabID: selectedTabID,
        worktreePath: worktreePath
      ),
      directoryHint: .isDirectory
    )
  }

  /// The host's file channel stays open only while the explorer or the viewer
  /// is on screen.
  static func needsConnection(isExplorerVisible: Bool, isViewerOpen: Bool) -> Bool {
    isExplorerVisible || isViewerOpen
  }
}
