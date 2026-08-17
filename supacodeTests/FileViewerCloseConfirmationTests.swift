import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

/// Closing a terminal tab interrupts work that zmx keeps alive, so the user can
/// reattach and the confirm-close setting is theirs to turn off. Closing a
/// viewer tab with an unsaved buffer destroys the text outright. These lock the
/// escalation that separates the two, and the save path the confirmation offers.
@MainActor
struct FileViewerCloseConfirmationTests {
  /// Content with a buffer: reports unsaved work, and records whether the close
  /// path asked it to save.
  private final class UnsavedContent: TabContent {
    let id: ContentID
    let kind: ContentKind = .fileViewer
    /// Whether a save attempt actually clears the buffer.
    var saveSucceeds = true
    var isDirty = false
    private(set) var saveCalls = 0
    private var view: NSView?

    init(id: ContentID) {
      self.id = id
    }

    var renderer: NSView? { view }
    var supportsHibernation: Bool { false }
    var hasKillableSession: Bool { false }
    var isBusy: Bool { isDirty }
    var closeDiscardsUnsavedWork: Bool { isDirty }

    func saveUnsavedWork() -> Bool {
      saveCalls += 1
      if saveSucceeds { isDirty = false }
      return !isDirty
    }

    func startSession(at geometry: ContentGeometry) {
      view = NSView()
    }

    func hibernate() {}

    func snapshot() -> ContentSnapshot {
      ContentSnapshot(id: id, state: .fileViewer(FileViewerContentState(filePath: "/tmp/repo/README.md")))
    }
  }

  private struct Harness {
    let store: TestStoreOf<LayoutFeature>
    let paneID: PaneID
    let tabID: TabID
    let content: UnsavedContent
    let killedContents: LockIsolated<[ContentID]>
  }

  private func makeHarness() -> Harness {
    let paneID = PaneID()
    let tabID = TabID()
    let contentID = ContentID()
    let content = UnsavedContent(id: contentID)
    let runtime = ContentRuntime()
    _ = runtime.provision(content, at: .fallback)
    let killed = LockIsolated<[ContentID]>([])
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [TabItem(id: tabID, title: "README.md", content: content.snapshot())],
          selectedTabID: tabID
        )
      ],
      focusedPaneID: paneID
    )
    let store = TestStore(
      initialState: LayoutFeature.State(id: WorktreeID("/tmp/viewer-close"), layout: layout)
    ) {
      LayoutFeature()
    } withDependencies: {
      $0.contentRuntime = runtime
      $0[ContentSessionKiller.self] = ContentSessionKiller(
        kill: { contentID, _ in killed.withValue { $0.append(contentID) } }
      )
    }
    return Harness(store: store, paneID: paneID, tabID: tabID, content: content, killedContents: killed)
  }

  // MARK: - Escalation past the setting.

  /// "Never confirm" is a statement about interrupting recoverable work; it
  /// cannot be a licence to silently delete text the user typed.
  @Test(.dependencies) func aDirtyViewerConfirmsEvenWhenConfirmationIsOff() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .never }
    let harness = makeHarness()
    harness.content.isDirty = true

    await harness.store.send(.contentRequestedClose(content: harness.content.id, scope: .tab)) {
      $0.alertPaneID = harness.paneID
      $0.alert = LayoutFeature.closeConfirmationAlert(
        tabs: [harness.tabID], interrupts: true, discardsUnsavedWork: true
      )
    }

    #expect(harness.store.state.layout.panes[id: harness.paneID]?.tabs.count == 1)
  }

  /// The setting still means what it says for everything else.
  @Test(.dependencies) func aCleanViewerStillClosesImmediatelyWhenConfirmationIsOff() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .never }
    let harness = makeHarness()

    await harness.store.send(.contentRequestedClose(content: harness.content.id, scope: .tab)) {
      $0.layout.panes = []
      $0.layout.tree = SplitTree()
      $0.layout.focusedPaneID = nil
    }
    await harness.store.receive(.runtime(.killConfirmed(id: harness.content.id)))
  }

  // MARK: - The save path.

  @Test(.dependencies) func saveAndCloseWritesTheBufferThenClosesTheTab() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .never }
    let harness = makeHarness()
    harness.content.isDirty = true

    await harness.store.send(.contentRequestedClose(content: harness.content.id, scope: .tab)) {
      $0.alertPaneID = harness.paneID
      $0.alert = LayoutFeature.closeConfirmationAlert(
        tabs: [harness.tabID], interrupts: true, discardsUnsavedWork: true
      )
    }
    await harness.store.send(.alert(.presented(.saveAndClose(tabs: [harness.tabID])))) {
      $0.alertPaneID = nil
      $0.alert = nil
      $0.layout.panes = []
      $0.layout.tree = SplitTree()
      $0.layout.focusedPaneID = nil
    }
    await harness.store.receive(.runtime(.killConfirmed(id: harness.content.id)))

    #expect(harness.content.saveCalls == 1)
    #expect(harness.content.isDirty == false)
  }

  /// A failed write (permission denied, or the file changed on disk) must not
  /// take the buffer down with it — the tab stays so the user can resolve it.
  @Test(.dependencies) func aFailedSaveKeepsTheTabOpen() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .never }
    let harness = makeHarness()
    harness.content.isDirty = true
    harness.content.saveSucceeds = false

    await harness.store.send(.contentRequestedClose(content: harness.content.id, scope: .tab)) {
      $0.alertPaneID = harness.paneID
      $0.alert = LayoutFeature.closeConfirmationAlert(
        tabs: [harness.tabID], interrupts: true, discardsUnsavedWork: true
      )
    }
    await harness.store.send(.alert(.presented(.saveAndClose(tabs: [harness.tabID])))) {
      $0.alertPaneID = nil
      $0.alert = nil
    }

    #expect(harness.content.saveCalls == 1)
    #expect(harness.store.state.layout.panes[id: harness.paneID]?.tabs.count == 1)
  }

  /// Discard is the existing confirm path; it must never reach the save hook.
  @Test(.dependencies) func discardingClosesWithoutSaving() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .never }
    let harness = makeHarness()
    harness.content.isDirty = true

    await harness.store.send(.contentRequestedClose(content: harness.content.id, scope: .tab)) {
      $0.alertPaneID = harness.paneID
      $0.alert = LayoutFeature.closeConfirmationAlert(
        tabs: [harness.tabID], interrupts: true, discardsUnsavedWork: true
      )
    }
    await harness.store.send(.alert(.presented(.confirmClose(tabs: [harness.tabID])))) {
      $0.alertPaneID = nil
      $0.alert = nil
      $0.layout.panes = []
      $0.layout.tree = SplitTree()
      $0.layout.focusedPaneID = nil
    }
    await harness.store.receive(.runtime(.killConfirmed(id: harness.content.id)))

    #expect(harness.content.saveCalls == 0)
    #expect(harness.content.isDirty == true)
  }

  // MARK: - Session teardown.

  /// A viewer's renderer is the whole thing; there is no zmx session behind it,
  /// so closing must not spawn a kill for a session that never existed.
  @Test(.dependencies) func closingAViewerNeverKillsASession() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.confirmCloseTab = .never }
    let harness = makeHarness()

    await harness.store.send(.contentRequestedClose(content: harness.content.id, scope: .tab)) {
      $0.layout.panes = []
      $0.layout.tree = SplitTree()
      $0.layout.focusedPaneID = nil
    }
    await harness.store.receive(.runtime(.killConfirmed(id: harness.content.id)))

    #expect(harness.killedContents.value.isEmpty)
  }
}
