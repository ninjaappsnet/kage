import AppKit
import SwiftUI

/// Paints the same `.sidebar` vibrancy macOS uses for the source-list column.
///
/// The workspace switcher is mounted via `.safeAreaInset(edge: .top)` over the
/// sidebar `List` so the list reserves space below it and the sticky highlight
/// section headers ("Active" / "Pinned") anchor *below* the switcher instead of
/// floating up under it. With `.safeAreaInset` the list rows scroll under the
/// switcher, so it needs a background — but `.bar` reads as a lighter strip than
/// the rows beside it. This effect view is the column's own material, so the
/// switcher blends seamlessly, and `.behindWindow` blending stays opaque to the
/// rows scrolling beneath.
struct SidebarMaterialBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .sidebar
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
    nsView.material = .sidebar
    nsView.blendingMode = .behindWindow
  }
}
