import Clocks
import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// Request routing of `kage host serve`: lines in, response and event lines out.
/// Nonisolated (as are the other remote-file suites): nothing here needs the
/// main actor, and a full parallel run keeps it too busy to resume on time.
nonisolated struct RemoteFileServerTests {
  private struct Harness {
    let source = FakeRemoteFileEventSource()
    let server: RemoteFileServer
    let lines: AsyncStream<Data>

    init() {
      let (lines, continuation) = AsyncStream<Data>.makeStream()
      self.lines = lines
      let output = RemoteFileLineOutput { data in continuation.yield(data) }
      let watcher = RemoteFileWatcher(
        source: source,
        clock: TestClock(),
        resolve: FakeRemoteFileResolver.resolve(),
        gitStamp: { _ in RemoteFileGitStamp(head: nil, index: nil) },
        emit: { output.send($0) }
      )
      server = RemoteFileServer(
        handler: RemoteFileRequestHandler(kageVersion: "1.2.3"),
        watcher: watcher,
        output: output
      )
    }

    func nextLine() async -> Data? {
      var iterator = lines.makeAsyncIterator()
      return await iterator.next()
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func answersRequestsWithNewlineTerminatedJSONLines() async throws {
    let harness = Harness()
    harness.server.receive(line: Data(#"{"id":1,"op":"hello"}"#.utf8))
    let line = try #require(await harness.nextLine())
    #expect(line.last == UInt8(ascii: "\n"))
    let response = try RemoteFileWire.decode(RemoteFileResponse<RemoteFileHelloResult>.self, from: line)
    #expect(response == .success(id: 1, RemoteFileHelloResult(protocolVersion: 1, kageVersion: "1.2.3")))
  }

  @Test(.timeLimit(.minutes(1)))
  func malformedLinesGetABadRequestWithTheirIDWhenOneIsReadable() async throws {
    let harness = Harness()

    harness.server.receive(line: Data("not json".utf8))
    let garbage = try #require(await harness.nextLine())
    let garbageResponse = try RemoteFileWire.decode(RemoteFileResponse<RemoteFileEmptyResult>.self, from: garbage)
    #expect(garbageResponse.id == nil)
    #expect(garbageResponse.error?.code == .badRequest)

    harness.server.receive(line: Data(#"{"id":7,"op":"frobnicate"}"#.utf8))
    let unknown = try #require(await harness.nextLine())
    let unknownResponse = try RemoteFileWire.decode(RemoteFileResponse<RemoteFileEmptyResult>.self, from: unknown)
    #expect(unknownResponse.id == 7)
    #expect(unknownResponse.error?.code == .badRequest)

    harness.server.receive(line: Data(#"{"id":8,"op":"watch"}"#.utf8))
    let missing = try #require(await harness.nextLine())
    let missingResponse = try RemoteFileWire.decode(RemoteFileResponse<RemoteFileEmptyResult>.self, from: missing)
    #expect(missingResponse.id == 8)
    #expect(missingResponse.error?.code == .badRequest)
  }

  @Test(.timeLimit(.minutes(1)))
  func watchReplacesTheSetBeforeAnswering() async throws {
    let harness = Harness()
    harness.server.receive(line: Data(#"{"id":2,"op":"watch","paths":["/repo","/repo/src"]}"#.utf8))
    let line = try #require(await harness.nextLine())
    let response = try RemoteFileWire.decode(RemoteFileResponse<RemoteFileEmptyResult>.self, from: line)
    #expect(response == .success(id: 2, RemoteFileEmptyResult()))
    #expect(harness.source.starts.value == [.init(paths: ["/repo"], since: nil)])

    // Events go out on the same channel.
    harness.source.send(path: "/repo/src")
    let event = try #require(await harness.nextLine())
    #expect(try RemoteFileWire.decode(RemoteFileEvent.self, from: event) == .treeChanged(root: "/repo"))

    harness.server.receive(line: Data(#"{"id":3,"op":"watch","paths":[]}"#.utf8))
    _ = await harness.nextLine()
    #expect(!harness.source.isRunning)
  }

  @Test(.timeLimit(.minutes(1)))
  func finishStopsWatching() async {
    let harness = Harness()
    harness.server.receive(line: Data(#"{"id":1,"op":"watch","paths":["/repo"]}"#.utf8))
    _ = await harness.nextLine()
    let server = harness.server
    await Task.detached { server.finish() }.value
    #expect(!harness.source.isRunning)
  }
}
