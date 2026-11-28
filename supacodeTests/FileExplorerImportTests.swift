import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

private nonisolated func trimmedPath(_ url: URL) -> String {
  var path = url.path(percentEncoded: false)
  while path.count > 1, path.hasSuffix("/") { path.removeLast() }
  return path
}

/// Where a drop or paste lands in the explorer.
struct FileExplorerImportTargetTests {
  private let root = URL(filePath: "/repo", directoryHint: .isDirectory)

  @Test func aFolderRowTakesTheItemsItself() {
    let folder = FileExplorerNode(
      url: URL(filePath: "/repo/sub", directoryHint: .isDirectory), name: "sub", isDirectory: true)
    #expect(trimmedPath(FileExplorerImportTarget.directory(onto: folder, root: root)) == "/repo/sub")
  }

  @Test func aFileRowHandsThemToItsFolder() {
    let file = FileExplorerNode(url: URL(filePath: "/repo/sub/a.txt"), name: "a.txt", isDirectory: false)
    #expect(trimmedPath(FileExplorerImportTarget.directory(onto: file, root: root)) == "/repo/sub")
  }

  @Test func emptySpaceMeansTheRoot() {
    #expect(trimmedPath(FileExplorerImportTarget.directory(onto: nil, root: root)) == "/repo")
  }

  @Test func onlyFileURLsAreImported() {
    let file = URL(filePath: "/Users/me/a.txt")
    #expect(FileExplorerImportTarget.importable([file, URL(string: "https://example.com/a.txt")!]) == [file])
  }
}

/// Copies into this Mac's disk: never a move, never an overwrite.
nonisolated struct FileExplorerLocalImportTests {
  private static func temporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: "/private/tmp").appending(path: "kage-import-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private static func read(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).flatMap { String(bytes: $0, encoding: .utf8) }
  }

  @Test func copiesAFileAndKeepsTheOriginal() async throws {
    let base = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appending(path: "from/a.txt")
    try Self.write("hello", to: source)
    let destination = base.appending(path: "to")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    let landed = try await FileExplorerImporter.local.importItems([source], destination)

    #expect(landed == ["a.txt"])
    #expect(Self.read(destination.appending(path: "a.txt")) == "hello")
    #expect(Self.read(source) == "hello")
  }

  @Test func aTakenNameLandsAsACopyAndTheExistingFileIsUntouched() async throws {
    let base = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appending(path: "from/a.txt")
    try Self.write("new", to: source)
    let destination = base.appending(path: "to")
    try Self.write("old", to: destination.appending(path: "a.txt"))

    let landed = try await FileExplorerImporter.local.importItems([source, source], destination)

    #expect(landed == ["a copy.txt", "a copy 2.txt"])
    #expect(Self.read(destination.appending(path: "a.txt")) == "old")
    #expect(Self.read(destination.appending(path: "a copy.txt")) == "new")
  }

  @Test func copiesAFolderWithEverythingInIt() async throws {
    let base = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    try Self.write("deep", to: base.appending(path: "from/pkg/inner/leaf.txt"))
    try Self.write("x", to: base.appending(path: "from/pkg/.env"))
    let destination = base.appending(path: "to")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    let landed = try await FileExplorerImporter.local.importItems([base.appending(path: "from/pkg")], destination)

    #expect(landed == ["pkg"])
    #expect(Self.read(destination.appending(path: "pkg/inner/leaf.txt")) == "deep")
    #expect(Self.read(destination.appending(path: "pkg/.env")) == "x")
  }

  @Test func refusesToCopyAFolderIntoItself() async throws {
    let base = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    try Self.write("a", to: base.appending(path: "pkg/sub/a.txt"))

    await #expect(throws: FileExplorerImportError.self) {
      try await FileExplorerImporter.local.importItems([base.appending(path: "pkg")], base.appending(path: "pkg/sub"))
    }
  }
}

/// The remote copy: `tar` on this Mac streamed into a script on the host.
/// Run here end to end with this Mac's `/bin/sh` standing in for ssh.
nonisolated struct RemoteFileImportTests {
  private static let host = RemoteKageHost(name: "Mini", username: "ahmet", address: "mini.tail.ts.net")

  private static func temporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: "/private/tmp").appending(path: "kage-remote-import-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private static func read(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).flatMap { String(bytes: $0, encoding: .utf8) }
  }

  /// The real pipeline, with the host's side run locally instead of over ssh.
  private static func importLocally(_ source: URL, into directory: URL) async throws -> Result<
    String, RemoteFileImportProblem
  > {
    let receiver = RemoteFileImport.receiverArguments(directory: directory.path, name: source.lastPathComponent)
    let pipeline = RemoteFileImport.pipeline(source: source, receiver: receiver)
    let result = try await RemotePasteProcess.run(
      executableURL: pipeline.executableURL, arguments: pipeline.arguments, input: Data())
    return RemoteFileImport.landedName(from: result)
  }

  @Test func aFileArrivesUnderItsName() async throws {
    let base = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appending(path: "from/notes.md")
    try Self.write("# hi", to: source)
    let destination = base.appending(path: "to")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    #expect(try await Self.importLocally(source, into: destination) == .success("notes.md"))
    #expect(Self.read(destination.appending(path: "notes.md")) == "# hi")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.path)
    #expect(leftovers == ["notes.md"])
  }

  @Test func aTakenNameLandsAsACopyLikeFinder() async throws {
    let base = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appending(path: "from/a.txt")
    try Self.write("new", to: source)
    let destination = base.appending(path: "to")
    try Self.write("old", to: destination.appending(path: "a.txt"))

    #expect(try await Self.importLocally(source, into: destination) == .success("a copy.txt"))
    #expect(try await Self.importLocally(source, into: destination) == .success("a copy 2.txt"))
    #expect(Self.read(destination.appending(path: "a.txt")) == "old")
    #expect(Self.read(destination.appending(path: "a copy 2.txt")) == "new")
  }

  @Test func aFolderArrivesWithEverythingInItAndNoAppleDoubleFiles() async throws {
    let base = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    try Self.write("deep", to: base.appending(path: "from/my pkg/inner/leaf.txt"))
    try Self.write("x", to: base.appending(path: "from/my pkg/.env"))
    let destination = base.appending(path: "to")
    try Self.write("taken", to: destination.appending(path: "my pkg/old.txt"))

    #expect(
      try await Self.importLocally(base.appending(path: "from/my pkg"), into: destination) == .success("my pkg copy"))
    #expect(Self.read(destination.appending(path: "my pkg copy/inner/leaf.txt")) == "deep")
    #expect(Self.read(destination.appending(path: "my pkg copy/.env")) == "x")
    let all = FileManager.default.subpaths(atPath: destination.path) ?? []
    #expect(!all.contains { ($0 as NSString).lastPathComponent.hasPrefix("._") })
    #expect(!all.contains { $0.contains(".kage-import") })
  }

  @Test func aNameStartingWithADashIsJustAName() async throws {
    let base = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appending(path: "from/-rf")
    try Self.write("dash", to: source)
    let destination = base.appending(path: "to")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    #expect(try await Self.importLocally(source, into: destination) == .success("-rf"))
    #expect(Self.read(destination.appending(path: "-rf")) == "dash")
  }

  @Test func aMissingDestinationFailsWithTheHostsReason() async throws {
    let base = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appending(path: "a.txt")
    try Self.write("a", to: source)

    let result = try await Self.importLocally(source, into: base.appending(path: "nope"))
    guard case .failure(.importFailed(let message)) = result else {
      Issue.record("Expected a failure, got \(result)")
      return
    }
    #expect(message.contains("nope"))
  }

  @Test func sshExit255IsUnreachable() {
    let result = RemotePasteProcess.Result(status: 255, stdout: Data(), stderr: Data("timeout".utf8))
    #expect(RemoteFileImport.landedName(from: result) == .failure(.unreachable))
  }

  @Test func theHostSideRunsOverTheSharedConnectionWithoutATTY() throws {
    let source = URL(filePath: "/Users/me/Desktop/shot.png")
    let invocation = try RemoteFileImport.invocation(host: Self.host, source: source, directory: "/Users/ahmet/repo")
      .get()
    let ssh = SSHCommand.invocation(
      host: RemoteHost(alias: "mini.tail.ts.net", username: "ahmet"),
      executable: "/bin/sh",
      arguments: RemoteFileImport.receiverArguments(directory: "/Users/ahmet/repo", name: "shot.png").dropFirst().map {
        $0
      },
      workingDirectory: nil,
      extraOptions: SSHCommand.backgroundProbeOptions + ["-T"]
    )
    #expect(invocation == RemoteFileImport.pipeline(source: source, receiver: [ssh.executableURL.path] + ssh.arguments))
    #expect(invocation.arguments.contains("ControlMaster=auto"))
  }

  @Test func anUnsafeHostIsRefused() {
    let host = RemoteKageHost(name: "Bad", username: "me", address: "-oProxyCommand=x")
    #expect(throws: RemoteFileImportProblem.invalidHost) {
      try RemoteFileImport.invocation(host: host, source: URL(filePath: "/a"), directory: "/b").get()
    }
  }
}

/// The panel's import state: what is copying, and why a copy failed.
@MainActor
struct FileExplorerImportModelTests {
  private let root = URL(filePath: "/repo", directoryHint: .isDirectory)

  @Test func copiesIntoTheTargetThenRefreshes() async {
    let calls = LockIsolatedBox<[(sources: [URL], directory: String)]>([])
    let importer = FileExplorerImporter { sources, directory in
      calls.withValue { $0.append((sources, trimmedPath(directory))) }
      return sources.map(\.lastPathComponent)
    }
    let model = FileExplorerImportModel(importer: importer)
    var refreshed = 0
    let file = URL(filePath: "/Users/me/a.txt")

    await model.importItems([file, URL(string: "https://x.y/z")!], into: root) { refreshed += 1 }

    #expect(calls.value.count == 1)
    #expect(calls.value.first?.sources == [file])
    #expect(calls.value.first?.directory == "/repo")
    #expect(refreshed == 1)
    #expect(model.status == nil)
    #expect(!model.isImporting)
  }

  @Test func aFailureIsShownUntilDismissed() async {
    let importer = FileExplorerImporter { _, _ in throw FileExplorerImportError("The host said no.") }
    let model = FileExplorerImportModel(importer: importer)

    await model.importItems([URL(filePath: "/a.txt")], into: root) {}

    #expect(model.status == .failed("The host said no."))
    model.dismissStatus()
    #expect(model.status == nil)
  }

  @Test func nothingImportableDoesNothing() async {
    let model = FileExplorerImportModel(
      importer: FileExplorerImporter { _, _ in
        Issue.record("Should not import")
        return []
      })
    await model.importItems([URL(string: "https://x.y/z")!], into: root) {}
    #expect(model.status == nil)
  }
}

/// A tiny lock box for recording calls from a Sendable closure.
final nonisolated class LockIsolatedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value { lock.withLock { stored } }
  func withValue(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
