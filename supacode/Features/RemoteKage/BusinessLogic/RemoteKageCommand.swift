import Foundation
import SupacodeSettingsShared

/// What the Remote Kage client runs on a host: absolute paths, arguments and
/// time limits. Pure, so the exact command lines are testable.
nonisolated enum RemoteKageCommand {
  /// Where a standard install keeps the CLI. Used until a snapshot reports its own path.
  static let defaultCLIPath = "/Applications/Kage.app/Contents/Resources/bin/supacode"
  /// Where a standard install keeps zmx. Snapshots report the real path.
  static let defaultZmxPath = "/Applications/Kage.app/Contents/Resources/zmx/zmx"

  /// Upper bounds per call, so a host that accepts the connection and then
  /// hangs can't wedge polling. `ConnectTimeout` already bounds the handshake.
  static let snapshotTimeout: Duration = .seconds(20)
  static let screenTimeout: Duration = .seconds(15)
  static let sendTimeout: Duration = .seconds(15)
  /// The host CLI waits for its app to create the tab, so allow longer.
  static let newTabTimeout: Duration = .seconds(30)

  static let snapshotArguments = ["host", "snapshot"]

  static func screenArguments(session: String) -> [String] {
    ["history", session, "--screen"]
  }

  static func sendArguments(session: String, text: String) -> [String] {
    ["send", session, text]
  }

  /// `tab new` on the host. The CLI's `-w` takes the percent-encoded id it
  /// prints in `worktree list`; `--background` leaves the host's own selection
  /// alone; `--input=` keeps a command starting with "-" from reading as an option.
  static func newTabArguments(worktreeID: String, tabID: UUID, command: String?) -> [String] {
    var arguments = [
      "tab", "new",
      "-w", WorktreeStatusQueryResponse.encoded(id: worktreeID),
      "--id", tabID.uuidString,
      "--background",
    ]
    if let command {
      arguments.append("--input=\(command)")
    }
    return arguments
  }

  /// `host claude-tab new` on the host: assigns the host account, then creates
  /// the tab in the background like `tab new`.
  static func newClaudeAccountTabArguments(
    worktreeID: String,
    tabID: UUID,
    accountID: String,
    command: String?
  ) -> [String] {
    var arguments = [
      "host", "claude-tab", "new",
      "-w", WorktreeStatusQueryResponse.encoded(id: worktreeID),
      "--id", tabID.uuidString,
      "--account", accountID,
    ]
    if let command {
      arguments.append("--input=\(command)")
    }
    return arguments
  }

  /// `host claude-tab restart` on the host.
  static func restartTabArguments(worktreeID: String, tabID: String, accountID: String) -> [String] {
    [
      "host", "claude-tab", "restart",
      "-w", WorktreeStatusQueryResponse.encoded(id: worktreeID),
      "--tab", tabID,
      "--account", accountID,
    ]
  }

  /// Characters that never belong in a host name or login, so a value carrying
  /// them is refused before it reaches ssh's argv.
  private static let unsafeCharacters = CharacterSet.whitespacesAndNewlines
    .union(.controlCharacters)
    .union(CharacterSet(charactersIn: "'\"`$;&|<>()\\*?!{}#~@,"))

  /// Whether the host's address and username are safe to hand to ssh: no
  /// leading "-" (which ssh would read as an option), no whitespace and no
  /// shell metacharacters. An empty username means "this Mac's user".
  static func isSafe(_ host: RemoteKageHost) -> Bool {
    isSafeToken(host.address) && (host.username.isEmpty || isSafeToken(host.username))
  }

  private static func isSafeToken(_ value: String) -> Bool {
    guard !value.isEmpty, !value.hasPrefix("-") else { return false }
    return value.unicodeScalars.allSatisfy { !unsafeCharacters.contains($0) }
  }
}

nonisolated extension RemoteKageHost {
  /// The SSH destination the rest of the app uses, so polling, attached
  /// terminals and Remote SSH repositories on the same host share one
  /// ControlMaster connection.
  var remoteHost: RemoteHost {
    RemoteHost(alias: address, username: username.isEmpty ? nil : username)
  }
}

nonisolated extension RemoteKageError {
  /// Keeps a `RemoteKageError` as is and turns anything else into a failed command.
  static func wrapping(_ error: any Error) -> RemoteKageError {
    (error as? RemoteKageError) ?? .commandFailed(error.localizedDescription)
  }
}
