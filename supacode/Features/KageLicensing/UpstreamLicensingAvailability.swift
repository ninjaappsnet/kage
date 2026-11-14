import Foundation

/// Upstream gates worktree creation behind a paid Supacode license in release builds
/// (supabitapp/supacode#892): five free creations, then activation against
/// license.supacode.sh. Kage is not sold through that service, so the gate is off.
///
/// Upstream's implementation stays in the codebase — deleting it would turn every future
/// sync into a conflict — but it never runs: `LicenseBuild.isEnforced` reads this flag, which
/// skips the launch-time license check, the creation allowance, and the updater entitlement
/// check, and the License settings pane is hidden.
nonisolated enum UpstreamLicensingAvailability {
  static let isEnabled = false
}
