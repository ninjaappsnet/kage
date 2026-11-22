import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// The CLI is a separate product with no test target, so a subprocess against
/// a stub socket server is the way to cover `host snapshot` and the `kage`
/// invocation name.
@MainActor
@Suite(.serialized)
struct HostSnapshotCLITests {
  @Test(.timeLimit(.minutes(3)))
  func hostSnapshotPrintsTheJSONRowVerbatim() async throws {
    let directory = "/tmp/supacode-cli-\(UUID().uuidString)"
    let socketPath = "\(directory)/pid-1"
    let server = AgentHookSocketServer(socketPathOverride: socketPath)
    defer {
      server.shutdown()
      try? FileManager.default.removeItem(atPath: directory)
    }
    try #require(server.socketPath == socketPath)
    let resource = LockIsolated<String?>(nil)
    let snapshot = "{\"schemaVersion\":1,\"repositories\":[]}"
    server.onQuery = { name, _, clientFD in
      resource.setValue(name)
      AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: [["json": snapshot]])
    }

    let run = try await Self.runCLI(
      arguments: ["host", "snapshot", "--timeout", "30"],
      environment: ["SUPACODE_SOCKET_PATH": socketPath]
    )

    #expect(run.exitCode == 0, "CLI failed: \(run.standardError)")
    #expect(resource.value == "host-snapshot")
    #expect(run.standardOutput == snapshot + "\n")
  }

  @Test(.timeLimit(.minutes(3)))
  func helpShowsTheNameTheCLIWasInvokedAs() async throws {
    let kage = try await Self.runCLI(arguments: ["--help"], environment: [:], invokedAs: "kage")
    #expect(kage.exitCode == 0, "CLI failed: \(kage.standardError)")
    #expect(kage.standardOutput.contains("USAGE: kage"))
    #expect(kage.standardOutput.contains("host"))

    let supacode = try await Self.runCLI(arguments: ["--help"], environment: [:], invokedAs: "supacode")
    #expect(supacode.standardOutput.contains("USAGE: supacode"))
  }

  // MARK: - Helpers.

  private struct Run {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32
  }

  /// Runs the bundled CLI through a symlink named `invokedAs` so argv[0] carries that name.
  private static func runCLI(
    arguments: [String],
    environment: [String: String],
    invokedAs name: String = "supacode"
  ) async throws -> Run {
    let bundled = try #require(Bundle.main.resourceURL?.appending(path: "bin/supacode"))
    try #require(FileManager.default.fileExists(atPath: bundled.path(percentEncoded: false)))
    let linkDirectory = URL(filePath: "/tmp/supacode-cli-link-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: linkDirectory) }
    let link = linkDirectory.appending(path: name)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundled)

    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = link
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(
      environment,
      uniquingKeysWith: { _, fixture in fixture }
    )
    process.standardOutput = output
    process.standardError = error

    try await process.runToExit()

    return Run(
      standardOutput: String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      standardError: String(bytes: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      exitCode: process.terminationStatus
    )
  }
}
