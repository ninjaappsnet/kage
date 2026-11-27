import ConcurrencyExtras
import Darwin
import Foundation
import SupacodeSettingsShared

/// Uploads one pasted file to a remote Kage host with a single `ssh -T` over
/// the shared ControlMaster connection: the bytes go on stdin and the host
/// prints the path it wrote. Needs nothing from Kage on the host.
nonisolated enum RemotePasteUpload {
  /// `$0` of the remote `/bin/sh`, shown in its error messages.
  static let scriptName = "kage-paste"
  /// Uploads land in `<base>/kage-<user>/`.
  static let baseDirectory = "/tmp"
  /// macOS 27 no longer sweeps `/tmp` on a schedule (only at boot, and hosts
  /// rarely reboot), so each upload deletes pasted files older than this.
  static let retentionDays = 7

  /// The POSIX script run on the host. `$1` is the file name (made by
  /// `RemotePasteName`, checked again here), `$2` the base directory, `$3`
  /// the retention in days. The folder is the user's own and owner-only; a
  /// symlink or someone else's folder in the shared `/tmp` is refused.
  static let script = #"""
    set -eu
    case "$1" in ''|.*|*/*) echo "kage-paste: invalid file name" >&2; exit 2 ;; esac
    dir="$2/kage-$(id -un)"
    umask 077
    if [ -L "$dir" ]; then echo "kage-paste: $dir is a symbolic link" >&2; exit 3; fi
    mkdir -p "$dir"
    if [ -L "$dir" ] || [ ! -d "$dir" ] || [ ! -O "$dir" ]; then
    echo "kage-paste: $dir is not a folder you own" >&2; exit 3
    fi
    chmod 700 "$dir"
    find "$dir" -type f -mtime +"$3" -delete 2>/dev/null || true
    part="$dir/.$1.part"
    trap 'rm -f -- "$part"' EXIT
    cat > "$part"
    mv -f -- "$part" "$dir/$1"
    printf '%s\n' "$dir/$1"
    """#

  struct Invocation: Equatable, Sendable {
    var executableURL: URL
    var arguments: [String]
  }

  static func invocation(host: RemoteKageHost, name: String) -> Result<Invocation, RemotePasteProblem> {
    guard RemoteKageCommand.isSafe(host) else { return .failure(.invalidHost) }
    let invocation = SSHCommand.invocation(
      host: host.remoteHost,
      executable: "/bin/sh",
      arguments: ["-c", script, scriptName, name, baseDirectory, String(retentionDays)],
      workingDirectory: nil,
      extraOptions: SSHCommand.backgroundProbeOptions + ["-T"]
    )
    return .success(Invocation(executableURL: invocation.executableURL, arguments: invocation.arguments))
  }

  /// The remote path from the script's output. The login shell may print
  /// before the script runs, so only the last line counts, and it must be the
  /// absolute path of the file that was sent.
  static func remotePath(from result: RemotePasteProcess.Result, name: String) -> Result<String, RemotePasteProblem> {
    if result.status == 255 { return .failure(.unreachable) }
    guard result.status == 0 else {
      let lines = lastLines(result.stderr)
      let prefix = scriptName + ": "
      let message =
        lines.last(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
        ?? lines.last
        ?? "The upload failed (exit \(result.status))."
      return .failure(.uploadFailed(message))
    }
    guard let path = lastLines(result.stdout).last, path.hasPrefix("/"), path.hasSuffix("/" + name),
      !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    else { return .failure(.uploadFailed("The host answered with an unexpected path.")) }
    return .success(path)
  }

  private static func lastLines(_ data: Data) -> [String] {
    (String(bytes: data, encoding: .utf8) ?? "")
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }
}

/// Runs one process with `input` on stdin and collects its output. The exit
/// is reported once both pipes have closed or half a second after the process
/// ended, whichever comes first: an ssh that became the ControlMaster leaves a
/// forked master holding the pipes open for minutes.
nonisolated enum RemotePasteProcess {
  struct Result: Equatable, Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
  }

  private struct State {
    var stdout = Data()
    var stderr = Data()
    var openPipes = 2
    var status: Int32?
    var continuation: CheckedContinuation<Result, any Error>?
  }

  static let drainGrace: DispatchTimeInterval = .milliseconds(500)

  static func run(executableURL: URL, arguments: [String], input: Data) async throws -> Result {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    // A host that hangs up mid-upload must fail the write, not SIGPIPE the app.
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

    let state = LockIsolated(State())
    let finish: @Sendable (_ force: Bool) -> Void = { force in
      let ready: (CheckedContinuation<Result, any Error>, Result)? = state.withValue { state in
        guard let status = state.status, state.openPipes == 0 || force, let continuation = state.continuation
        else { return nil }
        state.continuation = nil
        return (continuation, Result(status: status, stdout: state.stdout, stderr: state.stderr))
      }
      guard let (continuation, result) = ready else { return }
      continuation.resume(returning: result)
    }
    let collect: @Sendable (FileHandle, _ isStdout: Bool) -> Void = { handle, isStdout in
      handle.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty {
          handle.readabilityHandler = nil
          state.withValue { $0.openPipes -= 1 }
          finish(false)
        } else {
          state.withValue { state in
            if isStdout { state.stdout.append(chunk) } else { state.stderr.append(chunk) }
          }
        }
      }
    }

    return try await withCheckedThrowingContinuation { continuation in
      state.withValue { $0.continuation = continuation }
      collect(stdout.fileHandleForReading, true)
      collect(stderr.fileHandleForReading, false)
      process.terminationHandler = { process in
        state.withValue { $0.status = process.terminationStatus }
        finish(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + drainGrace) { finish(true) }
      }
      do {
        try process.run()
      } catch {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        let pending = state.withValue { state in
          defer { state.continuation = nil }
          return state.continuation
        }
        pending?.resume(throwing: error)
        return
      }
      let writer = stdin.fileHandleForWriting
      DispatchQueue.global().async {
        try? writer.write(contentsOf: input)
        try? writer.close()
      }
    }
  }
}

/// Uploads one item and returns its path on the host. Injectable so tests
/// never reach ssh.
nonisolated struct RemotePasteUploader: Sendable {
  let upload: @Sendable (RemotePasteItem) async throws -> String

  init(upload: @escaping @Sendable (RemotePasteItem) async throws -> String) {
    self.upload = upload
  }

  static func ssh(host: RemoteKageHost) -> Self {
    Self { item in
      let invocation = try RemotePasteUpload.invocation(host: host, name: item.name).get()
      let result: RemotePasteProcess.Result
      do {
        result = try await RemotePasteProcess.run(
          executableURL: invocation.executableURL,
          arguments: invocation.arguments,
          input: item.data
        )
      } catch {
        throw RemotePasteProblem.uploadFailed(error.localizedDescription)
      }
      return try RemotePasteUpload.remotePath(from: result, name: item.name).get()
    }
  }
}
