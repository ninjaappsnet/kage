import AppKit
import Highlightr
import MarkdownUI
import SwiftUI

/// Rendered markdown for the viewer's "Rendered" mode. Uses MarkdownUI with a
/// Highlightr-backed code-block highlighter so fenced code in the document is
/// syntax-colored to match the standalone code editor.
///
/// The document is laid out lazily in chunks (`MarkdownContent.chunked`, a Kage
/// patch to the vendored MarkdownUI): one `Markdown` view over a 2.9 MB file
/// spent ~15 s laying out every block before the first frame. The chunks carry
/// the margins of their joins, so the result looks the same as one view.
struct MarkdownPreview: View {
  let markdown: String
  @Environment(\.colorScheme) private var colorScheme
  @State private var chunks = MarkdownPreviewChunks()

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(Array(chunks.chunks(for: markdown).enumerated()), id: \.offset) { _, chunk in
          Markdown(chunk.content)
            .markdownChunkSpacing(chunk)
        }
      }
      .markdownCodeSyntaxHighlighter(.highlightr(dark: colorScheme == .dark))
      .textSelection(.enabled)
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// Adapts Highlightr to MarkdownUI's `CodeSyntaxHighlighter` so fenced code
/// blocks render with syntax colors.
struct HighlightrCodeSyntaxHighlighter: CodeSyntaxHighlighter {
  let dark: Bool

  // Satisfies MarkdownUI's nonisolated protocol requirement; the target defaults
  // to main-actor isolation, so the witness must opt out explicitly.
  nonisolated func highlightCode(_ code: String, language: String?) -> Text {
    guard let highlighted = CodeHighlighterStore.shared.attributed(code: code, language: language, dark: dark) else {
      return Text(code)
    }
    return Text(AttributedString(highlighted))
  }
}

extension CodeSyntaxHighlighter where Self == HighlightrCodeSyntaxHighlighter {
  static func highlightr(dark: Bool) -> Self { HighlightrCodeSyntaxHighlighter(dark: dark) }
}

/// Process-wide Highlightr instance for one-off `highlight` calls (markdown code
/// blocks). Highlightr loads a JS context on init, so it is created once and
/// reused. Only ever touched on the main thread during SwiftUI rendering, hence
/// `nonisolated`/`nonisolated(unsafe)`.
nonisolated final class CodeHighlighterStore {
  nonisolated(unsafe) static let shared = CodeHighlighterStore()

  private let highlightr = Highlightr()
  private let lock = NSLock()
  private var currentDark: Bool?

  private init() {}

  func attributed(code: String, language: String?, dark: Bool) -> NSAttributedString? {
    guard let highlightr else { return nil }
    // Highlightr renders during SwiftUI body (main thread) in practice, but a lock
    // keeps the theme switch + highlight atomic and removes any data race on the
    // shared instance regardless of caller thread.
    lock.lock()
    defer { lock.unlock() }
    if currentDark != dark {
      _ = highlightr.setTheme(to: dark ? "xcode-dark" : "xcode")
      highlightr.theme.setCodeFont(.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
      currentDark = dark
    }
    return highlightr.highlight(code, as: language, fastRender: true)
  }
}
