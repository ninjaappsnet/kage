import Testing

@testable import supacode

/// Upstream moved a tab's live title onto the content's `TabChrome`. A viewer
/// has no process rewriting its title: the layout's own title (the file name)
/// is the whole truth, so the chrome must report nothing rather than echo it
/// and turn every keystroke into a title report.
@MainActor
struct FileViewerTabChromeTests {
  private func viewerTab(title: String = "README.md", customTitle: String? = nil) -> TabItem {
    TabItem(
      id: TabID(),
      title: title,
      customTitle: customTitle,
      content: ContentSnapshot(
        id: ContentID(),
        state: .fileViewer(FileViewerContentState(filePath: "/tmp/repo/README.md"))
      )
    )
  }

  @Test func aViewerReportsNoTitle() {
    #expect(FileViewerTabChrome(model: FileViewerModel()).reportedTitle == nil)
  }

  @Test func aViewerTabKeepsTheLayoutsOwnTitle() {
    let chrome = FileViewerTabChrome(model: FileViewerModel())
    #expect(TabTitle.resolved(for: viewerTab(), chrome: chrome) == "README.md")
    #expect(TabTitle.stored(for: viewerTab(), chrome: chrome) == "README.md")
  }

  @Test func aUserOverrideStillWinsOnAViewerTab() {
    let chrome = FileViewerTabChrome(model: FileViewerModel())
    let tab = viewerTab(customTitle: "Notes")
    #expect(TabTitle.resolved(for: tab, chrome: chrome) == "Notes")
    #expect(TabTitle.stored(for: tab, chrome: chrome) == "README.md")
  }
}
