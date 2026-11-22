import AppKit
import MarkdownUI
import SwiftUI
import Testing

@testable import supacode

/// Splitting a document into chunks must not move anything: stacked with
/// `markdownChunkSpacing`, the chunks are exactly as tall as MarkdownUI's own
/// layout of the whole document, so every join reproduces the margin the
/// basic theme would have collapsed there.
@MainActor
struct MarkdownPreviewChunkParityTests {
  /// MarkdownUI learns each block's margins from a preference written back
  /// into `@State`, so its first layout pass uses default padding and the
  /// theme's margins land one update later. Measure once that has settled.
  private static func height(_ view: some View) -> CGFloat {
    let host = NSHostingView(rootView: view.frame(width: 600, alignment: .leading))
    host.frame = NSRect(x: 0, y: 0, width: 600, height: 2_000)
    var height: CGFloat = -1
    for _ in 0..<10 {
      host.layoutSubtreeIfNeeded()
      _ = RunLoop.main.run(mode: .default, before: .now)
      let settled = host.fittingSize.height
      if settled == height { break }
      height = settled
    }
    return height
  }

  @Test(arguments: [
    "# Title\n\nFirst paragraph.\n\nSecond paragraph.\n\n## Section\n\nText after a heading.\n",
    "Intro.\n\n- tight one\n- tight two\n- tight three\n\nAfter the list.\n",
    "- loose one\n\n- loose two\n\n- loose three\n\n### Heading after a list\n",
    "1. first\n2. second\n3. third\n4. fourth\n",
    "> A quoted paragraph.\n\nAfter the quote.\n\n---\n\nAfter the rule.\n",
    "| a | b |\n| - | - |\n| 1 | 2 |\n\n```swift\nlet x = 1\n```\n\nTail **bold** `code`.\n",
  ])
  func chunkedLayoutIsAsTallAsTheWholeDocument(markdown: String) {
    let content = MarkdownContent(markdown)
    let chunks = content.chunked(maxCharacters: 1)
    #expect(chunks.count > 1)

    let whole = Self.height(Markdown(content))
    let stacked = Self.height(
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
          Markdown(chunk.content).markdownChunkSpacing(chunk)
        }
      }
    )

    #expect(abs(whole - stacked) < 1, "whole \(whole) vs chunked \(stacked)")
  }

  /// The preview lays out only what is on screen, so a document several
  /// megabytes long opens in well under a second instead of the ~15 s the
  /// eager layout took on dayfolio's 2.9 MB plan.md. The bound is loose on
  /// purpose: it separates lazy from eager, not fast from slightly faster.
  @Test func largeDocumentLaysOutQuickly() {
    let section = (0..<40).map { "- item \($0) with `code` and **bold** text that wraps a little" }
      .joined(separator: "\n")
    let markdown = (0..<500).map { "## Section \($0)\n\n\(section)\n" }.joined(separator: "\n")
    #expect(markdown.utf8.count > 1_000_000)

    let start = ContinuousClock.now
    let controller = NSHostingController(rootView: MarkdownPreview(markdown: markdown))
    controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
    controller.view.layoutSubtreeIfNeeded()
    let elapsed = ContinuousClock.now - start

    #expect(elapsed < .seconds(3), "laid out in \(elapsed)")
  }
}
