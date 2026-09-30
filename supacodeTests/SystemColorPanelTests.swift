import AppKit
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// `NSColorPanel.shared` is a process-lifetime singleton, and merely touching it
/// creates it. Once it exists, every `NSTextView` typing-attribute change in the
/// process pushes color into it, whose KVO bindings dirty layout — which crashes
/// the app when it happens inside a SwiftUI layout pass (see
/// `RepositoryColor+CustomPicker.swift`). So the invariant is: nothing in Kage
/// may bring the panel into existence.
@MainActor
struct SystemColorPanelTests {
  @Test func nothingHasCreatedTheSharedColorPanel() {
    // The test host runs the app's launch path, so a launch-time
    // `NSColorPanel.shared` touch would already have failed this.
    #expect(SystemColorPanel.exists == false)
  }

  @Test func closingWhenAbsentDoesNotCreateThePanel() {
    SystemColorPanel.closeIfOpen()
    #expect(SystemColorPanel.exists == false)
  }

  @Test func disablingRestorationWhenAbsentDoesNotCreateThePanel() {
    SystemColorPanel.disableRestorationIfOpen()
    #expect(SystemColorPanel.exists == false)
  }
}
