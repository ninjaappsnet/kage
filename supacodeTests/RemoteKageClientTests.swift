import ComposableArchitecture
import ConcurrencyExtras
import Dependencies
import DependenciesTestSupport
import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

// MARK: - Classifier.

struct RemoteKageCommandResultTests {
  @Test func unresolvableHostIsUnreachable() {
    // Real output: ssh -o BatchMode=yes nobody@kage-agent-test.invalid true
    let result = RemoteKageCommandResult.classify(
      exitCode: 255,
      stdout: "",
      stderr: "ssh: Could not resolve hostname kage-agent-test.invalid: nodename nor servname provided, or not known"
    )
    #expect(
      result
        == .failure(
          .unreachable(
            "Could not resolve hostname kage-agent-test.invalid: nodename nor servname provided, or not known")
        ))
  }

  @Test func refusedConnectionIsUnreachable() {
    // Real output: ssh -p 1 nobody@127.0.0.1 true
    let result = RemoteKageCommandResult.classify(
      exitCode: 255, stdout: "", stderr: "ssh: connect to host 127.0.0.1 port 1: Connection refused")
    #expect(result == .failure(.unreachable("connect to host 127.0.0.1 port 1: Connection refused")))
  }

  @Test func deniedLoginIsUnreachable() {
    let result = RemoteKageCommandResult.classify(
      exitCode: 255, stdout: "", stderr: "ahmet@mini.example: Permission denied (publickey,password).")
    #expect(result == .failure(.unreachable("ahmet@mini.example: Permission denied (publickey,password).")))
  }

  @Test func oldHostCLIRejectingTheHostSubcommandNeedsUpdate() {
    // Real output of `supacode host snapshot` on the mini's pre-snapshot build (exit 64).
    let result = RemoteKageCommandResult.classify(
      exitCode: 64,
      stdout: "",
      stderr: """
        Error: 2 unexpected arguments: 'host', 'snapshot'
        Usage: supacode open [--timeout <timeout>]
          See 'supacode open --help' for more information.
        """
    )
    #expect(result == .failure(.needsUpdate))
  }

  @Test func oldHostAppRejectingTheResourceNeedsUpdate() {
    let result = RemoteKageCommandResult.classify(
      exitCode: 1, stdout: "", stderr: "Error: Unknown resource: host-snapshot")
    #expect(result == .failure(.needsUpdate))
  }

  @Test(arguments: [
    (Int32(69), "Error: Kage isn't running."),
    (Int32(1), "Error: Kage isn't running."),
    (Int32(1), "Waiting for Kage to start...\nError: Timed out waiting for Kage to start."),
    (Int32(1), "Error: Unable to find application named 'Kage'"),
    (Int32(1), "Error: Failed to connect to socket at /tmp/supacode-501/pid-42: Connection refused"),
  ])
  func missingKageSocketIsKageNotRunning(exitCode: Int32, stderr: String) {
    let result = RemoteKageCommandResult.classify(exitCode: exitCode, stdout: "", stderr: stderr)
    #expect(result == .failure(.kageNotRunning))
  }

  @Test func missingCLIIsNotInstalled() {
    // Real output of a missing CLI path through the login shell (exit 127).
    let result = RemoteKageCommandResult.classify(
      exitCode: 127,
      stdout: "",
      stderr: "zsh:1: no such file or directory: /Applications/Kage.app/Contents/Resources/bin/supacode"
    )
    #expect(result == .failure(.commandFailed("Kage isn't installed at /Applications on the host.")))
  }

  @Test func otherFailuresReportTheirLastLine() {
    let result = RemoteKageCommandResult.classify(
      exitCode: 1, stdout: "", stderr: "Waiting...\nError: No tab is focused in this worktree.")
    #expect(result == .failure(.commandFailed("No tab is focused in this worktree.")))
  }

  @Test func silentFailuresReportTheExitCode() {
    let result = RemoteKageCommandResult.classify(exitCode: 3, stdout: "", stderr: "")
    #expect(result == .failure(.commandFailed("The host command failed (exit 3).")))
  }

  @Test func successReturnsStdout() {
    #expect(RemoteKageCommandResult.classify(exitCode: 0, stdout: "ok", stderr: "noise") == .success("ok"))
  }

  @Test func decodesASnapshot() throws {
    let snapshot = RemoteKagePollingFixtures.snapshot(tabs: [RemoteKagePollingFixtures.tab("t1")])
    let json = try #require(String(bytes: try JSONEncoder().encode(snapshot), encoding: .utf8))
    #expect(RemoteKageCommandResult.decodeSnapshot(json) == .success(snapshot))
  }

  @Test func decodesASnapshotAfterLoginShellNoise() throws {
    let snapshot = RemoteKagePollingFixtures.snapshot(tabs: [])
    let json = try #require(String(bytes: try JSONEncoder().encode(snapshot), encoding: .utf8))
    #expect(RemoteKageCommandResult.decodeSnapshot("Welcome to the mini!\n" + json + "\n") == .success(snapshot))
  }

  @Test func decodesANewerSchemaWithUnknownFields() {
    let json = """
      {"schemaVersion": 2, "kageVersion": "9.0", "machineName": "Mini", "futureField": [1, 2],
       "workspaces": [], "repositories": []}
      """
    let result = RemoteKageCommandResult.decodeSnapshot(json)
    #expect((try? result.get())?.schemaVersion == 2)
  }

  @Test func undecodableNewerSchemaAsksToUpdateThisMac() {
    let result = RemoteKageCommandResult.decodeSnapshot(#"{"schemaVersion": 7, "kageVersion": 1}"#)
    #expect(result == .failure(.commandFailed("The host's Kage is newer than this Mac's. Update Kage on this Mac.")))
  }

  @Test func garbageIsACommandFailure() {
    let result = RemoteKageCommandResult.decodeSnapshot("not json")
    #expect(result == .failure(.commandFailed("The host answered with something that isn't a Kage snapshot.")))
  }

  @Test func screenTextDropsTrailingBlankLinesOnly() {
    let text = RemoteKageCommandResult.screenText(lines: ["", "  1. Yes", "  2. No", "", "   ", ""])
    #expect(text == "\n  1. Yes\n  2. No")
  }
}

// MARK: - Command lines.

struct RemoteKageCommandTests {
  @Test func remoteHostSharesTheSSHDestination() {
    let host = RemoteKageHost(name: "Mini", username: "ahmet", address: "mini.example")
    #expect(host.remoteHost == RemoteHost(alias: "mini.example", username: "ahmet"))
    #expect(host.remoteHost.sshDestination == host.sshDestination)
  }

  @Test func newTabEncodesTheWorktreeIDAndStaysInTheBackground() {
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    #expect(
      RemoteKageCommand.newTabArguments(worktreeID: "/Users/a b/repo", tabID: id, command: "claude") == [
        "tab", "new", "-w", "%2FUsers%2Fa%20b%2Frepo", "--id", "11111111-2222-3333-4444-555555555555",
        "--background", "--input=claude",
      ])
    // `--input=` keeps a command that starts with "-" from parsing as an option.
    #expect(RemoteKageCommand.newTabArguments(worktreeID: "w", tabID: id, command: "-x").last == "--input=-x")
    #expect(RemoteKageCommand.newTabArguments(worktreeID: "w", tabID: id, command: nil).last == "--background")
  }

  @Test func rejectsDestinationsThatCouldBecomeSSHOptions() {
    #expect(RemoteKageCommand.isSafe(RemoteKageHost(name: "a", username: "ahmet", address: "mini.example")))
    #expect(!RemoteKageCommand.isSafe(RemoteKageHost(name: "a", username: "ahmet", address: "-oProxyCommand=x")))
    #expect(!RemoteKageCommand.isSafe(RemoteKageHost(name: "a", username: "-l", address: "mini")))
    #expect(!RemoteKageCommand.isSafe(RemoteKageHost(name: "a", username: "ahmet", address: "mini example")))
    #expect(!RemoteKageCommand.isSafe(RemoteKageHost(name: "a", username: "ahmet", address: "")))
  }
}

// MARK: - Live client over a recorded shell.

struct RemoteKageLiveClientTests {
  private let host = RemoteKagePollingFixtures.host
  private let zmx = "/Applications/Kage.app/Contents/Resources/zmx/zmx"

  private static func expectedRemoteLine(_ executable: String, _ arguments: [String]) -> String {
    SSHCommand.loginShellWrapped(
      SSHCommand.remoteCommand(executable: executable, arguments: arguments, workingDirectory: nil))
  }

  private static func recordingShell(
    _ calls: LockIsolated<[[String]]>,
    output: @escaping @Sendable () throws -> ShellOutput
  ) -> ShellClient {
    ShellClient(
      run: { url, arguments, _ in
        calls.withValue { $0.append([url.path(percentEncoded: false)] + arguments) }
        return try output()
      },
      runLoginImpl: { _, _, _, _ in
        Issue.record("The remote client must not wrap ssh in a local login shell.")
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
  }

  @Test(.dependencies) func snapshotRunsTheHostCLIOverSSH() async throws {
    let snapshot = RemoteKagePollingFixtures.snapshot(tabs: [RemoteKagePollingFixtures.tab("t1")])
    let json = try #require(String(bytes: try JSONEncoder().encode(snapshot), encoding: .utf8))
    let calls = LockIsolated<[[String]]>([])
    let shell = Self.recordingShell(calls) { ShellOutput(stdout: json, stderr: "", exitCode: 0) }
    let result = try await withDependencies {
      $0.shellClient = shell
      $0.continuousClock = TestClock()
    } operation: {
      try await RemoteKageClient.liveValue.snapshot(host)
    }
    #expect(result == snapshot)
    let call = try #require(calls.value.first)
    #expect(call.first == "/usr/bin/ssh")
    #expect(call.contains("BatchMode=yes"))
    #expect(call.contains("ControlPath=~/.ssh/supacode-%C"))
    #expect(call.dropLast().last == "ahmet@mini.example")
    #expect(call.last == Self.expectedRemoteLine(RemoteKageCommand.defaultCLIPath, ["host", "snapshot"]))
  }

  @Test(.dependencies) func failedSnapshotIsClassified() async {
    let calls = LockIsolated<[[String]]>([])
    let shell = Self.recordingShell(calls) {
      throw ShellClientError(
        command: "ssh", stdout: "", stderr: "Error: 2 unexpected arguments: 'host', 'snapshot'", exitCode: 64)
    }
    await #expect(throws: RemoteKageError.needsUpdate) {
      try await withDependencies {
        $0.shellClient = shell
        $0.continuousClock = TestClock()
      } operation: {
        _ = try await RemoteKageClient.liveValue.snapshot(host)
      }
    }
  }

  @Test(.dependencies) func unsafeHostNeverRunsSSH() async {
    let calls = LockIsolated<[[String]]>([])
    let shell = Self.recordingShell(calls) { ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    let unsafe = RemoteKageHost(name: "Bad", username: "ahmet", address: "-oProxyCommand=touch /tmp/x")
    await #expect(throws: RemoteKageError.self) {
      try await withDependencies {
        $0.shellClient = shell
        $0.continuousClock = TestClock()
      } operation: {
        _ = try await RemoteKageClient.liveValue.snapshot(unsafe)
      }
    }
    #expect(calls.value.isEmpty)
  }

  @Test(.dependencies) func screenKeepsLeadingWhitespaceAndDropsTrailingBlankLines() async throws {
    let calls = LockIsolated<[[String]]>([])
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runStream: { url, arguments, _ in
        calls.withValue { $0.append([url.path(percentEncoded: false)] + arguments) }
        return AsyncThrowingStream { continuation in
          for line in ["", "  Do you want to proceed?", "  1. Yes", "", ""] {
            continuation.yield(.line(ShellStreamLine(source: .stdout, text: line)))
          }
          continuation.yield(.finished(ShellOutput(stdout: "trimmed", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      }
    )
    let screen = try await withDependencies {
      $0.shellClient = shell
      $0.continuousClock = TestClock()
    } operation: {
      try await RemoteKageClient.liveValue.screen(host, zmx, "supa-t1")
    }
    #expect(screen == "\n  Do you want to proceed?\n  1. Yes")
    #expect(calls.value.first?.last == Self.expectedRemoteLine(zmx, ["history", "supa-t1", "--screen"]))
  }

  @Test(.dependencies) func sendTypesTheTextVerbatim() async throws {
    let calls = LockIsolated<[[String]]>([])
    let shell = Self.recordingShell(calls) { ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    try await withDependencies {
      $0.shellClient = shell
      $0.continuousClock = TestClock()
    } operation: {
      try await RemoteKageClient.liveValue.send(host, zmx, "supa-t1", "1\r")
    }
    #expect(calls.value.first?.last == Self.expectedRemoteLine(zmx, ["send", "supa-t1", "1\r"]))
  }

  @Test(.dependencies) func newTabRunsTheHostCLI() async throws {
    let calls = LockIsolated<[[String]]>([])
    let shell = Self.recordingShell(calls) { ShellOutput(stdout: "ID", stderr: "", exitCode: 0) }
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    try await withDependencies {
      $0.shellClient = shell
      $0.continuousClock = TestClock()
    } operation: {
      try await RemoteKageClient.liveValue.newTab(host, "/opt/kage/bin/supacode", "/Users/a/repo", id, nil)
    }
    #expect(
      calls.value.first?.last
        == Self.expectedRemoteLine(
          "/opt/kage/bin/supacode",
          RemoteKageCommand.newTabArguments(worktreeID: "/Users/a/repo", tabID: id, command: nil)))
  }

  @Test(.dependencies) func hungHostTimesOut() async {
    let clock = TestClock()
    let shell = ShellClient(
      run: { _, _, _ in
        try await clock.sleep(for: .seconds(3600))
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let host = self.host
    let task = Task {
      try await withDependencies {
        $0.shellClient = shell
        $0.continuousClock = clock
      } operation: {
        try await RemoteKageClient.liveValue.snapshot(host)
      }
    }
    await Task.megaYield()
    await clock.advance(by: RemoteKageCommand.snapshotTimeout)
    let result = await task.result
    #expect(throws: RemoteKageError.unreachable("The host didn't answer within 20 seconds.")) {
      try result.get()
    }
  }
}
