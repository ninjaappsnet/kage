import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

/// Hibernation waits on content that is *momentarily* ineligible — a terminal
/// whose zmx session has not attached yet — by re-arming its grace timer. A file
/// viewer is ineligible forever: it has no session behind the renderer. Without
/// a way to say so, every backgrounded viewer tab would re-arm its timer on
/// every grace window for the life of the app.
@MainActor
struct FileViewerHibernationTests {
  /// Live content with a renderer that can never hibernate — the viewer's shape,
  /// without dragging a real file off disk into a reducer test.
  private final class SessionlessContent: TabContent {
    let id: ContentID
    let kind: ContentKind = .fileViewer
    private var view: NSView?

    init(id: ContentID) {
      self.id = id
    }

    var renderer: NSView? { view }
    var supportsHibernation: Bool { false }

    func startSession(at geometry: ContentGeometry) {
      view = NSView()
    }

    func hibernate() {
      Issue.record("A sessionless content must never be asked to hibernate.")
    }

    func snapshot() -> ContentSnapshot {
      ContentSnapshot(id: id, state: .fileViewer(FileViewerContentState(filePath: "/tmp/repo/README.md")))
    }
  }

  private struct Harness {
    let store: TestStoreOf<TerminalsFeature>
    let clock: TestClock<Duration>
    let worktreeID: Worktree.ID
    let hiddenTab: TabID
    let hiddenContent: SessionlessContent
  }

  /// One pane, a selected terminal and a hidden viewer, both live.
  private func makeHarness() -> Harness {
    let worktreeID = Worktree.ID("/tmp/viewer-hib")
    let paneID = PaneID()
    let selectedTab = TabID()
    let hiddenTab = TabID()
    let selectedContent = SessionlessContent(id: ContentID())
    let hiddenContent = SessionlessContent(id: ContentID())
    let runtime = ContentRuntime()
    _ = runtime.provision(selectedContent, at: .fallback)
    _ = runtime.provision(hiddenContent, at: .fallback)
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [
            TabItem(
              id: selectedTab,
              title: "One",
              content: selectedContent.snapshot()
            ),
            TabItem(
              id: hiddenTab,
              title: "README.md",
              content: hiddenContent.snapshot()
            ),
          ],
          selectedTabID: selectedTab
        )
      ],
      focusedPaneID: paneID
    )
    let clock = TestClock()
    let store = TestStore(
      initialState: TerminalsFeature.State(layouts: [LayoutFeature.State(id: worktreeID, layout: layout)])
    ) {
      TerminalsFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.contentRuntime = runtime
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    return Harness(
      store: store,
      clock: clock,
      worktreeID: worktreeID,
      hiddenTab: hiddenTab,
      hiddenContent: hiddenContent
    )
  }

  /// The timer is never armed in the first place, so no grace window ever fires.
  /// TestStore's exhaustivity is what proves the absence: an armed timer would
  /// deliver a `hibernationGraceElapsed` this test never receives.
  @Test(.dependencies) func aBackgroundedViewerTabNeverArmsTheGraceTimer() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHarness()

    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.recentWorktreeIDs = [harness.worktreeID]
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow)

    #expect(harness.store.state.hibernationArmedTabs.isEmpty)
    #expect(harness.hiddenContent.renderer != nil)
  }

  /// A second window would catch a re-arm that the first one hid.
  @Test(.dependencies) func aBackgroundedViewerTabStaysLiveAcrossGraceWindows() async {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.terminalHibernationEnabled = true }
    let harness = makeHarness()

    await harness.store.send(.selectedWorktreeChanged(harness.worktreeID)) {
      $0.selectedWorktreeID = harness.worktreeID
      $0.recentWorktreeIDs = [harness.worktreeID]
    }
    await harness.clock.advance(by: TerminalsFeature.hibernationGraceWindow * 3)

    #expect(harness.store.state.hibernationArmedTabs.isEmpty)
    #expect(harness.store.state.hibernationDeferralLogged.isEmpty)
    #expect(harness.hiddenContent.renderer != nil)
  }
}
