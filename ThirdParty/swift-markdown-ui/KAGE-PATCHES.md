# Vendored swift-markdown-ui

A copy of [gonzalezreal/swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui)
2.4.1 (revision `5f613358148239d0292c0cef674a3c2314737f9e`), MIT licensed (see `LICENSE`),
used by the file viewer's rendered markdown mode (`supacode/Features/FileExplorer/MarkdownPreview.swift`).

It is vendored rather than pulled from GitHub because 2.4.1 is the last release (the library is
in maintenance mode) and Kage needs a fix in it. Only `Sources/MarkdownUI` and `LICENSE` are
kept; the DocC catalog, tests and snapshot-testing dependency are dropped. Every change from
upstream is marked `KAGE PATCH` in the source and listed here.

## Patches

1. **Deep paragraphs no longer overflow the stack** (`Sources/MarkdownUI/Renderer/TextInlineRenderer.swift`).
   Upstream appended one `Text` per inline node with `+`, building a left-deep concatenation chain
   as long as the paragraph. SwiftUI resolves that chain recursively
   (`ConcatenatedTextStorage.resolve`), so a paragraph with a few thousand inline nodes (a decisions
   log written as one long paragraph, dense with `code` and **bold**) crashed Kage on first layout
   with "Thread stack size exceeded due to excessive recursion". Consecutive non-image inlines now
   accumulate into one `AttributedString`; only an inline image splits it, and the segments are
   joined as a balanced tree. Covered by `supacodeTests/MarkdownPreviewDeepParagraphTests.swift`.

## Bumping

Re-copy `Sources/MarkdownUI` (minus `Documentation.docc`) from the new tag, re-apply each patch
above, and re-run `MarkdownPreviewDeepParagraphTests` plus a Release build with
`SUPACODE_MD_SMOKE=1` (see the `-Onone` note in `Tuist/Package.swift`).
