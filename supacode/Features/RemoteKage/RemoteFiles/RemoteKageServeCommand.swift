import Foundation
import SupacodeSettingsShared

/// How this Mac starts `kage host serve` on a host: the CLI found where the
/// host's snapshot said it lives, run over the shared ControlMaster connection
/// (`SSHCommand.controlOptions`) with the non-interactive probe options and no
/// tty (`-T`), so stdin EOF reaches the host process and ends it.
nonisolated enum RemoteKageServeCommand {
  static let arguments = ["host", "serve"]

  /// Debug builds only: run this CLI on the host instead of the installed one,
  /// to try a `host serve` the host's Kage does not ship yet. Must be absolute.
  static let cliPathOverrideEnvironmentKey = "KAGE_REMOTE_CLI_PATH_OVERRIDE"

  static let sshOptions = SSHCommand.backgroundProbeOptions + ["-T"]

  static func cliPath(reported: String?, environment: [String: String]) -> String {
    #if DEBUG
      if let override = environment[cliPathOverrideEnvironmentKey], override.hasPrefix("/") {
        return override
      }
    #endif
    if let reported, !reported.isEmpty { return reported }
    return RemoteKageCommand.defaultCLIPath
  }

  static func sshInvocation(host: RemoteKageHost, cliPath: String) -> (executableURL: URL, arguments: [String]) {
    SSHCommand.invocation(
      host: host.remoteHost,
      executable: cliPath,
      arguments: arguments,
      workingDirectory: nil,
      extraOptions: sshOptions
    )
  }
}
