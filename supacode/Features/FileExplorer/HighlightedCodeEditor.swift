import AppKit
import Highlightr
import SwiftUI

/// An editable code view. When `highlightSyntax` is on it wraps an `NSTextView`
/// backed by Highlightr's `CodeAttributedString`, which re-highlights as the user
/// types; for large files it falls back to a plain monospaced `NSTextStorage` to
/// avoid per-keystroke jank. `NSTextView` (not SwiftUI `TextEditor`) for
/// monospaced rendering, native find/undo, horizontal scrolling, and large-file
/// performance — mirroring `PlainTextEditor`.
struct HighlightedCodeEditor: NSViewRepresentable {
  @Binding var text: String
  /// highlight.js language id, or `nil` to let Highlightr auto-detect.
  let language: String?
  /// When false (large files), the text is shown plain without syntax coloring.
  var highlightSyntax: Bool = true

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  func makeNSView(context: Context) -> NSScrollView {
    let textContainer = NSTextContainer()
    textContainer.widthTracksTextView = false
    textContainer.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    let layoutManager = NSLayoutManager()
    layoutManager.addTextContainer(textContainer)

    let textStorage: NSTextStorage = highlightSyntax ? CodeAttributedString() : NSTextStorage()
    textStorage.addLayoutManager(layoutManager)
    if let codeStorage = textStorage as? CodeAttributedString {
      codeStorage.language = language
    }

    let textView = NSTextView(frame: .zero, textContainer: textContainer)
    textView.delegate = context.coordinator
    textView.isEditable = true
    textView.isSelectable = true
    textView.allowsUndo = true
    textView.isRichText = false
    textView.importsGraphics = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.usesFindBar = true
    textView.textContainerInset = NSSize(width: 6, height: 8)
    // Non-wrapping + horizontal scroll, standard for a code editor.
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = true
    textView.autoresizingMask = [.width, .height]
    textView.string = text

    let scrollView = NSScrollView()
    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder

    applyTheme(for: context.environment.colorScheme, textView: textView, scrollView: scrollView)
    context.coordinator.themeIsDark = context.environment.colorScheme == .dark

    // Focus the editor when a file opens (the panel ids this view per file, so
    // makeNSView runs once per opened file).
    DispatchQueue.main.async { [weak textView] in
      guard let textView else { return }
      textView.window?.makeFirstResponder(textView)
    }
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView else { return }
    context.coordinator.text = $text

    if let codeStorage = textView.textStorage as? CodeAttributedString, codeStorage.language != language {
      codeStorage.language = language
    }
    let isDark = context.environment.colorScheme == .dark
    if context.coordinator.themeIsDark != isDark {
      applyTheme(for: context.environment.colorScheme, textView: textView, scrollView: scrollView)
      context.coordinator.themeIsDark = isDark
    }
    // Only push external changes (file reloaded); user typing flows the other way
    // via the delegate, so guarding on inequality avoids clobbering the cursor.
    if textView.string != text {
      textView.string = text
    }
  }

  private func applyTheme(for scheme: ColorScheme, textView: NSTextView, scrollView: NSScrollView) {
    let background: NSColor
    if let codeStorage = textView.textStorage as? CodeAttributedString {
      _ = codeStorage.highlightr.setTheme(to: scheme == .dark ? "xcode-dark" : "xcode")
      codeStorage.highlightr.theme.setCodeFont(Self.font)
      background = codeStorage.highlightr.theme.themeBackgroundColor ?? .textBackgroundColor
    } else {
      textView.font = Self.font
      textView.textColor = .textColor
      background = .textBackgroundColor
    }
    textView.backgroundColor = background
    textView.drawsBackground = true
    textView.insertionPointColor = scheme == .dark ? .white : .black
    scrollView.drawsBackground = true
    scrollView.backgroundColor = background
  }

  private static var font: NSFont {
    .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var text: Binding<String>
    var themeIsDark: Bool?

    nonisolated deinit {}

    init(text: Binding<String>) { self.text = text }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      text.wrappedValue = textView.string
    }
  }
}
