import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

/// Opening a file must never mint a second tab for a path that is already open:
/// two live buffers over one file diverge, and whichever saves last silently
/// clobbers the other. These lock the lookup that prevents it, plus the content
/// payload that survives a relaunch.
struct FileViewerTabOpeningTests {
  private func viewerTab(_ path: String, id: UUID = UUID()) -> TabItem {
    TabItem(
      id: TabID(rawValue: id),
      title: URL(filePath: path).lastPathComponent,
      content: ContentSnapshot(
        id: ContentID(rawValue: id),
        state: .fileViewer(FileViewerContentState(filePath: path))
      )
    )
  }

  private func terminalTab(id: UUID = UUID()) -> TabItem {
    TabItem(
      id: TabID(rawValue: id),
      title: "Terminal",
      content: ContentSnapshot(
        id: ContentID(rawValue: id),
        state: .terminal(TerminalContentState(workingDirectory: nil))
      )
    )
  }

  private func layout(panes: [[TabItem]]) -> PaneLayout {
    var built: IdentifiedArrayOf<Pane> = []
    var paneIDs: [PaneID] = []
    for tabs in panes {
      let paneID = PaneID()
      paneIDs.append(paneID)
      built.append(Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: tabs), selectedTabID: tabs.first?.id))
    }
    return PaneLayout(
      tree: SplitTree(view: paneIDs[0]),
      panes: built,
      focusedPaneID: paneIDs[0]
    )
  }

  // MARK: - Dedup lookup.

  @Test func findsAnOpenViewerTabForTheSamePath() {
    let tab = viewerTab("/tmp/repo/README.md")
    let layout = layout(panes: [[terminalTab(), tab]])

    let found = FileViewerTabOpening.existingTab(for: URL(filePath: "/tmp/repo/README.md"), in: layout)

    #expect(found == tab.id)
  }

  @Test func returnsNilWhenThePathIsNotOpen() {
    let layout = layout(panes: [[terminalTab(), viewerTab("/tmp/repo/README.md")]])

    let found = FileViewerTabOpening.existingTab(for: URL(filePath: "/tmp/repo/OTHER.md"), in: layout)

    #expect(found == nil)
  }

  /// A terminal whose cwd happens to be the file's directory is not a viewer.
  @Test func ignoresNonViewerTabs() {
    let layout = layout(panes: [[terminalTab(), terminalTab()]])

    let found = FileViewerTabOpening.existingTab(for: URL(filePath: "/tmp/repo/README.md"), in: layout)

    #expect(found == nil)
  }

  /// The explorer can open a file into pane A while the user is focused on pane
  /// B; the tab is still open and must be reused, not duplicated.
  @Test func findsAViewerTabInANonFocusedPane() {
    let tab = viewerTab("/tmp/repo/docs/guide.md")
    let layout = layout(panes: [[terminalTab()], [tab]])

    let found = FileViewerTabOpening.existingTab(for: URL(filePath: "/tmp/repo/docs/guide.md"), in: layout)

    #expect(found == tab.id)
  }

  /// The explorer hands over whatever URL it built; a traversal or a trailing
  /// slash must not read as a different file.
  @Test func matchesAcrossUnstandardizedPaths() {
    let tab = viewerTab("/tmp/repo/README.md")
    let layout = layout(panes: [[tab]])

    let found = FileViewerTabOpening.existingTab(for: URL(filePath: "/tmp/repo/docs/../README.md"), in: layout)

    #expect(found == tab.id)
  }

  /// The stored payload is normalized on the way in, so a tab minted from an
  /// unstandardized URL is still found by its canonical path.
  @Test func storedPathIsStandardized() {
    let state = FileViewerContentState(filePath: "/tmp/repo/docs/../README.md")

    #expect(state.filePath == "/tmp/repo/README.md")
    #expect(state.fileURL == URL(filePath: "/tmp/repo/README.md"))
  }

  // MARK: - Content payload.

  @Test func contentStateReportsTheFileViewerKind() {
    let state = ContentState.fileViewer(FileViewerContentState(filePath: "/tmp/repo/README.md"))

    #expect(state.kind == .fileViewer)
  }

  /// A viewer session is a file on disk, not a process; nothing about it dies
  /// with the app, so it must persist like a terminal tab rather than be
  /// stripped as ephemeral.
  @Test func viewerContentIsNotEphemeral() {
    let state = ContentState.fileViewer(FileViewerContentState(filePath: "/tmp/repo/README.md"))

    #expect(state.isEphemeral == false)
  }

  @Test func roundTripsThroughCoding() throws {
    let state = ContentState.fileViewer(FileViewerContentState(filePath: "/tmp/repo/README.md"))

    let decoded = try JSONDecoder().decode(ContentState.self, from: JSONEncoder().encode(state))

    #expect(decoded == state)
  }

  /// `freshSeed` backs "give me a new tab like this one". A viewer has no
  /// meaningful blank state, so the seed keeps the same file rather than
  /// producing a viewer pointed at nothing.
  @Test func freshSeedKeepsTheFile() {
    let state = ContentState.fileViewer(FileViewerContentState(filePath: "/tmp/repo/README.md"))

    #expect(state.freshSeed == state)
  }

  // MARK: - Tab presentation.

  @Test func tabTitleIsTheFileName() {
    #expect(FileViewerTabOpening.tabTitle(for: URL(filePath: "/tmp/repo/docs/guide.md")) == "guide.md")
  }
}
