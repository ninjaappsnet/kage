import SwiftUI

extension Sequence where Element == InlineNode {
  func renderText(
    baseURL: URL?,
    textStyles: InlineTextStyles,
    images: [String: Image],
    softBreakMode: SoftBreak.Mode,
    attributes: AttributeContainer
  ) -> Text {
    var renderer = TextInlineRenderer(
      baseURL: baseURL,
      textStyles: textStyles,
      images: images,
      softBreakMode: softBreakMode,
      attributes: attributes
    )
    renderer.render(self)
    return renderer.finish()
  }
}

// KAGE PATCH (see KAGE-PATCHES.md): upstream appended one `Text` per inline node
// with `+`, a left-deep concatenation chain as long as the paragraph. SwiftUI
// resolves that chain recursively, so a paragraph with a few thousand inlines
// overflowed the main thread's stack on first layout. Consecutive non-image
// inlines now accumulate into one AttributedString, only an inline image splits
// it, and the segments are joined as a balanced tree.
private struct TextInlineRenderer {
  private var segments: [Text] = []
  private var pending = AttributedString()

  private let baseURL: URL?
  private let textStyles: InlineTextStyles
  private let images: [String: Image]
  private let softBreakMode: SoftBreak.Mode
  private let attributes: AttributeContainer
  private var shouldSkipNextWhitespace = false

  init(
    baseURL: URL?,
    textStyles: InlineTextStyles,
    images: [String: Image],
    softBreakMode: SoftBreak.Mode,
    attributes: AttributeContainer
  ) {
    self.baseURL = baseURL
    self.textStyles = textStyles
    self.images = images
    self.softBreakMode = softBreakMode
    self.attributes = attributes
  }

  mutating func render<S: Sequence>(_ inlines: S) where S.Element == InlineNode {
    for inline in inlines {
      self.render(inline)
    }
  }

  mutating func finish() -> Text {
    self.flushPending()
    return Self.joined(self.segments[...])
  }

  private mutating func render(_ inline: InlineNode) {
    switch inline {
    case .text(let content):
      self.renderText(content)
    case .softBreak:
      self.renderSoftBreak()
    case .html(let content):
      self.renderHTML(content)
    case .image(let source, _):
      self.renderImage(source)
    default:
      self.defaultRender(inline)
    }
  }

  private mutating func renderText(_ text: String) {
    var text = text

    if self.shouldSkipNextWhitespace {
      self.shouldSkipNextWhitespace = false
      text = text.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
    }

    self.defaultRender(.text(text))
  }

  private mutating func renderSoftBreak() {
    switch self.softBreakMode {
    case .space where self.shouldSkipNextWhitespace:
      self.shouldSkipNextWhitespace = false
    case .space:
      self.defaultRender(.softBreak)
    case .lineBreak:
      self.shouldSkipNextWhitespace = true
      self.defaultRender(.lineBreak)
    }
  }

  private mutating func renderHTML(_ html: String) {
    let tag = HTMLTag(html)

    switch tag?.name.lowercased() {
    case "br":
      self.defaultRender(.lineBreak)
      self.shouldSkipNextWhitespace = true
    default:
      self.defaultRender(.html(html))
    }
  }

  private mutating func renderImage(_ source: String) {
    if let image = self.images[source] {
      self.flushPending()
      self.segments.append(Text(image))
    }
  }

  private mutating func defaultRender(_ inline: InlineNode) {
    self.pending.append(
      inline.renderAttributedString(
        baseURL: self.baseURL,
        textStyles: self.textStyles,
        softBreakMode: self.softBreakMode,
        attributes: self.attributes
      )
    )
  }

  private mutating func flushPending() {
    guard !self.pending.characters.isEmpty else { return }
    self.segments.append(Text(self.pending))
    self.pending = AttributedString()
  }

  /// Joins `texts` with `+` as a balanced tree, so the concatenation depth is
  /// logarithmic in the segment count instead of linear.
  private static func joined(_ texts: ArraySlice<Text>) -> Text {
    switch texts.count {
    case 0:
      return Text("")
    case 1:
      return texts[texts.startIndex]
    default:
      let middle = texts.startIndex + texts.count / 2
      return Self.joined(texts[..<middle]) + Self.joined(texts[middle...])
    }
  }
}
