import AppKit

/// Existence-guarded access to `NSColorPanel.shared`.
///
/// `NSColorPanel.shared` is a lazily created, process-lifetime singleton, and
/// every access — including a harmless-looking `isRestorable = false` or
/// `orderOut(nil)` — creates it. That matters because once the panel exists,
/// `-[NSTextView updateFontPanel]` pushes the typing attributes' color into it
/// on every selection change, and the panel's KVO bindings answer by dirtying
/// layout. When the text view is the `NSTextField` behind a SwiftUI
/// `.textSelection(.enabled)` overlay updating mid-layout, that re-entrant
/// `setNeedsLayout` raises from `-[NSWindow _postWindowNeedsLayout]` and takes
/// the app down (see `RepositoryColor+CustomPicker.swift`).
///
/// Kage therefore never creates the panel: the custom color picker is
/// hand-rolled, and these helpers only act on a panel AppKit already made (the
/// system can still open one, e.g. via a text view's Font menu).
public enum SystemColorPanel {
  /// `true` only when AppKit has already created the shared panel.
  public static var exists: Bool { NSColorPanel.sharedColorPanelExists }

  /// Hides an already-open panel; a no-op when none exists.
  public static func closeIfOpen() {
    guard exists else { return }
    NSColorPanel.shared.orderOut(nil)
  }

  /// Opts an already-open panel out of window restoration, so its visibility
  /// isn't written into the app's restoration archive and replayed on the next
  /// launch independently of the main window. A no-op when none exists.
  public static func disableRestorationIfOpen() {
    guard exists else { return }
    NSColorPanel.shared.isRestorable = false
  }
}
