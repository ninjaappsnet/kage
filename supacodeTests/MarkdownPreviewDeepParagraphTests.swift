import AppKit
import SwiftUI
import Testing

@testable import supacode

/// MarkdownUI renders a paragraph's inlines by chaining one `Text` per inline
/// node with `+`. SwiftUI resolves that chain recursively, so a paragraph with a
/// few thousand inline nodes (a long decisions log written as one paragraph,
/// thick with `code` spans and **bold**) overflowed the main thread's stack the
/// first time the preview laid out, and took the whole app down.
@MainActor
struct MarkdownPreviewDeepParagraphTests {
  /// One paragraph, soft-wrapped over many lines, with code, strong and
  /// emphasis spans on every line: well over 20,000 top-level inline nodes.
  private static let deepParagraph: String = (0..<3_000)
    .map { "D\($0) uses `token\($0)` with **bold** and *emph* text" }
    .joined(separator: "\n")

  @Test func paragraphWithThousandsOfInlinesRendersWithoutOverflowingTheStack() {
    let controller = NSHostingController(rootView: MarkdownPreview(markdown: "# Log\n\n\(Self.deepParagraph)\n"))
    controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    controller.view.layoutSubtreeIfNeeded()

    #expect(controller.sizeThatFits(in: CGSize(width: 800, height: CGFloat.infinity)).height > 600)
  }
}
