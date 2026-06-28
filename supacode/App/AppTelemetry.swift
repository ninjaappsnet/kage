import Foundation
import SupacodeSettingsShared

/// Telemetry stripped from Kage: no analytics SDK is initialized or shipped.
/// Kept as a no-op so the app's startup wiring stays untouched.
enum AppTelemetry {
  @MainActor
  static func setup(settings: GlobalSettings, infoDictionary: [String: Any]) {}
}
