import ConcurrencyExtras
import Darwin
import Foundation

/// One running `kage host serve`, seen from this Mac: its stdout as it arrives
/// and how it ended, plus the three things the session does to it. Behind this
/// shape the session never knows whether ssh, a local CLI (tests) or a fake
/// sits on the other end.
nonisolated struct RemoteKageServeChannel: Sendable {
  enum Output: Equatable, Sendable {
    /// A chunk of stdout, split anywhere (see `RemoteKageServeLineSplitter`).
    case data(Data)
    /// The process ended; `diagnostics` is the tail of its stderr. Always last.
    case exited(status: Int32, diagnostics: String)
  }

  let output: AsyncStream<Output>
  /// Queues bytes for stdin, in order. Never blocks the caller.
  let write: @Sendable (Data) -> Void
  /// Closes stdin; the host exits on EOF.
  let closeInput: @Sendable () -> Void
  /// Kills the process (a no-op once it has ended).
  let terminate: @Sendable () -> Void
}

/// Starts a channel. Injectable so tests run the real local CLI (`process`) or a
/// fake, and the app runs ssh (`ssh(host:cliPath:)`).
nonisolated struct RemoteKageServeLauncher: Sendable {
  let launch: @Sendable () throws -> RemoteKageServeChannel

  init(launch: @escaping @Sendable () throws -> RemoteKageServeChannel) {
    self.launch = launch
  }

  /// Runs `executableURL arguments` as a child process with piped stdio.
  static func process(executableURL: URL, arguments: [String]) -> Self {
    Self { try RemoteKageServeProcess.launch(executableURL: executableURL, arguments: arguments) }
  }

  /// `ssh -T … '<cli> host serve'` on `host`, reading the CLI path at each
  /// launch so a reconnect picks up a path the latest snapshot reported.
  static func ssh(host: RemoteKageHost, cliPath: @escaping @Sendable () -> String) -> Self {
    Self {
      guard RemoteKageCommand.isSafe(host) else {
        throw RemoteKageError.commandFailed("This host's address or username isn't valid.")
      }
      let invocation = RemoteKageServeCommand.sshInvocation(host: host, cliPath: cliPath())
      return try RemoteKageServeProcess.launch(
        executableURL: invocation.executableURL,
        arguments: invocation.arguments
      )
    }
  }
}

/// The live channel: a `Process` with three pipes. Stdin writes go through one
/// serial queue so a large save never blocks the session and lines never
/// interleave. The exit is reported once stdout has drained (so no response is
/// lost behind it) or a second after the process ended, whichever comes first:
/// an ssh ControlMaster forked by this process can keep the pipes open.
nonisolated enum RemoteKageServeProcess {
  /// Kept from stderr for classifying the exit.
  static let diagnosticsLimit = 8 * 1024

  private struct ExitState {
    var stdoutClosed = false
    var status: Int32?
    var diagnostics = Data()
    var reported = false
  }

  static func launch(executableURL: URL, arguments: [String]) throws -> RemoteKageServeChannel {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    // A write after the host died must fail, not kill the app with SIGPIPE.
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

    let (stream, continuation) = AsyncStream.makeStream(of: RemoteKageServeChannel.Output.self)
    let state = LockIsolated(ExitState())
    let reportExitIfDone: @Sendable (_ force: Bool) -> Void = { force in
      let report: (Int32, String)? = state.withValue { state in
        guard !state.reported, let status = state.status, state.stdoutClosed || force else { return nil }
        state.reported = true
        return (status, String(bytes: state.diagnostics, encoding: .utf8) ?? "")
      }
      guard let (status, diagnostics) = report else { return }
      continuation.yield(.exited(status: status, diagnostics: diagnostics))
      continuation.finish()
    }

    output.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        state.withValue { $0.stdoutClosed = true }
        reportExitIfDone(false)
      } else {
        continuation.yield(.data(chunk))
      }
    }
    errors.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      state.withValue { state in
        state.diagnostics.append(chunk)
        if state.diagnostics.count > diagnosticsLimit {
          state.diagnostics = Data(state.diagnostics.suffix(diagnosticsLimit))
        }
      }
    }
    process.terminationHandler = { process in
      state.withValue { $0.status = process.terminationStatus }
      reportExitIfDone(false)
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) { reportExitIfDone(true) }
    }

    try process.run()

    let writer = DispatchQueue(label: "net.ninjaapps.kage.remote-serve.stdin")
    let stdin = input.fileHandleForWriting
    let running = UncheckedSendable(process)
    return RemoteKageServeChannel(
      output: stream,
      write: { data in
        writer.async { try? stdin.write(contentsOf: data) }
      },
      closeInput: {
        writer.async { try? stdin.close() }
      },
      terminate: {
        if running.value.isRunning {
          running.value.terminate()
        }
      }
    )
  }
}
