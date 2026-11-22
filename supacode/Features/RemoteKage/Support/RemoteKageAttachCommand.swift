import Foundation
import SupacodeSettingsShared

/// Builds the Ghostty surface command that attaches this Mac to one zmx
/// session on a remote Kage host, over the same multiplexed SSH connection the
/// rest of the app uses for that host (`SSHCommand.controlOptions`).
///
/// Shape, outermost first:
/// - `/bin/sh -c '<loop>'`: Ghostty runs a surface command as
///   `exec -l <command>`, so it must lead with an executable (#737).
/// - `SSHReconnectLoop`: ssh exit 255 (a dropped connection) retries with
///   backoff; any other exit ends the loop and so closes the surface. Ctrl+\\
///   (zmx detach) and the session ending both exit 0.
/// - `ssh -tt <control options> user@host '<remote command>'`, built by
///   `SSHCommand.commandLine`, so the remote side runs a login shell (PATH,
///   TMPDIR for zmx's socket dir) and falls back from `xterm-ghostty`.
/// - `attachScript` under `/bin/sh`, given the zmx path and session as
///   positional arguments, so neither is ever spliced into script text.
///
/// Connect and reconnect run the same script: it attaches only when the
/// session is listed, because `zmx attach` creates a missing session and this
/// Mac must never start sessions on the host. The window between the list
/// check and the attach is accepted (milliseconds, as in
/// `ZmxAttach.remoteReconnectScript`).
nonisolated enum RemoteKageAttachCommand {
  enum Problem: Error, Equatable, Sendable {
    /// Username or address could become an ssh option or shell syntax.
    case invalidDestination
    /// The host's zmx must be called by absolute path: it is not on the ssh PATH.
    case zmxPathNotAbsolute
    /// Empty, option-like, or carrying control characters.
    case invalidSession
  }

  /// `$0` of the remote `/bin/sh`, shown in its error messages.
  static let scriptName = "kage-remote-attach"

  /// The POSIX script run on the host. `$1` is the zmx path, `$2` the session.
  /// `grep -x` so a session whose name merely contains ours does not count.
  static let attachScript = #"""
    if "$1" list --short 2>/dev/null | grep -qxF -- "$2"; then
    exec "$1" attach "$2"
    fi
    printf '\033[2m── The remote session is no longer running. ──\033[0m\r\n'
    exit 0
    """#

  static func remoteHost(for host: RemoteKageHost) -> RemoteHost {
    RemoteHost(alias: host.address, username: host.username.isEmpty ? nil : host.username)
  }

  /// The single ssh line that attaches once. Also what the reconnect loop reruns.
  static func attachLine(
    host: RemoteKageHost,
    zmxPath: String,
    session: String,
    controlPath: String = SSHCommand.defaultControlPath
  ) -> Result<String, Problem> {
    if let problem = problem(host: host, zmxPath: zmxPath, session: session) {
      return .failure(problem)
    }
    return .success(
      SSHCommand.commandLine(
        host: remoteHost(for: host),
        remoteScript: attachScript,
        positionalArguments: [scriptName, zmxPath, session],
        controlPath: controlPath
      )
    )
  }

  /// The full Ghostty surface command: the attach line inside the reconnect loop.
  static func surfaceCommand(
    host: RemoteKageHost,
    zmxPath: String,
    session: String,
    controlPath: String = SSHCommand.defaultControlPath
  ) -> Result<String, Problem> {
    attachLine(host: host, zmxPath: zmxPath, session: session, controlPath: controlPath).map { line in
      "/bin/sh -c " + SSHCommand.shellQuote(SSHReconnectLoop.script(connect: line, reconnect: line))
    }
  }

  private static func problem(host: RemoteKageHost, zmxPath: String, session: String) -> Problem? {
    // `SSHCommand.commandLine` splices the destination unquoted, so it must be
    // made of shell-inert characters and must not read as an option.
    guard isSafeToken(host.address, extra: ":"), host.username.isEmpty || isSafeToken(host.username, extra: "")
    else { return .invalidDestination }
    guard zmxPath.hasPrefix("/") else { return .zmxPathNotAbsolute }
    guard !session.isEmpty, !session.hasPrefix("-"), !session.unicodeScalars.contains(where: isControl)
    else { return .invalidSession }
    return nil
  }

  /// ASCII letters, digits, `.`, `_`, `-` (plus `extra`), not leading with `-`.
  private static func isSafeToken(_ value: String, extra: String) -> Bool {
    guard let first = value.unicodeScalars.first, first != "-" else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      scalar.isASCII
        && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar)
          || extra.unicodeScalars.contains(scalar))
    }
  }

  private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value < 0x20 || scalar.value == 0x7F
  }
}
