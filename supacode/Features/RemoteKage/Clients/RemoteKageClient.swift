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
  /// Creates a tab on the host whose Claude Code runs as one of the host's
  /// accounts (`supacode host claude-tab new`).
  var newClaudeAccountTab:
    @Sendable (
      _ host: RemoteKageHost, _ cliPath: String, _ worktreeID: String, _ tabID: UUID, _ accountID: String,
      _ command: String
    ) async throws -> Void
  /// Restarts a host tab under one of the host's accounts (`supacode host claude-tab restart`).
  var restartTab:
    @Sendable (
      _ host: RemoteKageHost, _ cliPath: String, _ worktreeID: String, _ tabID: String, _ accountID: String
    ) async throws -> Void
}

nonisolated extension RemoteKageClient: DependencyKey {
  /// Runs everything through `RemoteKageTransport` (`ShellClient.ssh` over the
  /// shared ControlMaster, bounded by `RemoteKageCommand`'s timeouts).
  static let liveValue: Self = {
    // The CLI path a host's snapshot reported, per host. Dropped on failure so
    // a moved install falls back to the default path.
    let cliPaths = LockIsolated<[RemoteKageHost.ID: String]>([:])
    return Self(
      snapshot: { host in
        let cliPath = cliPaths.value[host.id] ?? RemoteKageCommand.defaultCLIPath
        do {
          let stdout = try await RemoteKageTransport.run(
            host: host,
            executable: cliPath,
            arguments: RemoteKageCommand.snapshotArguments,
            timeout: RemoteKageCommand.snapshotTimeout
          )
          let snapshot = try RemoteKageCommandResult.decodeSnapshot(stdout).get()
          if let reported = snapshot.cliPath, !reported.isEmpty {
            cliPaths.withValue { $0[host.id] = reported }
          }
          return snapshot
        } catch {
          cliPaths.withValue { $0[host.id] = nil }
          throw error
        }
      },
      screen: { host, zmxPath, session in
        let lines = try await RemoteKageTransport.runLines(
          host: host,
          executable: zmxPath,
          arguments: RemoteKageCommand.screenArguments(session: session),
          timeout: RemoteKageCommand.screenTimeout
        )
        return RemoteKageCommandResult.screenText(lines: lines)
      },
      send: { host, zmxPath, session, text in
        _ = try await RemoteKageTransport.run(
          host: host,
          executable: zmxPath,
          arguments: RemoteKageCommand.sendArguments(session: session, text: text),
          timeout: RemoteKageCommand.sendTimeout
        )
      },
      newTab: { host, cliPath, worktreeID, tabID, command in
        _ = try await RemoteKageTransport.run(
          host: host,
          executable: cliPath,
          arguments: RemoteKageCommand.newTabArguments(worktreeID: worktreeID, tabID: tabID, command: command),
          timeout: RemoteKageCommand.newTabTimeout
        )
      },
      newClaudeAccountTab: { host, cliPath, worktreeID, tabID, accountID, command in
        _ = try await RemoteKageTransport.run(
          host: host,
          executable: cliPath,
          arguments: RemoteKageCommand.newClaudeAccountTabArguments(
            worktreeID: worktreeID, tabID: tabID, accountID: accountID, command: command),
          timeout: RemoteKageCommand.newTabTimeout
        )
      },
      restartTab: { host, cliPath, worktreeID, tabID, accountID in
        _ = try await RemoteKageTransport.run(
          host: host,
          executable: cliPath,
          arguments: RemoteKageCommand.restartTabArguments(worktreeID: worktreeID, tabID: tabID, accountID: accountID),
          timeout: RemoteKageCommand.newTabTimeout
        )
      }
    )
  }()

  static let testValue = Self(
    snapshot: unimplemented("RemoteKageClient.snapshot", placeholder: HostSnapshot.placeholder),
    screen: unimplemented("RemoteKageClient.screen", placeholder: ""),
    send: unimplemented("RemoteKageClient.send"),
    newTab: unimplemented("RemoteKageClient.newTab"),
    newClaudeAccountTab: unimplemented("RemoteKageClient.newClaudeAccountTab"),
    restartTab: unimplemented("RemoteKageClient.restartTab")
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

nonisolated extension DependencyValues {
  var remoteKageClient: RemoteKageClient {
    get { self[RemoteKageClient.self] }
    set { self[RemoteKageClient.self] = newValue }
  }
}
