import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Nonisolated: these run the upload script in a real local `/bin/sh`, and
/// waiting for it on the main actor lets the test host's SwiftUI re-enter.
nonisolated struct RemotePasteUploadTests {
  private static let host = RemoteKageHost(name: "Mini", username: "ahmet", address: "mini.tail.ts.net")

  private static func temporaryDirectory() throws -> URL {
    // Resolved: `/var` is a symlink to `/private/var` and the script prints real paths.
    let url = URL(fileURLWithPath: "/private/tmp").appending(path: "kage-paste-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static var userName: String { NSUserName() }

  /// Runs the script exactly as the host would, with this Mac's `/bin/sh`.
  private static func runScript(name: String, base: URL, data: Data) async throws -> RemotePasteProcess.Result {
    try await RemotePasteProcess.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", RemotePasteUpload.script, RemotePasteUpload.scriptName, name, base.path, "7"],
      input: data
    )
  }

  // MARK: - Invocation

  @Test func invocationRunsTheScriptOverTheSharedConnectionWithoutATTY() throws {
    let invocation = try RemotePasteUpload.invocation(host: Self.host, name: "a-abc123.png").get()
    let expected = SSHCommand.invocation(
      host: RemoteHost(alias: "mini.tail.ts.net", username: "ahmet"),
      executable: "/bin/sh",
      arguments: ["-c", RemotePasteUpload.script, "kage-paste", "a-abc123.png", "/tmp", "7"],
      workingDirectory: nil,
      extraOptions: SSHCommand.backgroundProbeOptions + ["-T"]
    )
    #expect(invocation.executableURL == expected.executableURL)
    #expect(invocation.arguments == expected.arguments)
    #expect(invocation.arguments.contains("ControlMaster=auto"))
    #expect(!invocation.arguments.contains("-tt"))
  }

  @Test func invocationRefusesAnUnsafeHost() {
    let host = RemoteKageHost(name: "Bad", username: "me", address: "-oProxyCommand=x")
    #expect(throws: RemotePasteProblem.invalidHost) {
      try RemotePasteUpload.invocation(host: host, name: "a.png").get()
    }
  }

  // MARK: - Script

  @Test func writesTheFileIntoAnOwnerOnlyFolderAndPrintsItsPath() async throws {
    let base = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }

    let result = try await Self.runScript(name: "shot-abc123.png", base: base, data: Data([1, 2, 3]))

    let folder = base.appending(path: "kage-\(Self.userName)")
    let target = folder.appending(path: "shot-abc123.png")
    #expect(result.status == 0)
    #expect(String(bytes: result.stdout, encoding: .utf8) == target.path + "\n")
    #expect(try Data(contentsOf: target) == Data([1, 2, 3]))
    let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
    let fileMode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
    #expect(folderMode == 0o700)
    #expect(fileMode == 0o600)
    // No partial file is left behind.
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["shot-abc123.png"])
  }

  @Test func deletesPastedFilesOlderThanTheRetention() async throws {
    let base = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let folder = base.appending(path: "kage-\(Self.userName)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let old = folder.appending(path: "old.png")
    let recent = folder.appending(path: "recent.png")
    try Data([0]).write(to: old)
    try Data([0]).write(to: recent)
    try FileManager.default.setAttributes(
      [.modificationDate: Date.now.addingTimeInterval(-10 * 86_400)], ofItemAtPath: old.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date.now.addingTimeInterval(-1 * 86_400)], ofItemAtPath: recent.path)

    let result = try await Self.runScript(name: "new.png", base: base, data: Data([1]))

    #expect(result.status == 0)
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: recent.path))
  }

  @Test func refusesAFolderThatIsASymbolicLink() async throws {
    let base = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let elsewhere = base.appending(path: "elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: base.appending(path: "kage-\(Self.userName)"), withDestinationURL: elsewhere)

    let result = try await Self.runScript(name: "a.png", base: base, data: Data([1]))

    #expect(result.status == 3)
    #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
  }

  @Test(arguments: ["", ".hidden", "a/b.png", "../a.png"])
  func refusesUnsafeNames(_ name: String) async throws {
    let base = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let result = try await Self.runScript(name: name, base: base, data: Data([1]))
    #expect(result.status == 2)
  }

  // MARK: - Outcome

  @Test func acceptsThePrintedPathAfterLoginShellNoise() {
    let output = Data("Welcome!\n/tmp/kage-ahmet/a-abc123.png\n".utf8)
    let result = RemotePasteProcess.Result(status: 0, stdout: output, stderr: Data())
    #expect(
      RemotePasteUpload.remotePath(from: result, name: "a-abc123.png") == .success("/tmp/kage-ahmet/a-abc123.png"))
  }

  @Test func rejectsAPrintedPathForAnotherFile() {
    let result = RemotePasteProcess.Result(status: 0, stdout: Data("/tmp/kage-ahmet/other.png\n".utf8), stderr: Data())
    #expect(
      RemotePasteUpload.remotePath(from: result, name: "a.png")
        == .failure(.uploadFailed("The host answered with an unexpected path.")))
  }

  @Test func rejectsARelativePath() {
    let result = RemotePasteProcess.Result(status: 0, stdout: Data("kage/a.png\n".utf8), stderr: Data())
    #expect(
      RemotePasteUpload.remotePath(from: result, name: "a.png")
        == .failure(.uploadFailed("The host answered with an unexpected path.")))
  }

  @Test func sshFailureMeansUnreachable() {
    let result = RemotePasteProcess.Result(status: 255, stdout: Data(), stderr: Data("ssh: connect: timeout\n".utf8))
    #expect(RemotePasteUpload.remotePath(from: result, name: "a.png") == .failure(.unreachable))
  }

  @Test func scriptFailureCarriesItsMessage() {
    let stderr = Data("noise\nkage-paste: /tmp/kage-ahmet is a symbolic link\n".utf8)
    let result = RemotePasteProcess.Result(status: 3, stdout: Data(), stderr: stderr)
    #expect(
      RemotePasteUpload.remotePath(from: result, name: "a.png")
        == .failure(.uploadFailed("/tmp/kage-ahmet is a symbolic link")))
  }
}
