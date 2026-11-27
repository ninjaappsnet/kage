import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import supacode

@MainActor
struct GhosttySurfacePasteInterceptorTests {
  private func makeSurfaceView() -> GhosttySurfaceView {
    GhosttySurfaceView(
      id: UUID(),
      runtime: GhosttyRuntime(),
      workingDirectory: nil,
      initialGeometry: .fallback,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
  }

  @Test func editPasteOffersTheGeneralPasteboardToTheInterceptor() {
    let view = makeSurfaceView()
    defer { view.closeSurface() }
    var offered: [NSPasteboard] = []
    view.pasteInterceptor = { pasteboard in
      offered.append(pasteboard)
      return true
    }
    view.paste(nil)
    #expect(offered.count == 1)
    #expect(offered.first === NSPasteboard.general)
  }

  @Test func surfacesWithoutAnInterceptorPasteAsBefore() {
    let view = makeSurfaceView()
    defer { view.closeSurface() }
    #expect(view.pasteInterceptor == nil)
    view.paste(nil)
  }

  @Test func onlyAnExactCommandVIsOfferedFromTheKeyboard() throws {
    func event(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
      try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
          characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 9))
    }
    #expect(GhosttySurfaceView.offersPasteToInterceptor(try event("v", .command)))
    #expect(!GhosttySurfaceView.offersPasteToInterceptor(try event("v", [.command, .shift])))
    #expect(!GhosttySurfaceView.offersPasteToInterceptor(try event("v", .control)))
    #expect(!GhosttySurfaceView.offersPasteToInterceptor(try event("c", .command)))
  }
}
