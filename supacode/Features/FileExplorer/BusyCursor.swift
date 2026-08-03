import AppKit
import SwiftUI

/// Swaps the pointer for an hourglass while a view reports itself busy.
///
/// AppKit ships no public "busy but responsive" cursor — the spinning beachball
/// is drawn by the window server only once an app stops answering events, which
/// is both too late and not something an app can ask for. So the cursor is built
/// from an SF Symbol and pushed onto the cursor stack.
///
/// The push has to happen *before* the main thread blocks: a cursor set during a
/// block never reaches the screen, whereas one set in the frame before stays up
/// for the whole stall.
struct BusyCursorModifier: ViewModifier {
  let isBusy: Bool

  @State private var isPushed = false

  func body(content: Content) -> some View {
    content
      .onChange(of: isBusy) { _, busy in
        apply(busy)
      }
      .onDisappear { apply(false) }
  }

  /// Push/pop kept balanced by `isPushed`: `NSCursor` keeps a stack, and an
  /// unmatched pop would yank whatever cursor another view pushed.
  private func apply(_ busy: Bool) {
    guard busy != isPushed else { return }
    if busy {
      Self.hourglass.push()
    } else {
      NSCursor.pop()
    }
    isPushed = busy
  }

  private static let hourglass: NSCursor = {
    let configuration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
    guard
      let symbol = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Busy")?
        .withSymbolConfiguration(configuration)
    else {
      return .arrow
    }
    // Drawn onto an opaque-backed image: a bare symbol is a thin glyph that
    // disappears over dark content, and cursors get no system backdrop.
    let padded = NSImage(size: NSSize(width: 28, height: 28), flipped: false) { rect in
      NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
      NSBezierPath(ovalIn: rect).fill()
      let symbolRect = NSRect(x: 4, y: 4, width: 20, height: 20)
      symbol.draw(in: symbolRect)
      return true
    }
    return NSCursor(image: padded, hotSpot: NSPoint(x: 14, y: 14))
  }()
}

extension View {
  /// Shows an hourglass pointer while `isBusy`, for work that blocks the main
  /// thread long enough that a click otherwise looks ignored.
  func busyCursor(_ isBusy: Bool) -> some View {
    modifier(BusyCursorModifier(isBusy: isBusy))
  }
}
