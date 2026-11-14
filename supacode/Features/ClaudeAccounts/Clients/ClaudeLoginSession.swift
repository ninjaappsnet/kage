import Foundation

/// A running `claude auth login` for one account.
///
/// The command opens the browser and finishes on its own once the user approves;
/// when the browser can't reach it, it prints a URL and waits on stdin for the code
/// the page shows (`Paste code here if prompted >`), which `send` forwards.
nonisolated struct ClaudeLoginSession: Sendable {
  enum Event: Equatable, Sendable {
    case output(String)
    case exited(Int32)
  }

  var events: AsyncStream<Event>
  var send: @Sendable (String) -> Void
  var cancel: @Sendable () -> Void

  static func launch(executableURL: URL, account: ClaudeAccount) throws -> Self {
    let handle = ProcessHandle()
    let process = handle.process
    process.executableURL = executableURL
    process.arguments = ["auth", "login"]
    var environment = ProcessInfo.processInfo.environment
    environment[ClaudeAccount.configDirectoryVariable] = account.configDirectoryPath
    process.environment = environment

    let output = Pipe()
    let input = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = input
    handle.input = input.fileHandleForWriting

    let (events, continuation) = AsyncStream.makeStream(of: Event.self)
    output.fileHandleForReading.readabilityHandler = { fileHandle in
      let data = fileHandle.availableData
      guard !data.isEmpty else {
        fileHandle.readabilityHandler = nil
        return
      }
      continuation.yield(.output(String(bytes: data, encoding: .utf8) ?? ""))
    }
    process.terminationHandler = { process in
      output.fileHandleForReading.readabilityHandler = nil
      // Flush whatever arrived between the last read and exit.
      let rest = output.fileHandleForReading.readDataToEndOfFile()
      if !rest.isEmpty { continuation.yield(.output(String(bytes: rest, encoding: .utf8) ?? "")) }
      continuation.yield(.exited(process.terminationStatus))
      continuation.finish()
    }
    continuation.onTermination = { _ in handle.terminate() }

    try process.run()
    return Self(
      events: events,
      send: { line in handle.write(line) },
      cancel: { handle.terminate() }
    )
  }

  /// Owns the non-Sendable `Process` and its stdin; every access goes through the lock.
  private nonisolated final class ProcessHandle: @unchecked Sendable {
    let process = Process()
    var input: FileHandle?
    private let lock = NSLock()

    func write(_ line: String) {
      lock.withLock {
        guard process.isRunning, let input else { return }
        try? input.write(contentsOf: Data((line + "\n").utf8))
      }
    }

    func terminate() {
      lock.withLock {
        if process.isRunning { process.terminate() }
      }
    }
  }
}
