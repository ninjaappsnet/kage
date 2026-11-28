import Foundation
import Testing

@testable import supacode

/// Reads a real child process, since what matters is that an unprivileged app
/// gets argv and the start environment back from the kernel. The kernel hides
/// the environment of platform binaries such as `/bin/sleep`, so the children
/// run an ad-hoc signed copy, as the real `claude` binary is not one.
@Suite(.serialized)
struct ClaudeProcessInspectorTests {
  private let marker = "CLAUDE_CODE_KAGE_INSPECTOR_TEST"

  @Test func theArgumentsAndStartEnvironmentOfAChildAreRead() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sleep = try await Self.adHocSleep(named: "sleeper", in: directory)
    let child = try Self.spawn(executable: sleep, arguments: ["30"], environment: [marker: "1"])
    defer { child.terminate() }
    let launch = try #require(ClaudeProcessInspector.launch(pid: child.processIdentifier))
    #expect(launch.arguments == [sleep.path(percentEncoded: false), "30"])
    #expect(launch.environment[marker] == "1")
    #expect(ClaudeProcessInspector.parentPID(of: child.processIdentifier) == getpid())
  }

  @Test func aProcessThatIsGoneReadsAsNothing() {
    #expect(ClaudeProcessInspector.launch(pid: 999_999) == nil)
    #expect(ClaudeProcessInspector.relaunch(pids: [999_999]) == nil)
  }

  @Test func aRunningClaudeIsRelaunchedWithItsSwitchAndExactSession() async throws {
    let directory = try Self.temporaryDirectory()
    let sessions = directory.appending(path: "config/sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // A program named claude, so the inspector takes it for Claude Code.
    let claude = try await Self.adHocSleep(named: "claude", in: directory)
    let child = try Self.spawn(
      executable: claude,
      arguments: ["30"],
      environment: [marker: "1", "CLAUDE_CONFIG_DIR": directory.appending(path: "config").path(percentEncoded: false)]
    )
    defer { child.terminate() }
    let sessionID = "4E7FCB91-BC51-4718-8AA6-9D3E02009AC5"
    try Data(#"{"pid":\#(child.processIdentifier),"sessionId":"\#(sessionID)"}"#.utf8)
      .write(to: sessions.appending(path: "\(child.processIdentifier).json"))

    let relaunch = try #require(ClaudeProcessInspector.relaunch(pids: [child.processIdentifier]))
    #expect(relaunch.command == "\(marker)=1 claude --resume \(sessionID.lowercased())")
  }

  @Test func aProcessThatIsNotClaudeIsNotRelaunched() async throws {
    let directory = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sleep = try await Self.adHocSleep(named: "sleeper", in: directory)
    let child = try Self.spawn(executable: sleep, arguments: ["30"], environment: [:])
    defer { child.terminate() }
    #expect(ClaudeProcessInspector.relaunch(pids: [child.processIdentifier]) == nil)
  }

  private static func temporaryDirectory() throws -> URL {
    let directory = URL(filePath: NSTemporaryDirectory()).appending(path: "kage-inspector-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// A copy of `/bin/sleep` re-signed ad hoc, so it is no longer a platform binary.
  private static func adHocSleep(named name: String, in directory: URL) async throws -> URL {
    let copy = directory.appending(path: name)
    try FileManager.default.copyItem(at: URL(filePath: "/bin/sleep"), to: copy)
    let codesign = Process()
    codesign.executableURL = URL(filePath: "/usr/bin/codesign")
    codesign.arguments = ["--force", "--sign", "-", copy.path(percentEncoded: false)]
    codesign.standardOutput = FileHandle.nullDevice
    codesign.standardError = FileHandle.nullDevice
    // Waits through the termination handler, set before launch, never by blocking.
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      codesign.terminationHandler = { _ in continuation.resume() }
      do { try codesign.run() } catch { continuation.resume(throwing: error) }
    }
    return copy
  }

  private static func spawn(executable: URL, arguments: [String], environment: [String: String]) throws -> Process {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
  }
}
