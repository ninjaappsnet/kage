import Dependencies
import Foundation
import SupacodeSettingsShared

/// Runs one command on a host over the shared SSH connection
/// (`ShellClient.ssh` with the shared ControlMaster and the non-interactive
/// probe options), with a time limit, and classifies the outcome.
nonisolated enum RemoteKageTransport {
  /// Runs `executable arguments` on the host and returns its stdout.
  static func run(
    host: RemoteKageHost,
    executable: String,
    arguments: [String],
    timeout: Duration
  ) async throws -> String {
    let shell = try sshShell(for: host)
    return try await withTimeout(timeout) {
      try await classified {
        let output = try await shell.run(URL(fileURLWithPath: executable), arguments, nil)
        return try RemoteKageCommandResult.classify(
          exitCode: output.exitCode, stdout: output.stdout, stderr: output.stderr
        ).get()
      }
    }
  }

  /// Like `run`, but returns stdout as raw lines (leading whitespace kept),
  /// for screens whose layout matters.
  static func runLines(
    host: RemoteKageHost,
    executable: String,
    arguments: [String],
    timeout: Duration
  ) async throws -> [String] {
    let shell = try sshShell(for: host)
    return try await withTimeout(timeout) {
      try await classified {
        var lines: [String] = []
        var finished: ShellOutput?
        for try await event in shell.runStream(URL(fileURLWithPath: executable), arguments, nil) {
          switch event {
          case .line(let line) where line.source == .stdout:
            lines.append(line.text)
          case .line:
            break
          case .finished(let output):
            finished = output
          }
        }
        // A transport that only reports the finished output still yields its text.
        if lines.isEmpty, let finished, !finished.stdout.isEmpty {
          lines = finished.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        return lines
      }
    }
  }

  private static func sshShell(for host: RemoteKageHost) throws -> ShellClient {
    guard RemoteKageCommand.isSafe(host) else {
      throw RemoteKageError.commandFailed("This host's address or username isn't valid.")
    }
    @Dependency(\.shellClient) var base
    return ShellClient.ssh(host: host.remoteHost, base: base, extraOptions: SSHCommand.backgroundProbeOptions)
  }

  /// Turns a failed process into the matching `RemoteKageError`.
  private static func classified<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
    do {
      return try await operation()
    } catch let error as ShellClientError {
      throw RemoteKageCommandResult.error(exitCode: error.exitCode, stdout: error.stdout, stderr: error.stderr)
    } catch let error as RemoteKageError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw RemoteKageError.commandFailed(error.localizedDescription)
    }
  }

  /// Races `operation` against `timeout` on the injected clock; the loser is
  /// cancelled, which terminates the ssh process.
  static func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    @Dependency(\.continuousClock) var continuousClock
    let clock = continuousClock
    return try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await clock.sleep(for: timeout)
        throw RemoteKageError.unreachable("The host didn't answer within \(timeout.components.seconds) seconds.")
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw CancellationError() }
      return result
    }
  }
}
