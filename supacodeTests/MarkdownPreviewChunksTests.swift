import MarkdownUI
import Testing

@testable import supacode

@MainActor
struct MarkdownPreviewChunksTests {
  @Test func reusesTheChunksWhileTheTextIsUnchanged() {
    let cache = MarkdownPreviewChunks()

    let first = cache.chunks(for: "# Title\n\nBody.\n")
    #expect(first.map(\.content) == [MarkdownContent("# Title\n\nBody.")])
    #expect(cache.chunkingCount == 1)

    _ = cache.chunks(for: "# Title\n\nBody.\n")
    #expect(cache.chunkingCount == 1)
  }

  @Test func rechunksWhenTheTextChanges() {
    let cache = MarkdownPreviewChunks()
    _ = cache.chunks(for: "One.")

    let second = cache.chunks(for: "Two.")

    #expect(second.map(\.content) == [MarkdownContent("Two.")])
    #expect(cache.chunkingCount == 2)
  }
}
