import ComposableArchitecture
import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

// MARK: - The host's `host-claude-tab` request.

struct HostClaudeTabRequestTests {
  private let tabID = UUID(7)

  @Test func anAssignmentNamesTheTabAndTheAccount() {
    #expect(
      HostClaudeTabRequest.parse(["action": "assign", "tabID": tabID.uuidString, "accountID": "work"])
        == .success(.assign(tabID: tabID, accountID: "work")))
  }

  @Test func aRestartNamesTheWorktreeAsTheCLIEncodesIt() {
    #expect(
      HostClaudeTabRequest.parse([
        "action": "restart", "worktreeID": "%2Ftmp%2Frepo%2Ffeature", "tabID": tabID.uuidString, "accountID": "work",
      ]) == .success(.restart(worktreeID: "/tmp/repo/feature", tabID: tabID, accountID: "work")))
  }

  @Test func malformedRequestsAreRefusedWithAReason() {
    #expect(HostClaudeTabRequest.parse(["action": "assign", "accountID": "work"]) == .failure(.missing("tabID")))
    #expect(
      HostClaudeTabRequest.parse(["action": "assign", "tabID": "nope", "accountID": "work"])
        == .failure(.invalidTabID("nope")))
    #expect(
      HostClaudeTabRequest.parse(["action": "assign", "tabID": tabID.uuidString, "accountID": " "])
        == .failure(.missing("accountID")))
    #expect(
      HostClaudeTabRequest.parse(["action": "restart", "tabID": tabID.uuidString, "accountID": "work"])
        == .failure(.missing("worktreeID")))
    #expect(HostClaudeTabRequest.parse(["action": "fly"]) == .failure(.unknownAction("fly")))
    #expect(HostClaudeTabRequest.parse([:]) == .failure(.unknownAction("")))
  }
}

// MARK: - The host's reducer side.

@MainActor
struct HostClaudeTabFeatureTests {
  private let work = ClaudeAccount(id: "work", name: "Work", configDirectoryPath: "/tmp/kage-claude/work")
  private let tabID = TabID(rawValue: UUID(3))
  private let worktree = Worktree(
    location: .local(
      workingDirectory: URL(filePath: "/tmp/repo/feature"), repositoryRoot: URL(filePath: "/tmp/repo")),
    kind: .git, name: "feature", detail: "", isAttached: false)

  private func state() -> ClaudeAccountsFeature.State {
    let state = ClaudeAccountsFeature.State()
    state.$file.withLock { file in
      file = ClaudeAccountsFile()
      file.accounts = [work]
    }
    return state
  }

  @Test(.dependencies) func aViewerAssignmentIsStoredForTheTabAboutToBeCreated() async {
    let store = TestStore(initialState: state()) { ClaudeAccountsFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.tabAssignmentRequested(tabID: tabID.rawValue, "work"))
    #expect(store.state.file.tabAccountIDs == [tabID.rawValue.uuidString: "work"])
    // An account this Mac doesn't have is never stored.
    await store.send(.tabAssignmentRequested(tabID: UUID(), "gone"))
    #expect(store.state.file.tabAccountIDs.count == 1)
  }

  @Test(.dependencies) func aViewerRestartSkipsTheAlertAndLeavesTheHostsFocusAlone() async {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: state()) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
      $0.terminalClient.tabCanRename = { _, _ in true }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.restartTabConfirmed("work", worktree, tabID: tabID, focus: false))
    await store.finish()
    #expect(store.state.restartTabAlert == nil)
    #expect(store.state.file.tabAccountIDs == [tabID.rawValue.uuidString: "work"])
    #expect(sent.value == [.restartTab(worktree, tabID: tabID, resume: ClaudeTabRestart.resume, focus: false)])
  }

  @Test(.dependencies) func aViewerRestartOfAScriptTabOrUnknownAccountDoesNothing() async {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: state()) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
      $0.terminalClient.tabCanRename = { _, _ in false }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.restartTabConfirmed("work", worktree, tabID: tabID, focus: false))
    await store.send(.restartTabConfirmed("gone", worktree, tabID: tabID, focus: false))
    await store.finish()
    #expect(store.state.file.tabAccountIDs.isEmpty)
    #expect(sent.value.isEmpty)
  }
}

// MARK: - The host CLI (`kage host claude-tab`).

/// The CLI is a separate product with no test target, so it runs against a stub socket server.
@MainActor
@Suite(.serialized)
struct HostClaudeTabCLITests {
  private struct Recorded: Sendable {
    var queries: [(String, [String: String])] = []
    var commands: [URL] = []
  }

  @Test(.timeLimit(.minutes(3)))
  func newAssignsTheAccountThenCreatesTheTabInTheBackground() async throws {
    let tabID = UUID().uuidString
    let (run, recorded) = try await Self.runCLI([
      "host", "claude-tab", "new", "-w", "%2Ftmp%2Frepo", "--id", tabID, "--account", "work", "--input=claude",
    ])
    #expect(run.exitCode == 0, "CLI failed: \(run.standardError)")
    #expect(recorded.queries.map(\.0) == ["host-claude-tab"])
    #expect(recorded.queries.first?.1 == ["action": "assign", "tabID": tabID, "accountID": "work"])
    let command = try #require(recorded.commands.first)
    #expect(command.absoluteString.contains("tab"))
    #expect(command.absoluteString.contains(tabID))
    #expect(command.absoluteString.contains("background"))
    #expect(command.absoluteString.contains("claude"))
    #expect(run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == tabID)
  }

  @Test(.timeLimit(.minutes(3)))
  func restartSendsTheRequestAndReportsTheHostsRefusal() async throws {
    let tabID = UUID().uuidString
    let arguments = ["host", "claude-tab", "restart", "-w", "%2Ftmp%2Frepo", "--tab", tabID, "--account", "work"]
    let (run, recorded) = try await Self.runCLI(arguments)
    #expect(run.exitCode == 0, "CLI failed: \(run.standardError)")
    #expect(
      recorded.queries.first?.1 == [
        "action": "restart", "worktreeID": "%2Ftmp%2Frepo", "tabID": tabID, "accountID": "work",
      ])

    let (refused, _) = try await Self.runCLI(arguments, refusal: "This Mac has no Claude account work.")
    #expect(refused.exitCode != 0)
    #expect(refused.standardError.contains("This Mac has no Claude account work."))
  }

  // MARK: Helpers.

  private struct Run {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32
  }

  private static func runCLI(_ arguments: [String], refusal: String? = nil) async throws -> (Run, Recorded) {
    let directory = "/tmp/supacode-cli-\(UUID().uuidString)"
    let socketPath = "\(directory)/pid-1"
    let server = AgentHookSocketServer(socketPathOverride: socketPath)
    defer {
      server.shutdown()
      try? FileManager.default.removeItem(atPath: directory)
    }
    try #require(server.socketPath == socketPath)
    let recorded = LockIsolated(Recorded())
    server.onQuery = { name, params, clientFD in
      recorded.withValue { $0.queries.append((name, params)) }
      if let refusal {
        AgentHookSocketServer.sendCommandResponse(clientFD: clientFD, ok: false, error: refusal)
      } else {
        AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: [])
      }
    }
    server.onCommand = { url, clientFD in
      recorded.withValue { $0.commands.append(url) }
      AgentHookSocketServer.sendCommandResponse(clientFD: clientFD, ok: true)
    }
    let bundled = try #require(Bundle.main.resourceURL?.appending(path: "bin/supacode"))
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = bundled
    process.arguments = arguments + ["--timeout", "30"]
    process.environment = ProcessInfo.processInfo.environment.merging(["SUPACODE_SOCKET_PATH": socketPath]) { _, new in
      new
    }
    process.standardOutput = output
    process.standardError = error
    try await process.runToExit()
    let run = Run(
      standardOutput: String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      standardError: String(bytes: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
      exitCode: process.terminationStatus
    )
    return (run, recorded.value)
  }
}
