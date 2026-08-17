import AppKit
import SwiftUI

/// A file preview / editor hosted as a tab in the pane layout. Fork-owned
/// content kind: the layout only ever sees `TabContent`, so nothing about the
/// viewer leaks into `LayoutFeature`.
///
/// Not hibernatable — there is no session to keep alive behind a dropped
/// renderer, and a re-read from disk is cheap. `isBusy` reports the unsaved
/// buffer, which is what makes the layout's close confirmation fire before a
/// dirty tab goes away.
@MainActor
final class FileViewerContent: TabContent {
  let id: ContentID
  let kind: ContentKind = .fileViewer

  /// Instance-owned so the buffer, dirty state, and view mode survive tab
  /// switches — the renderer is only built once and reused.
  let model = FileViewerModel()

  private let fileURL: URL
  private lazy var viewerChrome = FileViewerTabChrome(model: model)
  private var hostingView: NSHostingView<FileViewerTabView>?

  init(id: ContentID, fileURL: URL) {
    self.id = id
    self.fileURL = fileURL
  }

  var chrome: (any TabChrome)? { viewerChrome }

  var renderer: NSView? { hostingView }

  /// An unsaved buffer is the one thing closing this tab would destroy; zmx
  /// has no equivalent here, so this is what arms the confirmation.
  var isBusy: Bool { model.isDirty }

  /// Discarded, not interrupted: there is no session to reattach to, so this
  /// confirms even for a user who turned close confirmation off.
  var closeDiscardsUnsavedWork: Bool { model.isDirty }

  /// A write that did not land leaves the buffer dirty — a denied permission, or
  /// the file having changed on disk since it was opened, which parks the save
  /// behind the viewer's own conflict banner. Reporting the buffer's real state
  /// rather than "I tried" is what keeps the close from proceeding anyway.
  func saveUnsavedWork() -> Bool {
    model.save()
    return !model.isDirty
  }

  /// The renderer is the whole content; nothing survives it to be killed.
  var hasKillableSession: Bool { false }

  /// Never, not "not yet": there is no session behind the renderer to survive a
  /// teardown, so a backgrounded viewer must not sit on a grace timer that
  /// re-arms on every window for the life of the app.
  var supportsHibernation: Bool { false }

  func startSession(at geometry: ContentGeometry) {
    guard hostingView == nil else { return }
    model.open(fileURL)
    let view = NSHostingView(rootView: FileViewerTabView(model: model))
    // The renderer is pinned to all four edges of its pane, so any intrinsic
    // size it reports climbs the constraint chain into `NSWindow.contentMinSize`
    // — a wide markdown or HTML document would leave the window unable to shrink
    // back. Clearing the sizing options makes the view take the pane's size
    // instead of demanding one; the content scrolls inside it.
    view.sizingOptions = []
    hostingView = view
  }

  // Nothing to hibernate: `isHibernatable` is false, so this is never reached
  // through the layout; the default conformance would be a silent no-op either
  // way, and dropping the renderer here would strand an unsaved buffer.
  func hibernate() {}

  func tearDown() {
    hostingView = nil
  }

  func snapshot() -> ContentSnapshot {
    ContentSnapshot(id: id, state: .fileViewer(FileViewerContentState(fileURL: fileURL)))
  }
}

/// Tab chrome for a viewer: an unsaved-changes dot, and the title shimmer while
/// a slow first render is still blocking. Stateless — every value reads through
/// the observable model, so the strip re-renders on a keystroke that dirties the
/// buffer without the content pushing anything.
@MainActor
final class FileViewerTabChrome: TabChrome {
  private let model: FileViewerModel

  init(model: FileViewerModel) {
    self.model = model
  }

  var accessory: AnyView? {
    guard model.isDirty else { return nil }
    return AnyView(FileViewerDirtyMarker())
  }

  var isWorking: Bool { model.isPreparingContent }

  var progress: TerminalTabProgressDisplay? { nil }

  /// Terminal-input state; a viewer has no pty to refuse input.
  var isReadOnly: Bool { false }
}

/// Matches the unsaved dot in the viewer's own header, so the tab and the pane
/// agree at a glance.
private struct FileViewerDirtyMarker: View, Equatable {
  var body: some View {
    Circle()
      .fill(.orange)
      .frame(width: 6, height: 6)
      .padding(.trailing, 2)
      .help("Unsaved changes")
  }
}
