import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// The host side of `kage host serve` against a real scratch directory.
@Suite(.serialized)
nonisolated struct RemoteFileRequestHandlerTests {
  private let handler = RemoteFileRequestHandler(kageVersion: "9.9.9")

  @Test func helloReportsProtocolAndKageVersions() {
    #expect(handler.hello() == RemoteFileHelloResult(protocolVersion: 1, kageVersion: "9.9.9"))
  }

  @Test func listReportsKindsSizesAndSymlinkTargets() throws {
    let scratch = try RemoteFileScratchDirectory()
    defer { scratch.remove() }
    let file = try scratch.makeFile("a.txt", contents: "hello")
    try scratch.makeDirectory("sub")
    try scratch.makeFile(".hidden", contents: "x")
    try FileManager.default.createSymbolicLink(atPath: scratch.appending("link"), withDestinationPath: "a.txt")
    try FileManager.default.createSymbolicLink(atPath: scratch.appending("dlink"), withDestinationPath: "sub")
    try FileManager.default.createSymbolicLink(atPath: scratch.appending("broken"), withDestinationPath: "missing")

    let visible = try handler.list(path: scratch.path, showHidden: false)
    let byName = Dictionary(uniqueKeysWithValues: visible.entries.map { ($0.name, $0) })
    #expect(Set(byName.keys) == ["a.txt", "sub", "link", "dlink", "broken"])
    #expect(byName["a.txt"]?.kind == .file)
    #expect(byName["a.txt"]?.size == 5)
    #expect(byName["a.txt"]?.mtime == (try RemoteFileScratchDirectory.mtime(of: file)))
    #expect(byName["a.txt"]?.targetKind == nil)
    #expect(byName["sub"]?.kind == .dir)
    #expect(byName["link"]?.kind == .symlink)
    #expect(byName["link"]?.targetKind == .file)
    #expect(byName["dlink"]?.targetKind == .dir)
    #expect(byName["broken"]?.kind == .symlink)
    #expect(byName["broken"]?.targetKind == nil)

    let all = try handler.list(path: scratch.path, showHidden: true)
    #expect(all.entries.map(\.name).contains(".hidden"))
    #expect(!all.entries.map(\.name).contains("."))
    #expect(!all.entries.map(\.name).contains(".."))
  }

  @Test func pathErrorsMapToProtocolCodes() throws {
    let scratch = try RemoteFileScratchDirectory()
    defer { scratch.remove() }
    #expect(Self.code { try handler.list(path: scratch.appending("missing"), showHidden: false) } == .notFound)
    #expect(Self.code { try handler.stat(path: scratch.appending("missing")) } == .notFound)
    #expect(Self.code { try handler.stat(path: "relative/path") } == .badRequest)
    let locked = try scratch.makeDirectory("locked")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
    #expect(Self.code { try handler.list(path: locked, showHidden: false) } == .permission)
  }

  @Test func statFollowsSymlinks() throws {
    let scratch = try RemoteFileScratchDirectory()
    defer { scratch.remove() }
    let file = try scratch.makeFile("a.txt", contents: "abc")
    try FileManager.default.createSymbolicLink(atPath: scratch.appending("link"), withDestinationPath: "a.txt")

    let result = try handler.stat(path: scratch.appending("link"))
    #expect(result == RemoteFileStatResult(kind: .file, size: 3, mtime: try RemoteFileScratchDirectory.mtime(of: file)))
    #expect(try handler.stat(path: scratch.path).kind == .dir)
  }

  @Test func readReturnsContentsAndRefusesLargeFilesWithoutOpeningThem() throws {
    let scratch = try RemoteFileScratchDirectory()
    defer { scratch.remove() }
    let file = try scratch.makeFile("a.txt", contents: "hello world")

    let result = try handler.read(path: file, maxBytes: 100)
    #expect(result.data == Data("hello world".utf8))
    #expect(result.size == 11)
    #expect(result.mtime == (try RemoteFileScratchDirectory.mtime(of: file)))

    do {
      _ = try handler.read(path: file, maxBytes: 5)
      Issue.record("expected tooLarge")
    } catch {
      #expect(error.code == .tooLarge)
      #expect(error.size == 11)
    }

    // An unreadable file over the limit still answers tooLarge, so the size
    // check happens before any open.
    let locked = try scratch.makeFile("locked.bin", contents: String(repeating: "x", count: 64), mode: 0)
    #expect(Self.code { try handler.read(path: locked, maxBytes: 10) } == .tooLarge)
    #expect(Self.code { try handler.read(path: locked, maxBytes: 1000) } == .permission)
    #expect(Self.code { try handler.read(path: scratch.path, maxBytes: 1000) } == .badRequest)
  }

  @Test func writeCreatesAndReplacesAtomicallyKeepingTheMode() throws {
    let scratch = try RemoteFileScratchDirectory()
    defer { scratch.remove() }

    let created = scratch.appending("new/deep.txt")
    let first = try handler.write(path: created, data: Data("one".utf8), expectedMtime: nil)
    #expect(try String(contentsOfFile: created, encoding: .utf8) == "one")
    #expect(first.mtime == (try RemoteFileScratchDirectory.mtime(of: created)))

    let script = try scratch.makeFile("run.sh", contents: "echo 1", mode: 0o755)
    let mtime = try RemoteFileScratchDirectory.mtime(of: script)
    _ = try handler.write(path: script, data: Data("echo 2".utf8), expectedMtime: mtime)
    #expect(try String(contentsOfFile: script, encoding: .utf8) == "echo 2")
    let mode = try FileManager.default.attributesOfItem(atPath: script)[.posixPermissions] as? Int
    #expect(mode == 0o755)
    // No temp file is left behind.
    let names = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
    #expect(Set(names) == ["new", "run.sh"])
  }

  @Test func writeRefusesAStaleOrVanishedExpectedMtime() throws {
    let scratch = try RemoteFileScratchDirectory()
    defer { scratch.remove() }
    let file = try scratch.makeFile("a.txt", contents: "disk")
    let current = try RemoteFileScratchDirectory.mtime(of: file)

    do {
      _ = try handler.write(path: file, data: Data("mine".utf8), expectedMtime: current - 5000)
      Issue.record("expected conflict")
    } catch {
      #expect(error.code == .conflict)
      #expect(error.mtime == current)
    }
    #expect(try String(contentsOfFile: file, encoding: .utf8) == "disk")

    do {
      _ = try handler.write(path: scratch.appending("gone.txt"), data: Data("x".utf8), expectedMtime: current)
      Issue.record("expected conflict")
    } catch {
      #expect(error.code == .conflict)
      #expect(error.mtime == nil)
    }
    #expect(!FileManager.default.fileExists(atPath: scratch.appending("gone.txt")))
  }

  @Test func writeGoesThroughASymlinkAndKeepsTheLink() throws {
    let scratch = try RemoteFileScratchDirectory()
    defer { scratch.remove() }
    let target = try scratch.makeFile("real/target.txt", contents: "old")
    let link = scratch.appending("link.txt")
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "real/target.txt")

    let result = try handler.write(path: link, data: Data("new".utf8), expectedMtime: nil)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "real/target.txt")
    #expect(try String(contentsOfFile: target, encoding: .utf8) == "new")
    #expect(result.mtime == (try RemoteFileScratchDirectory.mtime(of: target)))
  }

  @Test(.timeLimit(.minutes(1)))
  func gitStatusReturnsRawPorcelainOrNotGit() async throws {
    let scratch = try RemoteFileScratchDirectory()
    defer { scratch.remove() }
    let repository = try scratch.makeDirectory("repo")
    let initProcess = Process()
    initProcess.executableURL = URL(filePath: "/usr/bin/git")
    initProcess.arguments = ["init", "-q", repository]
    try await initProcess.runToExit()
    #expect(initProcess.terminationStatus == 0)
    try scratch.makeFile("repo/new file.txt", contents: "x")
    let plain = try scratch.makeDirectory("plain")

    let handler = handler
    let status = try await Task.detached { try handler.gitStatus(root: repository) }.value
    #expect(status.porcelain == "?? new file.txt\u{0}")

    let notGit = await Task.detached { () -> RemoteFileErrorCode? in
      do {
        _ = try handler.gitStatus(root: plain)
        return nil
      } catch {
        return (error as? RemoteFileError)?.code
      }
    }.value
    #expect(notGit == .notGit)
  }

  @Test func respondEncodesSuccessAndErrorLines() throws {
    let scratch = try RemoteFileScratchDirectory()
    defer { scratch.remove() }
    let file = try scratch.makeFile("a.txt", contents: "hi")

    let success = handler.respond(to: .read(id: 4, path: file, maxBytes: 10))
    let decoded = try RemoteFileWire.decode(RemoteFileResponse<RemoteFileReadResult>.self, from: success)
    #expect(decoded.id == 4)
    #expect(decoded.isSuccess)
    #expect(decoded.result?.data == Data("hi".utf8))

    let failure = handler.respond(to: RemoteFileRequest(id: 5, operation: .read, path: file))
    let error = try RemoteFileWire.decode(RemoteFileResponse<RemoteFileEmptyResult>.self, from: failure)
    #expect(error.id == 5)
    #expect(!error.isSuccess)
    #expect(error.error?.code == .badRequest)
  }

  /// The protocol error code `body` fails with, or `nil` when it succeeds.
  private static func code(_ body: () throws -> some Any) -> RemoteFileErrorCode? {
    do {
      _ = try body()
      return nil
    } catch {
      return (error as? RemoteFileError)?.code
    }
  }
}
