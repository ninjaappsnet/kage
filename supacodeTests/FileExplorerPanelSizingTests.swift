import AppKit
import SwiftUI
import Testing

@testable import supacode

/// Whatever minimum width the explorer and the viewer advertise ends up in the
/// window's own minimum — the explorer because it docks as a safe-area inset,
/// the viewer because its hosting view is pinned to all four edges of its pane.
/// A renderer that refuses to shrink therefore pushes `NSWindow.contentMinSize`
/// out and leaves the window unable to shrink back. Both must render at their
/// natural width while advertising a minimum the window can shrink past.
@MainActor
struct FileExplorerPanelSizingTests {
  /// Width the hosted layout demands under a zero-size proposal — the same probe
  /// AppKit runs to derive `NSWindow.contentMinSize`. `NSHostingView.fittingSize`
  /// answers the *ideal* size instead, which stays at the natural width in
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

  /// The renderer the layout actually mounts, pinned to its pane on all four
  /// edges — so this is the view whose intrinsic size would reach the window.
  private static func mountedViewerRenderer(for file: URL) -> NSView? {
    let content = FileViewerContent(id: ContentID(rawValue: UUID()), fileURL: file)
    content.startSession(at: .fallback)
    return content.renderer
  }

  /// Each viewer content path wraps a different renderer — a non-wrapping
  /// `NSTextView`, MarkdownUI, a `WKWebView`, an `NSImage` at natural size — and
  /// any one of them that refuses to shrink drags the pane's minimum back up.
  /// Asserting on `noIntrinsicMetric` rather than a width threshold states the
  /// real invariant: the viewer takes whatever size its pane has and never asks
  /// for one, whatever a future SwiftUI decides a document measures at.
  @Test(arguments: [
    ("notes.txt", "hello"),
    ("long-lines.swift", String(repeating: "let averyLongIdentifierName = 1  // padding\n", count: 40)),
    ("wide-single-line.txt", String(repeating: "x", count: 4000)),
    ("readme.md", "# Title\n\n\(String(repeating: "word ", count: 400))\n\n```swift\nlet x = 1\n```\n"),
    ("report.html", "<html><body><h1>\(String(repeating: "wide ", count: 400))</h1></body></html>"),
  ])
  func viewerContentDoesNotImposeAWindowMinimum(name: String, contents: String) throws {
    let directory = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent(name)
    try contents.write(to: file, atomically: true, encoding: .utf8)

    let renderer = try #require(Self.mountedViewerRenderer(for: file))

    #expect(
      renderer.intrinsicContentSize.width == NSView.noIntrinsicMetric,
      "viewer for \(name) demanded a width of \(renderer.intrinsicContentSize.width)"
    )
    #expect(
      renderer.intrinsicContentSize.height == NSView.noIntrinsicMetric,
      "viewer for \(name) demanded a height of \(renderer.intrinsicContentSize.height)"
    )
  }

  /// The pane container pins all four edges; a renderer that resisted would
  /// fight those constraints instead of filling.
  @Test func viewerRendererFillsItsPaneRatherThanResisting() throws {
    let directory = try Self.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("readme.md")
    try "# Title\n\n\(String(repeating: "word ", count: 400))".write(to: file, atomically: true, encoding: .utf8)

    let renderer = try #require(Self.mountedViewerRenderer(for: file))
    let container = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    renderer.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(renderer)
    NSLayoutConstraint.activate([
      renderer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      renderer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      renderer.topAnchor.constraint(equalTo: container.topAnchor),
      renderer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    container.layoutSubtreeIfNeeded()

    #expect(renderer.frame.width == 320, "viewer settled at \(renderer.frame.width) in a 320pt pane")
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
