import MarkdownUI

/// Memoizes the chunked parse behind `MarkdownPreview`. Parsing and chunking a
/// multi-megabyte document costs a few hundred milliseconds, and SwiftUI re-runs
/// the preview's body for reasons unrelated to the text (color scheme, focus).
final class MarkdownPreviewChunks {
  /// Plain-text characters per lazily laid-out chunk. Small enough that a chunk
  /// lays out in tens of milliseconds, large enough to keep the row count low.
  static let maxCharacters = 8_000

  private var text: String?
  private var cached: [MarkdownChunk] = []
  private(set) var chunkingCount = 0

  nonisolated deinit {}

  func chunks(for text: String) -> [MarkdownChunk] {
    if text != self.text {
      cached = MarkdownContent(text).chunked(maxCharacters: Self.maxCharacters)
      self.text = text
      chunkingCount += 1
    }
    return cached
  }
}
