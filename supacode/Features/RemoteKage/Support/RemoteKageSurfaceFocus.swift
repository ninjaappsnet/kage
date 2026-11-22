import AppKit

/// When an attached remote terminal takes keyboard focus. The first show
/// takes it (the user just opened or attached the tab) unless someone is
/// typing into a text input; a later re-show (SwiftUI re-parenting the view)
/// only reclaims it from nobody or from another terminal, never from a
/// control the user moved to.
enum RemoteKageSurfaceFocus {
  nonisolated enum Owner: Equatable, Sendable, CaseIterable {
    /// No first responder at all.
    case none
    /// AppKit parked focus on the window itself (previous owner left).
    case window
    case terminal
    /// A text field's field editor or any text view.
    case textInput
    case other
  }

  static func owner(of responder: NSResponder?, in window: NSWindow) -> Owner {
    guard let responder else { return .none }
    if responder === window { return .window }
    if responder is GhosttySurfaceView { return .terminal }
    if responder is NSText { return .textInput }
    return .other
  }

  nonisolated static func shouldClaim(firstShow: Bool, currentOwner: Owner) -> Bool {
    switch currentOwner {
    case .none, .window, .terminal: true
    case .other: firstShow
    case .textInput: false
    }
  }
}
