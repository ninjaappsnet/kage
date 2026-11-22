import Foundation
import MarkdownUI
import Testing

/// The rendered preview lays a document out lazily, one chunk at a time, so
/// chunks must split only where MarkdownUI would place blocks apart anyway, and
/// must say how far apart: the margin MarkdownUI's basic theme collapses at
/// that join.
struct MarkdownChunkingTests {
  @Test func documentUnderTheLimitStaysOneChunk() {
    let content = MarkdownContent("# Title\n\nSome text.\n\n- a\n- b\n")
    let chunks = content.chunked(maxCharacters: 10_000)

    #expect(chunks.map(\.content) == [content])
    #expect(chunks[0].leadingMargins.isEmpty)
  }

  @Test func splitsBetweenTopLevelBlocks() {
    let chunks = MarkdownContent("# Title\n\nFirst paragraph.\n\nSecond paragraph.\n").chunked(maxCharacters: 1)

    #expect(
      chunks.map(\.content) == [
        MarkdownContent("# Title"),
        MarkdownContent("First paragraph."),
        MarkdownContent("Second paragraph."),
      ]
    )
    #expect(chunks[0].leadingMargins.isEmpty)
    #expect(chunks[1].leadingMargins == [.rem(1)])
    #expect(chunks[2].leadingMargins == [.em(1)])
  }

  @Test func headingKeepsItsTopMarginAtAJoin() {
    let chunks = MarkdownContent("Paragraph.\n\n## Heading\n").chunked(maxCharacters: 1)

    #expect(chunks[1].leadingMargins == [.em(1), .rem(1.5)])
  }

  @Test func groupsSmallBlocksUpToTheLimit() {
    let chunks = MarkdownContent("aaaa\n\nbbbb\n\ncccc\n").chunked(maxCharacters: 8)

    #expect(chunks.map(\.content) == [MarkdownContent("aaaa\n\nbbbb"), MarkdownContent("cccc")])
  }

  @Test func splitsALongNumberedListBetweenItemsAndKeepsItsNumbering() {
    let chunks = MarkdownContent("1. one\n2. two\n3. three\n").chunked(maxCharacters: 1)

    #expect(
      chunks.map(\.content) == [
        MarkdownContent("1. one"),
        MarkdownContent("2. two"),
        MarkdownContent("3. three"),
      ]
    )
    // A tight list's items sit flush against each other.
    #expect(chunks[1].leadingMargins.isEmpty)
  }

  @Test func looseListItemsKeepTheirParagraphGap() {
    let chunks = MarkdownContent("- a\n\n- b\n").chunked(maxCharacters: 1)

    #expect(chunks.count == 2)
    #expect(chunks[1].leadingMargins == [.em(1)])
  }

  @Test func blockLargerThanTheLimitIsKeptWhole() {
    let paragraph = String(repeating: "word ", count: 100)
    let chunks = MarkdownContent(paragraph).chunked(maxCharacters: 10)

    #expect(chunks.map(\.content) == [MarkdownContent(paragraph)])
  }
}
