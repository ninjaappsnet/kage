import Foundation

/// Reads what a host command printed: maps an exit status and its output to
/// success or a `RemoteKageError`, decodes snapshots and screens.
nonisolated enum RemoteKageCommandResult {
  static let notInstalledMessage = "Kage isn't installed at /Applications on the host."
  static let notASnapshotMessage = "The host answered with something that isn't a Kage snapshot."
  static let newerSchemaMessage = "The host's Kage is newer than this Mac's. Update Kage on this Mac."

  /// ssh's own failures (resolve, connect, auth, host key) all exit 255.
  static let sshFailureExitCode: Int32 = 255
  /// ArgumentParser's usage error, e.g. an old CLI without `host`.
  static let usageExitCode: Int32 = 64
  /// EX_UNAVAILABLE: the host CLI found no running Kage.
  static let unavailableExitCode: Int32 = 69
  /// The login shell couldn't find the executable.
  static let commandNotFoundExitCode: Int32 = 127

  /// Messages the host CLI prints when no Kage app answers its socket.
  private static let kageNotRunningMarkers = [
    "kage isn't running",
    "timed out waiting for kage to start",
    "failed to launch kage",
    "unable to find application named",
    "failed to connect to socket at",
  ]

  static func classify(exitCode: Int32, stdout: String, stderr: String) -> Result<String, RemoteKageError> {
    guard exitCode != 0 else { return .success(stdout) }
    return .failure(error(exitCode: exitCode, stdout: stdout, stderr: stderr))
  }

  static func error(exitCode: Int32, stdout: String, stderr: String) -> RemoteKageError {
    let output = stderr.isEmpty ? stdout : stderr
    let lowered = (stderr + "\n" + stdout).lowercased()
    if exitCode == sshFailureExitCode {
      return .unreachable(lastLine(of: output, dropping: "ssh: ") ?? "ssh failed (exit \(exitCode)).")
    }
    if lowered.contains("unknown resource: host-snapshot")
      || (exitCode == usageExitCode && lowered.contains("'host'"))
    {
      return .needsUpdate
    }
    if exitCode == unavailableExitCode || kageNotRunningMarkers.contains(where: lowered.contains) {
      return .kageNotRunning
    }
    if exitCode == commandNotFoundExitCode {
      return .commandFailed(notInstalledMessage)
    }
    return .commandFailed(
      lastLine(of: output, dropping: "Error: ") ?? "The host command failed (exit \(exitCode)).")
  }

  /// Decodes `host snapshot` output. Tolerates login-shell noise around the
  /// JSON and unknown fields from a newer host.
  static func decodeSnapshot(_ stdout: String) -> Result<HostSnapshot, RemoteKageError> {
    let decoder = JSONDecoder()
    let candidates = jsonCandidates(in: stdout)
    for candidate in candidates {
      if let snapshot = try? decoder.decode(HostSnapshot.self, from: Data(candidate.utf8)) {
        return .success(snapshot)
      }
    }
    let reportedVersion = candidates.lazy
      .compactMap { try? decoder.decode(VersionProbe.self, from: Data($0.utf8)).schemaVersion }
      .first
    if let reportedVersion, reportedVersion > HostSnapshot.currentSchemaVersion {
      return .failure(.commandFailed(newerSchemaMessage))
    }
    return .failure(.commandFailed(notASnapshotMessage))
  }

  /// A screen from `zmx history --screen`: lines kept verbatim (leading
  /// whitespace is layout), trailing blank rows dropped.
  static func screenText(lines: [String]) -> String {
    var lines = lines
    while let last = lines.last, last.allSatisfy(\.isWhitespace) {
      lines.removeLast()
    }
    return lines.joined(separator: "\n")
  }

  private struct VersionProbe: Decodable {
    var schemaVersion: Int
  }

  private static func jsonCandidates(in stdout: String) -> [String] {
    let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    var candidates = [trimmed]
    if let open = trimmed.firstIndex(of: "{"), let close = trimmed.lastIndex(of: "}"), open < close {
      let object = String(trimmed[open...close])
      if object != trimmed {
        candidates.append(object)
      }
    }
    return candidates
  }

  private static func lastLine(of output: String, dropping prefix: String) -> String? {
    let line = output.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .last { !$0.isEmpty }
    guard let line else { return nil }
    return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line
  }
}
