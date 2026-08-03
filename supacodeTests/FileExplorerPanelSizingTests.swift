import AppKit
import SwiftUI
import Testing

@testable import supacode

/// The explorer and viewer dock as safe-area insets on the terminal, so whatever
/// minimum width they advertise is added to the window's own minimum. A rigid
/// `.frame(width:)` therefore pushes `NSWindow.contentMinSize` out by the full
/// pane width: opening a file grew the window and left it unable to shrink back.
/// The panes must render at their stored width while advertising a minimum the
/// window can shrink past.
@MainActor
struct FileExplorerPanelSizingTests {
  /// Width the hosted layout demands under a zero-size proposal — the same probe
  /// AppKit runs to derive `NSWindow.contentMinSize`. `NSHostingView.fittingSize`
  /// answers the *ideal* size instead, which stays at the pane's stored width in
  /// either case and so can't tell the bug from the fix.
  private static func hostedMinimumWidth(_ inset: some View, edge: HorizontalEdge) -> CGFloat {
    let controller = NSHostingController(
      rootView: Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: edge, spacing: 0) { inset }
    )
    controller.view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    controller.view.layoutSubtreeIfNeeded()
    return controller.sizeThatFits(in: CGSize(width: 0, height: 0)).width
  }

  private static func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("panel-sizing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func fileViewerPanelDoesNotImposeItsWidthAsAWindowMinimum() throws {
    let directory = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("notes.txt")
    try "hello".write(to: file, atomically: true, encoding: .utf8)

    let model = FileViewerModel()
    model.open(file)

    let width = Self.hostedMinimumWidth(
      FileViewerPanel(model: model, onClose: {}),
      edge: .trailing
    )
    #expect(width < 100, "viewer inset minimum width was \(width)")
  }

  @Test func fileExplorerPanelDoesNotImposeItsWidthAsAWindowMinimum() throws {
    let directory = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let width = Self.hostedMinimumWidth(
      FileExplorerPanel(rootURL: directory, onClose: {}),
      edge: .leading
    )
    #expect(width < 100, "explorer inset minimum width was \(width)")
  }
}
