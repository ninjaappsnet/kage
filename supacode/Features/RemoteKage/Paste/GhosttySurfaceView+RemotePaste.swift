import AppKit
import GhosttyKit

/// The surface side of remote pastes: which key chord is offered to
/// `pasteInterceptor`, and how the uploaded paths go back in.
extension GhosttySurfaceView {
  /// Cmd+V exactly, outside a key sequence or key table (where the chord may
  /// mean something else). Edit → Paste and drops are offered unconditionally.
  func offersPasteToInterceptor(_ event: NSEvent) -> Bool {
    Self.offersPasteToInterceptor(event) && bridge.state.keySequenceActive != true && bridge.state.keyTableDepth == 0
  }

  static func offersPasteToInterceptor(_ event: NSEvent) -> Bool {
    let shortcutMask: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    return event.type == .keyDown && event.charactersIgnoringModifiers?.lowercased() == "v"
      && event.modifierFlags.intersection(shortcutMask) == [.command]
  }

  /// Sends `text` to the terminal as a paste (bracketed when the program
  /// asked for it), as a drop does. Unlike `insertText` it works with no
  /// current event, since an upload finishes long after the key press.
  func sendPastedText(_ text: String) {
    guard let surface, !text.isEmpty else { return }
    let length = text.utf8CString.count
    text.withCString { pointer in
      ghostty_surface_text(surface, pointer, UInt(length - 1))
    }
  }
}
