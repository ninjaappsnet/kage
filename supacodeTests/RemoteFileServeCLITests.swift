import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// Runs the bundled CLI's `host serve` as a subprocess, the way a viewer does
/// over ssh: requests on stdin, responses and events on stdout, exit on EOF.
@Suite(.serialized)
struct RemoteFileServeCLITests {
  /// One serve process with line-level access to its stdout.
  private final class ServeProcess {
    let process = Process()
    private let input = Pipe()
    private let exited: AsyncStream<Int32>
    private let lines: AsyncStream<Data>
    private let nextID = LockIsolated(0)

    init() throws {
      let executableURL = try #require(Bundle.main.resourceURL?.appending(path: "bin/supacode"))
      try #require(FileManager.default.fileExists(atPath: executableURL.path(percentEncoded: false)))
      let output = Pipe()
      process.executableURL = executableURL
      process.arguments = ["host", "serve"]
      process.standardInput = input
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice

      let (exited, exitContinuation) = AsyncStream<Int32>.makeStream()
      self.exited = exited
      process.terminationHandler = { process in
        exitContinuation.yield(process.terminationStatus)
        exitContinuation.finish()
      }
      let (lines, lineContinuation) = AsyncStream<Data>.makeStream()
      self.lines = lines
      let buffer = LockIsolated(Data())
      output.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else {
          handle.readabilityHandler = nil
          lineContinuation.finish()
          return
        }
        buffer.withValue { pending in
          pending.append(chunk)
          while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            lineContinuation.yield(Data(pending[pending.startIndex..<newline]))
            pending.removeSubrange(pending.startIndex...newline)
          }
        }
      }
      try process.run()
    }

    func send(_ request: (Int) -> RemoteFileRequest) throws -> Int {
      let id = nextID.withValue { value in
        value += 1
        return value
      }
      var line = try RemoteFileWire.encodeLine(request(id))
      line.append(UInt8(ascii: "\n"))
      try input.fileHandleForWriting.write(contentsOf: line)
      return id
    }

    /// The next line that is the response to `id`, skipping events.
    func response<Result: Codable & Sendable>(_ id: Int, as type: Result.Type) async throws -> RemoteFileResponse<
      Result
    > {
      for await line in lines {
        let header = try RemoteFileWire.decode(RemoteFileLineHeader.self, from: line)
        guard header.id == id else { continue }
        return try RemoteFileWire.decode(RemoteFileResponse<Result>.self, from: line)
      }
      throw CancellationError()
    }

    /// The next event line, skipping responses.
    func event() async throws -> RemoteFileEvent {
      for await line in lines {
        let header = try RemoteFileWire.decode(RemoteFileLineHeader.self, from: line)
        guard header.event != nil else { continue }
        return try RemoteFileWire.decode(RemoteFileEvent.self, from: line)
      }
      throw CancellationError()
    }

    func closeInput() throws { try input.fileHandleForWriting.close() }

    func exitStatus() async -> Int32? {
      for await status in exited { return status }
      return nil
    }

    func kill() { if process.isRunning { process.terminate() } }
  }

  @Test(.timeLimit(.minutes(2)))
  func servesRequestsPushesChangesAndExitsOnEOF() async throws {
    let scratch = try RemoteFileScratchDirectory()
    defer { scratch.remove() }
    try scratch.makeFile("readme.txt", contents: "hi")
    let watched = try scratch.makeDirectory("watched")
    let serve = try ServeProcess()
    defer { serve.kill() }

    let hello = try await serve.response(try serve.send { .hello(id: $0) }, as: RemoteFileHelloResult.self)
    #expect(hello.result?.protocolVersion == 1)
    #expect(
      hello.result?.kageVersion == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)

    let list = try await serve.response(
      try serve.send { .list(id: $0, path: scratch.path, showHidden: false) },
      as: RemoteFileListResult.self
    )
    #expect(Set(list.result?.entries.map(\.name) ?? []) == ["readme.txt", "watched"])

    let written = scratch.appending("written.txt")
    let write = try await serve.response(
      try serve.send { .write(id: $0, path: written, data: Data("from viewer".utf8), expectedMtime: nil) },
      as: RemoteFileWriteResult.self
    )
    #expect(write.isSuccess)
    let read = try await serve.response(
      try serve.send { .read(id: $0, path: written, maxBytes: 1024) },
      as: RemoteFileReadResult.self
    )
    #expect(read.result?.data == Data("from viewer".utf8))
    #expect(read.result?.mtime == write.result?.mtime)

    let watch = try await serve.response(
      try serve.send { .watch(id: $0, paths: [watched]) }, as: RemoteFileEmptyResult.self)
    #expect(watch.isSuccess)
    try scratch.makeFile("watched/touched.txt", contents: "x")
    var events: [RemoteFileEvent] = []
    while !events.contains(.changed(paths: [watched])) {
      events.append(try await serve.event())
    }
    #expect(events.contains(.treeChanged(root: watched)))

    try serve.closeInput()
    #expect(await serve.exitStatus() == 0)
  }
}
