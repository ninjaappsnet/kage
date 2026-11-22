import ComposableArchitecture
import Foundation

nonisolated enum RemoteKageError: LocalizedError, Equatable, Sendable {
  /// ssh could not reach or log in to the host (exit 255, timeout, auth).
  case unreachable(String)
  /// The host answered but its Kage app is not running (no socket).
  case kageNotRunning
  /// The host's Kage is too old to answer `host snapshot`.
  case needsUpdate
  /// The host answered with something that is not a snapshot / failed command.
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case .unreachable(let message): "Can't reach the host: \(message)"
    case .kageNotRunning: "Kage isn't running on the host."
    case .needsUpdate: "The host's Kage is too old. Update Kage on that Mac."
    case .commandFailed(let message): message
    }
  }
}

/// Everything the Remote Kage hosts feature runs on another Mac, over one
/// multiplexed SSH connection per host (`SSHCommand.controlOptions`).
nonisolated struct RemoteKageClient: Sendable {
  /// Runs the host's `supacode host snapshot` and decodes it.
  var snapshot: @Sendable (RemoteKageHost) async throws -> HostSnapshot
  /// The current screen of a session (`zmx history <session> --screen`), plain text.
  var screen: @Sendable (_ host: RemoteKageHost, _ zmxPath: String, _ session: String) async throws -> String
  /// Types raw input into a session without attaching (`zmx send`).
  /// `text` is sent verbatim; include "\r" for Enter.
  var send:
    @Sendable (_ host: RemoteKageHost, _ zmxPath: String, _ session: String, _ text: String) async throws -> Void
  /// Creates a tab on the host (`supacode tab new -w <encoded id> --id <uuid> [--command]`).
  var newTab:
    @Sendable (
      _ host: RemoteKageHost, _ cliPath: String, _ worktreeID: String, _ tabID: UUID, _ command: String?
    ) async throws -> Void
}

nonisolated extension RemoteKageClient: DependencyKey {
  /// Replaced by the real implementation (Phase 3).
  static let liveValue = Self(
    snapshot: { _ in throw RemoteKageError.commandFailed("Not implemented") },
    screen: { _, _, _ in throw RemoteKageError.commandFailed("Not implemented") },
    send: { _, _, _, _ in throw RemoteKageError.commandFailed("Not implemented") },
    newTab: { _, _, _, _, _ in throw RemoteKageError.commandFailed("Not implemented") }
  )

  static let testValue = Self(
    snapshot: unimplemented("RemoteKageClient.snapshot", placeholder: HostSnapshot.placeholder),
    screen: unimplemented("RemoteKageClient.screen", placeholder: ""),
    send: unimplemented("RemoteKageClient.send"),
    newTab: unimplemented("RemoteKageClient.newTab")
  )
}

nonisolated extension HostSnapshot {
  static let placeholder = HostSnapshot(
    schemaVersion: HostSnapshot.currentSchemaVersion,
    kageVersion: "",
    machineName: "",
    zmxPath: nil,
    cliPath: nil,
    workspaces: [],
    repositories: []
  )
}

extension DependencyValues {
  var remoteKageClient: RemoteKageClient {
    get { self[RemoteKageClient.self] }
    set { self[RemoteKageClient.self] = newValue }
  }
}
