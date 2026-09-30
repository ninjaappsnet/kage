import Foundation
import SwiftUI
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Covers the pure hex / HSB surface the in-app custom color picker is built on.
/// The picker replaced SwiftUI's `ColorPicker`, whose shared `NSColorPanel`
/// singleton drove an AppKit layout loop, so this math must stand on its own
/// without AppKit's panel or color-space conversions.
@MainActor
struct RepositoryColorCustomPickerTests {
  // MARK: - Typed hex input.

  @Test func hexInputAcceptsMissingHashAndSurroundingWhitespace() {
    #expect(RepositoryColor.custom(fromHexInput: "a1b2c3") == .custom("#A1B2C3"))
    #expect(RepositoryColor.custom(fromHexInput: "  #a1b2c3\n") == .custom("#A1B2C3"))
  }

  @Test func hexInputExpandsThreeDigitShorthand() {
    #expect(RepositoryColor.custom(fromHexInput: "abc") == .custom("#AABBCC"))
    #expect(RepositoryColor.custom(fromHexInput: "#0f8") == .custom("#00FF88"))
  }

  @Test func hexInputKeepsEightDigitAlpha() {
    #expect(RepositoryColor.custom(fromHexInput: "#a1b2c380") == .custom("#A1B2C380"))
  }

  @Test func hexInputRejectsMalformedValues() {
    #expect(RepositoryColor.custom(fromHexInput: "") == nil)
    #expect(RepositoryColor.custom(fromHexInput: "   ") == nil)
    #expect(RepositoryColor.custom(fromHexInput: "red") == nil)
    #expect(RepositoryColor.custom(fromHexInput: "#12345") == nil)
    #expect(RepositoryColor.custom(fromHexInput: "#GGGGGG") == nil)
  }

  // MARK: - HSB → hex.

  @Test(
    arguments: [
      (RepositoryColor.HSB(hue: 0, saturation: 1, brightness: 1), "#FF0000"),
      (.init(hue: 1.0 / 3.0, saturation: 1, brightness: 1), "#00FF00"),
      (.init(hue: 2.0 / 3.0, saturation: 1, brightness: 1), "#0000FF"),
      (.init(hue: 0, saturation: 0, brightness: 1), "#FFFFFF"),
      (.init(hue: 0.5, saturation: 1, brightness: 0), "#000000"),
    ]
  )
  func customFromHSBProducesExpectedHex(hsb: RepositoryColor.HSB, hex: String) {
    #expect(RepositoryColor.custom(hsb) == .custom(hex))
  }

  @Test func customFromHSBClampsOutOfRangeComponents() {
    let clamped = RepositoryColor.custom(.init(hue: 1.4, saturation: -0.2, brightness: 2))
    #expect(clamped == .custom("#FFFFFF"))
  }

  @Test func hsbClampingKeepsKnobComponentsIndependent() {
    // The picker drives knob positions off the clamped HSB, never off a
    // round trip through hex: at brightness 0 the hex is #000000, whose hue and
    // saturation are both 0, so a round trip would teleport the knobs.
    let dark = RepositoryColor.HSB(hue: 0.75, saturation: 0.6, brightness: 0).clamped
    #expect(abs(dark.hue - 0.75) < 0.001)
    #expect(abs(dark.saturation - 0.6) < 0.001)
    #expect(dark.brightness == 0)
  }

  @Test func hsbClampingPinsOutOfRangeComponents() {
    let clamped = RepositoryColor.HSB(hue: 1.4, saturation: -0.2, brightness: 2).clamped
    #expect(clamped == .init(hue: 1, saturation: 0, brightness: 1))
  }

  // MARK: - Hex → HSB.

  @Test func hsbReadsPrimaryHues() {
    let red = RepositoryColor.custom("#FF0000").hsb
    #expect(abs(red.hue - 0) < 0.001)
    #expect(abs(red.saturation - 1) < 0.001)
    #expect(abs(red.brightness - 1) < 0.001)

    let green = RepositoryColor.custom("#00FF00").hsb
    #expect(abs(green.hue - 1.0 / 3.0) < 0.001)

    let blue = RepositoryColor.custom("#0000FF").hsb
    #expect(abs(blue.hue - 2.0 / 3.0) < 0.001)
  }

  @Test func hsbReadsAchromaticValues() {
    let white = RepositoryColor.custom("#FFFFFF").hsb
    #expect(abs(white.saturation - 0) < 0.001)
    #expect(abs(white.brightness - 1) < 0.001)

    let black = RepositoryColor.custom("#000000").hsb
    #expect(abs(black.brightness - 0) < 0.001)

    let gray = RepositoryColor.custom("#808080").hsb
    #expect(abs(gray.saturation - 0) < 0.001)
    #expect(abs(gray.brightness - 128.0 / 255.0) < 0.001)
  }

  @Test(arguments: ["#A1B2C3", "#123456", "#FEDCBA", "#00FF88", "#7F007F"])
  func hsbRoundTripsThroughHex(hex: String) {
    let hsb = RepositoryColor.custom(hex).hsb
    #expect(RepositoryColor.custom(hsb) == .custom(hex))
  }

  @Test func hsbFallsBackForMalformedCustomHex() {
    // A malformed stored value still has to seed the picker with something usable.
    let hsb = RepositoryColor.custom("#nope").hsb
    #expect(hsb.hue >= 0 && hsb.hue <= 1)
    #expect(hsb.saturation >= 0 && hsb.saturation <= 1)
    #expect(hsb.brightness >= 0 && hsb.brightness <= 1)
  }

  // MARK: - Resolved hex.

  @Test func resolvedHexEchoesCustomValue() {
    #expect(RepositoryColor.custom("#A1B2C3").resolvedHex == "#A1B2C3")
  }

  @Test(arguments: RepositoryColor.predefined)
  func resolvedHexOfPredefinedParsesBack(color: RepositoryColor) {
    let hex = color.resolvedHex
    #expect(hex.hasPrefix("#"))
    #expect(RepositoryColor.parse(hex) != nil)
  }

  /// `custom(from: Color)` is still the intent-capture path when a SwiftUI
  /// `Color` (rather than typed hex or picker HSB) is the input.
  @Test func customFromSwiftUIColorCapturesHex() {
    #expect(RepositoryColor.custom(from: .white) == .custom("#FFFFFF"))
    #expect(RepositoryColor.custom(from: .black) == .custom("#000000"))
  }
}
