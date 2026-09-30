import SupacodeSettingsShared
import SwiftUI

/// In-app replacement for SwiftUI's `ColorPicker`: a saturation/brightness
/// field, a hue slider, and a hex field.
///
/// `ColorPicker` is unusable here because it instantiates `NSColorPanel.shared`,
/// a singleton that survives for the process lifetime and then feeds every
/// `NSTextView` typing-attribute change into KVO bindings that dirty layout —
/// an infinite layout loop that crashes the app. See
/// `RepositoryColor+CustomPicker.swift` for the full chain.
///
/// Sizes are fixed constants so drag locations map to components without a
/// `GeometryReader`.
struct CustomColorPopover: View {
  @Binding var color: RepositoryColor?

  @State private var hsb: RepositoryColor.HSB
  @State private var hexInput: String

  private static let fieldWidth: CGFloat = 216
  private static let fieldHeight: CGFloat = 136
  private static let sliderHeight: CGFloat = 16
  private static let knobDiameter: CGFloat = 14

  /// Hue ramp for the slider, sampled through the same math the picker commits
  /// with so the gradient never drifts from the value it yields.
  private static let hueStops: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 12.0).map { hue in
    RepositoryColor.custom(.init(hue: hue, saturation: 1, brightness: 1)).color
  }

  init(color: Binding<RepositoryColor?>) {
    _color = color
    let seed = color.wrappedValue ?? .blue
    _hsb = State(initialValue: seed.hsb)
    _hexInput = State(initialValue: seed.resolvedHex)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      saturationBrightnessField
      hueSlider
      hexField
    }
    .padding(12)
  }

  // MARK: - Saturation / brightness.

  private var saturationBrightnessField: some View {
    Rectangle()
      .fill(RepositoryColor.custom(.init(hue: hsb.hue, saturation: 1, brightness: 1)).color)
      .overlay {
        LinearGradient(
          colors: [.white, .white.opacity(0)],
          startPoint: .leading,
          endPoint: .trailing,
        )
      }
      .overlay {
        LinearGradient(
          colors: [.black.opacity(0), .black],
          startPoint: .top,
          endPoint: .bottom,
        )
      }
      .frame(width: Self.fieldWidth, height: Self.fieldHeight)
      .clipShape(.rect(cornerRadius: 8))
      .overlay(alignment: .topLeading) { fieldKnob }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            apply(
              .init(
                hue: hsb.hue,
                saturation: Double(value.location.x / Self.fieldWidth),
                brightness: 1 - Double(value.location.y / Self.fieldHeight),
              )
            )
          }
      )
      .accessibilityElement()
      .accessibilityLabel("Saturation and brightness")
      .accessibilityValue(hexInput)
      .help("Drag to set saturation and brightness")
  }

  private var fieldKnob: some View {
    Circle()
      .fill(RepositoryColor.custom(hsb).color)
      .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
      .shadow(radius: 1)
      .frame(width: Self.knobDiameter, height: Self.knobDiameter)
      .offset(
        x: hsb.saturation * Self.fieldWidth - Self.knobDiameter / 2,
        y: (1 - hsb.brightness) * Self.fieldHeight - Self.knobDiameter / 2,
      )
      .allowsHitTesting(false)
  }

  // MARK: - Hue.

  private var hueSlider: some View {
    LinearGradient(colors: Self.hueStops, startPoint: .leading, endPoint: .trailing)
      .frame(width: Self.fieldWidth, height: Self.sliderHeight)
      .clipShape(.capsule)
      .overlay(alignment: .leading) { hueKnob }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            apply(
              .init(
                hue: Double(value.location.x / Self.fieldWidth),
                saturation: hsb.saturation,
                brightness: hsb.brightness,
              )
            )
          }
      )
      .accessibilityElement()
      .accessibilityLabel("Hue")
      .accessibilityValue(hexInput)
      .accessibilityAdjustableAction { direction in
        let step = 1.0 / 36.0
        let delta = direction == .increment ? step : -step
        apply(.init(hue: hsb.hue + delta, saturation: hsb.saturation, brightness: hsb.brightness))
      }
      .help("Drag to set the hue")
  }

  private var hueKnob: some View {
    Circle()
      .fill(RepositoryColor.custom(.init(hue: hsb.hue, saturation: 1, brightness: 1)).color)
      .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
      .shadow(radius: 1)
      .frame(width: Self.sliderHeight + 2, height: Self.sliderHeight + 2)
      .offset(x: hsb.hue * Self.fieldWidth - (Self.sliderHeight + 2) / 2)
      .allowsHitTesting(false)
  }

  // MARK: - Hex.

  private var hexField: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(RepositoryColor.custom(hsb).color)
        .overlay { Circle().strokeBorder(.separator, lineWidth: 1) }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
      TextField("Hex", text: $hexInput)
        .monospaced()
        .onSubmit { commitHexInput() }
        .help("Type a hex value like #A1B2C3 and press ↩")
    }
    .frame(width: Self.fieldWidth)
  }

  // MARK: - Commits.

  /// Single write path for drag-driven changes: clamping lives in
  /// `RepositoryColor.custom(_:)`, so the stored hex and the echoed field always
  /// agree with what the knobs show.
  private func apply(_ candidate: RepositoryColor.HSB) {
    let clamped = candidate.clamped
    let committed = RepositoryColor.custom(clamped)
    hsb = clamped
    hexInput = committed.resolvedHex
    color = committed
  }

  /// Malformed input reverts to the live value rather than clearing the color.
  private func commitHexInput() {
    guard let parsed = RepositoryColor.custom(fromHexInput: hexInput) else {
      hexInput = RepositoryColor.custom(hsb).resolvedHex
      return
    }
    hsb = parsed.hsb
    hexInput = parsed.resolvedHex
    color = parsed
  }
}
