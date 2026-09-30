import AppKit
import Foundation

/// Hex / HSB surface for the in-app custom color picker.
///
/// The picker is hand-rolled rather than SwiftUI's `ColorPicker` because
/// `ColorPicker` instantiates `NSColorPanel.shared`, a process-wide singleton
/// that cannot be destroyed once created. While it exists, every
/// `NSTextView.setTypingAttributes` in the process pushes the color into the
/// panel (`updateFontPanel`), whose KVO bindings dirty layout — and when the
/// text view belongs to a SwiftUI `.textSelection(.enabled)` overlay updating
/// mid-layout, that re-entrant `setNeedsLayout` raises from
/// `-[NSWindow _postWindowNeedsLayout]` and kills the app.
///
/// Everything here is pure integer/floating math (no color-space conversion for
/// `.custom`), so the picker's round trips are exact and testable.
extension RepositoryColor {
  /// Hue / saturation / brightness in `0...1`, the picker's working model.
  public nonisolated struct HSB: Hashable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var brightness: Double

    public init(hue: Double, saturation: Double, brightness: Double) {
      self.hue = hue
      self.saturation = saturation
      self.brightness = brightness
    }

    /// Every component pinned to `0...1`, each independently. The picker keeps
    /// this — not a round trip through hex — as the knobs' source of truth, so a
    /// fully dark or fully desaturated color doesn't discard the hue the user set.
    public var clamped: HSB {
      HSB(
        hue: Swift.min(Swift.max(hue, 0), 1),
        saturation: Swift.min(Swift.max(saturation, 0), 1),
        brightness: Swift.min(Swift.max(brightness, 0), 1),
      )
    }
  }

  /// sRGB triple in `0...1` — the currency between hex, HSB and AppKit colors.
  fileprivate nonisolated struct RGBComponents: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
  }

  /// Lenient parse of a user-typed hex field: optional `#`, surrounding
  /// whitespace, and `RGB` shorthand are all accepted. Stricter than
  /// `parse(_:)` on the digits themselves — `parse` scans a prefix, so
  /// `#12345G` slips through there; typed input must be fully hexadecimal.
  public nonisolated static func custom(fromHexInput input: String) -> RepositoryColor? {
    var body = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix("#") { body.removeFirst() }
    if body.count == 3 {
      body = body.map { String(repeating: $0, count: 2) }.joined()
    }
    guard body.count == 6 || body.count == 8 else { return nil }
    guard body.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
    return .custom("#" + body.uppercased())
  }

  /// `.custom(hex)` from picker components; out-of-range values clamp, and
  /// `hue == 1` folds onto `hue == 0` so the hue slider's end stops match.
  public nonisolated static func custom(_ hsb: HSB) -> RepositoryColor {
    let clamped = hsb.clamped
    let hue = clamped.hue
    let saturation = clamped.saturation
    let brightness = clamped.brightness
    let sector = (hue == 1 ? 0 : hue) * 6
    let index = Int(sector.rounded(.down)) % 6
    let offset = sector - sector.rounded(.down)
    let low = brightness * (1 - saturation)
    let falling = brightness * (1 - saturation * offset)
    let rising = brightness * (1 - saturation * (1 - offset))
    let rgb: RGBComponents =
      switch index {
      case 0: .init(red: brightness, green: rising, blue: low)
      case 1: .init(red: falling, green: brightness, blue: low)
      case 2: .init(red: low, green: brightness, blue: rising)
      case 3: .init(red: low, green: falling, blue: brightness)
      case 4: .init(red: rising, green: low, blue: brightness)
      default: .init(red: brightness, green: low, blue: falling)
      }
    return .custom(hexString(rgb))
  }

  /// Picker seed for any color: parsed straight from the hex for `.custom`,
  /// resolved through the system palette for predefined cases.
  public nonisolated var hsb: HSB {
    let rgb = resolvedRGB
    let maxComponent = max(rgb.red, rgb.green, rgb.blue)
    let minComponent = min(rgb.red, rgb.green, rgb.blue)
    let delta = maxComponent - minComponent
    var hue = 0.0
    if delta > 0 {
      if maxComponent == rgb.red {
        hue = ((rgb.green - rgb.blue) / delta).truncatingRemainder(dividingBy: 6)
      } else if maxComponent == rgb.green {
        hue = (rgb.blue - rgb.red) / delta + 2
      } else {
        hue = (rgb.red - rgb.green) / delta + 4
      }
      hue /= 6
      if hue < 0 { hue += 1 }
    }
    return HSB(
      hue: hue,
      saturation: maxComponent == 0 ? 0 : delta / maxComponent,
      brightness: maxComponent,
    )
  }

  /// `#RRGGBB[AA]` for any case: the stored value for `.custom`, the resolved
  /// sRGB triple for predefined ones. Drives the picker's hex field.
  public nonisolated var resolvedHex: String {
    if case .custom(let hex) = self, Self.rgbComponents(fromHex: hex) != nil {
      return hex
    }
    return Self.hexString(resolvedRGB)
  }

  // MARK: - Resolution.

  /// sRGB components in `0...1`. Malformed custom hex falls back to mid gray so
  /// the picker still opens on something usable.
  private nonisolated var resolvedRGB: RGBComponents {
    if case .custom(let hex) = self, let parsed = Self.rgbComponents(fromHex: hex) {
      return parsed
    }
    guard let srgb = nsColor.usingColorSpace(.sRGB) else {
      return RGBComponents(red: 0.5, green: 0.5, blue: 0.5)
    }
    return RGBComponents(
      red: Double(srgb.redComponent),
      green: Double(srgb.greenComponent),
      blue: Double(srgb.blueComponent),
    )
  }

  /// Strict hex → sRGB components; alpha is parsed and dropped (the picker is opaque).
  private nonisolated static func rgbComponents(fromHex hex: String) -> RGBComponents? {
    var raw = hex
    if raw.hasPrefix("#") { raw.removeFirst() }
    guard raw.count == 6 || raw.count == 8 else { return nil }
    guard var value = UInt64(raw, radix: 16) else { return nil }
    if raw.count == 8 { value >>= 8 }
    return RGBComponents(
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255,
    )
  }

  private nonisolated static func hexString(_ rgb: RGBComponents) -> String {
    String(format: "#%02X%02X%02X", rgb.red.asColorChannel, rgb.green.asColorChannel, rgb.blue.asColorChannel)
  }
}

extension Double {
  fileprivate nonisolated var clampedToUnitRange: Double { Swift.min(Swift.max(self, 0), 1) }

  fileprivate nonisolated var asColorChannel: Int { Int((clampedToUnitRange * 255).rounded()) }
}
