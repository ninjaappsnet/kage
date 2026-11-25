import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// The host end of a serve channel, driven by a test: records every request
/// line the session writes and lets the test answer, push events, or exit.
nonisolated final class FakeServeChannel: Sendable {
  let channel: RemoteKageServeChannel
  let requests = LockIsolated<[RemoteFileRequest]>([])
  let inputClosed = LockIsolated(false)
  let terminated = LockIsolated(false)
  private let continuation: AsyncStream<RemoteKageServeChannel.Output>.Continuation

  init() {
    let (output, continuation) = AsyncStream.makeStream(of: RemoteKageServeChannel.Output.self)
    self.continuation = continuation
    let requests = requests
    let inputClosed = inputClosed
    let terminated = terminated
    let splitter = LockIsolated(RemoteKageServeLineSplitter())
    channel = RemoteKageServeChannel(
      output: output,
      write: { data in
        let lines = splitter.withValue { $0.append(data) }
        for line in lines {
          if let request = try? RemoteFileWire.decode(RemoteFileRequest.self, from: line) {
            requests.withValue { $0.append(request) }
          }
        }
      },
      closeInput: { inputClosed.setValue(true) },
      terminate: { terminated.setValue(true) }
    )
  }

  /// Sends raw bytes, as the host's stdout would.
  func sendRaw(_ text: String) {
    continuation.yield(.data(Data(text.utf8)))
  }

  func send(_ value: some Encodable) {
    var line = (try? RemoteFileWire.encodeLine(value)) ?? Data()
    line.append(UInt8(ascii: "\n"))
    continuation.yield(.data(line))
  }

  func respond<Result: Codable & Sendable>(to id: Int, with result: Result) {
    send(RemoteFileResponse<Result>.success(id: id, result))
  }

  func fail(_ id: Int, _ error: RemoteFileError) {
    send(RemoteFileResponse<RemoteFileEmptyResult>.failure(id: id, error))
  }

  func push(_ event: RemoteFileEvent) {
    send(event)
  }

  func exit(_ status: Int32, diagnostics: String = "") {
    continuation.yield(.exited(status: status, diagnostics: diagnostics))
    continuation.finish()
  }

  /// The `index`-th request (0-based) with `operation`, once written.
  func request(_ operation: RemoteFileOperation, index: Int = 0) async throws -> RemoteFileRequest {
    var found: RemoteFileRequest?
    let arrived = await serveEventually {
      let matching = requests.value.filter { $0.operation == operation }
      found = matching.count > index ? matching[index] : nil
      return found != nil
    }
    try #require(arrived, "no \(operation) request #\(index) arrived")
    return try #require(found)
  }

  func count(_ operation: RemoteFileOperation) -> Int {
    requests.value.filter { $0.operation == operation }.count
  }

  /// Answers the session's hello.
  func answerHello(protocolVersion: Int = RemoteFileWire.protocolVersion) async throws {
    let hello = try await request(.hello)
    respond(to: hello.id, with: RemoteFileHelloResult(protocolVersion: protocolVersion, kageVersion: "9.9.9"))
  }
}

/// Hands the session a fresh `FakeServeChannel` per launch.
nonisolated final class FakeServeLauncher: Sendable {
  let channels = LockIsolated<[FakeServeChannel]>([])
  let failure = LockIsolated<String?>(nil)

  var launcher: RemoteKageServeLauncher {
    let channels = channels
    let failure = failure
    return RemoteKageServeLauncher {
      if let message = failure.value {
        throw RemoteKageError.commandFailed(message)
      }
      let channel = FakeServeChannel()
      channels.withValue { $0.append(channel) }
      return channel.channel
    }
  }

  var launchCount: Int { channels.value.count }

  func channel(_ index: Int) async throws -> FakeServeChannel {
    let arrived = await serveEventually { channels.value.count > index }
    try #require(arrived, "launch #\(index) never happened")
    return channels.value[index]
  }
}

/// Waits (yielding, never sleeping) until `condition` holds, for at most
/// `timeout` of real time. Returns whether it did. The bound is generous: under
/// the full suite's load an actor hop can wait many seconds for a thread, and the
/// bound only matters when a test is failing anyway.
nonisolated func serveEventually(
  timeout: Duration = .seconds(60),
  _ condition: () async -> Bool
) async -> Bool {
  let start = ContinuousClock.now
  while !(await condition()) {
    if ContinuousClock.now - start > timeout { return false }
    await Task.yield()
  }
  return true
}

/// Collects a session's events for a test.
nonisolated final class EventRecorder<Event: Sendable>: Sendable {
  let events = LockIsolated<[Event]>([])
  private let task: LockIsolated<Task<Void, Never>?> = LockIsolated(nil)

  init(_ stream: AsyncStream<Event>) {
    let events = events
    task.setValue(
      Task {
        for await event in stream {
          events.withValue { $0.append(event) }
        }
      })
  }

  func cancel() { task.value?.cancel() }
}
