import Foundation
import Testing

/// Debug builds (the test host, `make run-app`, the dev sandbox's source) must
/// not carry the release bundle identifier. macOS keys privacy grants (Screen
/// Recording, Accessibility, …) and UserDefaults by bundle identifier, so an
/// ad-hoc signed Debug build under `net.ninjaapps.kage` re-binds the installed
/// Kage's grants to itself the moment someone allows its prompt, and the
/// installed app starts prompting in a loop (2026-11-25).
struct DebugBundleIdentifierTests {
  @Test func debugBuildHasItsOwnBundleIdentifier() {
    #expect(Bundle.main.bundleIdentifier == "net.ninjaapps.kage.debug")
  }
}
