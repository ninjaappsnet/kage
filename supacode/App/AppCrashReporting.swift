import Foundation
import SupacodeSettingsShared

/// Crash reporting stripped from Kage: no Sentry SDK is initialized or shipped.
/// Kept as a no-op so the app's startup wiring stays untouched.
enum AppCrashReporting {
  @MainActor
  static func setup(settings: GlobalSettings, infoDictionary: [String: Any]) {}
}
