import AppKit
import Foundation
import IdentifiedCollections

/// Opens a file as a tab in the worktree's pane layout.
///
/// Fork-owned, as an extension rather than methods on upstream's
/// `WorktreeTerminalManager`, so an upstream rework of the terminal layer costs
/// one adapter here instead of a conflict inside their file (see "Minimizing
/// Upstream Merge Conflicts" in AGENTS.md).
enum FileViewerTabOpening {
  /// The already-open viewer tab for `url`, if the layout has one. Comparing
  /// standardized paths is what keeps a second buffer from being minted for a
  /// file that is already open — two live buffers over one path diverge, and
  /// whichever saves last silently clobbers the other.
  static func existingTab(for url: URL, in layout: PaneLayout) -> TabID? {
    let target = FileViewerContentState(fileURL: url).filePath
    for pane in layout.panes {
      for tab in pane.tabs {
        guard case .fileViewer(let state) = tab.content.state, state.filePath == target else { continue }
        return tab.id
      }
    }
    return nil
  }

  /// Tab title for a viewer: the file name alone. The full path is in the tab's
  /// own header, and a strip full of paths would truncate to nothing.
  static func tabTitle(for url: URL) -> String {
    url.lastPathComponent
  }

  /// Builds the live content for a viewer tab. Called from the layout's content
  /// factory, which is the only place allowed to construct content.
  @MainActor
  static func makeContent(id: ContentID, state: FileViewerContentState) -> any TabContent {
    FileViewerContent(id: id, fileURL: state.fileURL)
  }
}

extension WorktreeTerminalManager {
  /// Opens `url` as a viewer tab in `worktree`'s layout, reusing an existing tab
  /// for the same file rather than minting a rival buffer. Placement follows the
  /// same rule as the open-file script hook, so the app has one answer for
  /// "I opened a file" regardless of which path produced it.
  func openFileInViewerTab(_ url: URL, in worktree: Worktree) {
    guard let layout = layoutState(for: worktree.id)?.layout else {
      // A layout-less worktree has nowhere to put a tab; the terminal bootstrap
      // creates one, and the user can open the file again once it exists.
      return
    }
    if let existing = FileViewerTabOpening.existingTab(for: url, in: layout) {
      sendLayout(worktree.id, .selectTab(id: existing))
      if let pane = layout.pane(containingTab: existing) {
        sendLayout(worktree.id, .focusPane(.pane(pane.id)))
      }
      return
    }

    let zoomedLeaf: PaneID?
    if case .leaf(let leaf) = layout.tree.zoomed { zoomedLeaf = leaf } else { zoomedLeaf = nil }
    let leafCount = layout.tree.leaves().count
    let topRight = layout.tree.topRightmostLeaf()
    let placement = Self.openFilePlacement(
      zoomedLeaf: zoomedLeaf,
      leafCount: leafCount,
      topRightLeaf: topRight,
      focusedPane: layout.focusedPaneID,
      hasRoomForSplit: leafCount <= 1
        && Self.paneIsWideEnoughForViewerSplit(topRight ?? layout.focusedPaneID, in: layout)
    )

    // Anchor geometry on the focused content so the viewer is born at a real
    // size; an off-window default would mount it at an arbitrary tiny frame.
    let anchorContent = layout.focusedPaneID.flatMap { layout.panes[id: $0]?.selectedTab?.content.id }
    let contentID = ContentID(rawValue: UUID())
    let spec = NewTabSpec(
      tabID: TabID(rawValue: contentID.rawValue),
      contentID: contentID,
      title: FileViewerTabOpening.tabTitle(for: url),
      content: .fileViewer(FileViewerContentState(fileURL: url)),
      geometry: ContentRuntime.liveValue.spawnGeometry(near: anchorContent, fallback: anchorContent)
    )

    switch placement {
    case .tab(let paneToken):
      guard let paneID = layout.pane(forToken: paneToken)?.id else { return }
      sendLayout(worktree.id, .newTab(inPane: paneID, spec: spec))
    case .splitRight(let paneToken):
      guard let paneID = layout.pane(forToken: paneToken)?.id else { return }
      sendLayout(worktree.id, .splitPane(id: paneID, direction: .right, spec: spec))
    case nil:
      // No pane at all (a tab-less layout is valid): mint the first one.
      sendLayout(worktree.id, .newTab(inPane: layout.focusedPaneID ?? PaneID(), spec: spec))
    }
  }

  /// The file shown by the focused pane's selected tab, when that tab is a
  /// viewer. Drives the explorer's "this row is open" highlight; nil whenever a
  /// terminal is focused, so the highlight tracks what is actually on screen
  /// rather than the last file opened.
  func selectedViewerFileURL(for worktreeID: Worktree.ID) -> URL? {
    guard let layout = layoutState(for: worktreeID)?.layout,
      let focusedPaneID = layout.focusedPaneID,
      case .fileViewer(let state) = layout.panes[id: focusedPaneID]?.selectedTab?.content.state
    else { return nil }
    return state.fileURL
  }

  /// Mirrors the terminal path's room check, but reads the pane's own renderer
  /// rather than assuming a terminal is mounted there.
  private static func paneIsWideEnoughForViewerSplit(_ paneID: PaneID?, in layout: PaneLayout) -> Bool {
    guard let paneID,
      let contentID = layout.panes[id: paneID]?.selectedTab?.content.id,
      let renderer = ContentRuntime.liveValue.renderer(for: contentID)
    else { return false }
    return renderer.bounds.width >= minimumViewerSplitWidth
  }

  /// Below this a horizontal split leaves the file and the terminal both too
  /// narrow to read, so the file opens as a tab instead.
  private static let minimumViewerSplitWidth: CGFloat = 600
}
