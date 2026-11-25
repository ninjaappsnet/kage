import Foundation

/// Why a host's file channel (`kage host serve`) is not usable. Only `offline`
/// is retried: an old or newer host stays as it is until Kage there (or here)
/// is updated, so retrying would only spawn ssh processes for nothing.
nonisolated enum RemoteKageServeFailure: Equatable, Sendable {
  /// The host's Kage predates `host serve`.
  case needsUpdate
  /// The host speaks a newer protocol than this Mac understands.
  case hostIsNewer(protocolVersion: Int)
  /// The link is down or the process ended; retried with backoff while visible.
  case offline(String)

  static let connectionClosedMessage = "The connection to the host's files closed."
  static let noAnswerMessage = "The host didn't answer the file connection in time."

  var isRetryable: Bool {
    if case .offline = self { return true }
    return false
  }

  /// What the explorer and viewer show for this failure.
  var message: String {
    switch self {
    case .needsUpdate:
      "Kage on that Mac is too old to share its files. Update Kage there."
    case .hostIsNewer(let version):
      "The host's Kage uses a newer file protocol (v\(version)). Update Kage on this Mac."
    case .offline(let message):
      message
    }
  }

  /// Classifies how the serve process ended. Before the hello answer, a usage
  /// error is an old host CLI without `serve` (ArgumentParser exits 64 with
  /// "Unexpected argument 'serve'"); after it, any exit is a lost connection.
  static func classify(exitStatus: Int32, diagnostics: String, helloAnswered: Bool) -> Self {
    if helloAnswered, exitStatus != RemoteKageCommandResult.sshFailureExitCode {
      return .offline(connectionClosedMessage)
    }
    let lowered = diagnostics.lowercased()
    if !helloAnswered,
      exitStatus == RemoteKageCommandResult.usageExitCode || lowered.contains("'serve'")
        || lowered.contains("unknown subcommand")
    {
      return .needsUpdate
    }
    switch RemoteKageCommandResult.error(exitCode: exitStatus, stdout: "", stderr: diagnostics) {
    case .needsUpdate:
      return .needsUpdate
    case .unreachable(let reason):
      return .offline("Can't reach the host: \(reason)")
    case .kageNotRunning:
      return .offline(connectionClosedMessage)
    case .commandFailed(let message):
      return .offline(message)
    }
  }
}
