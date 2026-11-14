import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

nonisolated enum ClaudeAccountsError: LocalizedError, Equatable {
  case claudeNotFound
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case .claudeNotFound:
      "Kage couldn't find the claude command. Install Claude Code, or make sure your shell's PATH includes it."
    case .commandFailed(let message):
      message
    }
  }
}

/// Everything the Claude Accounts feature does outside the reducer: running the
/// `claude` CLI as a given account, preparing account directories, and reading
/// MCP server state.
nonisolated struct ClaudeAccountsClient: Sendable {
  var authStatus: @Sendable (ClaudeAccount) async throws -> ClaudeAuthStatus
  /// Starts `claude auth login` for the account, replacing any login in flight.
  var startLogin: @Sendable (ClaudeAccount) async throws -> AsyncStream<ClaudeLoginSession.Event>
  /// Writes a line (the pasted code) to the running login's stdin.
  var sendLoginInput: @Sendable (String) async -> Void
  var cancelLogin: @Sendable () async -> Void
  var logout: @Sendable (ClaudeAccount) async throws -> Void
  var prepareDirectory: @Sendable (URL) async throws -> ClaudeAccountLayout.Report
  var readMCPServers: @Sendable (ClaudeAccount) async throws -> ClaudeMCPServerSync.Servers
  var applyMCPOperations: @Sendable (ClaudeAccount, [ClaudeMCPServerSync.Operation]) async throws -> Void
}

nonisolated extension ClaudeAccountsClient: DependencyKey {
  static let liveValue: Self = {
    let runner = ClaudeCLIRunner()
    let logins = ActiveLogin()
    return Self(
      authStatus: { account in
        let output = try await runner.run(["auth", "status", "--json"], as: account)
        return try ClaudeAuthStatus.decode(output)
      },
      startLogin: { account in
        let session = try ClaudeLoginSession.launch(executableURL: try await runner.executableURL(), account: account)
        await logins.replace(with: session)
        return session.events
      },
      sendLoginInput: { line in await logins.send(line) },
      cancelLogin: { await logins.cancel() },
      logout: { account in
        _ = try await runner.run(["auth", "logout"], as: account)
      },
      prepareDirectory: { directory in
        try ClaudeAccountLayout().prepare(accountDirectory: directory)
      },
      readMCPServers: { account in
        try ClaudeMCPServerSync.readServers(globalStateURL: account.globalStateURL())
      },
      applyMCPOperations: { account, operations in
        // Through the CLI, not by editing `.claude.json`: a running session rewrites
        // that file, and the CLI owns its locking and format.
        for operation in operations {
          switch operation.kind {
          case .remove:
            _ = try await runner.run(["mcp", "remove", "--scope", "user", operation.serverName], as: account)
          case .upsert(let configuration):
            if try ClaudeMCPServerSync.readServers(globalStateURL: account.globalStateURL())[operation.serverName]
              != nil
            {
              _ = try await runner.run(["mcp", "remove", "--scope", "user", operation.serverName], as: account)
            }
            let json = try ClaudeMCPServerSync.encodedConfiguration(configuration)
            _ = try await runner.run(
              ["mcp", "add-json", "--scope", "user", operation.serverName, json], as: account)
          }
        }
      }
    )
  }()

  static let testValue = Self(
    authStatus: { _ in ClaudeAuthStatus(loggedIn: false) },
    startLogin: { _ in throw ClaudeAccountsError.claudeNotFound },
    sendLoginInput: { _ in },
    cancelLogin: {},
    logout: { _ in },
    prepareDirectory: { _ in ClaudeAccountLayout.Report() },
    readMCPServers: { _ in [:] },
    applyMCPOperations: { _, _ in }
  )
}

/// The one login the Settings sheet can drive at a time.
actor ActiveLogin {
  private var session: ClaudeLoginSession?

  func replace(with session: ClaudeLoginSession) {
    self.session?.cancel()
    self.session = session
  }

  func send(_ line: String) {
    session?.send(line)
  }

  func cancel() {
    session?.cancel()
    session = nil
  }
}

/// Runs `claude` through the user's login shell so the PATH their terminal sees
/// applies, with `CLAUDE_CONFIG_DIR` set (or unset, for the main account) by `env`
/// after the rc files ran, so an rc that exports its own value can't win.
actor ClaudeCLIRunner {
  private var cachedExecutableURL: URL?

  func executableURL() async throws -> URL {
    if let cachedExecutableURL, FileManager.default.isExecutableFile(atPath: cachedExecutableURL.path) {
      return cachedExecutableURL
    }
    @Dependency(\.shellClient) var shell
    let which = URL(fileURLWithPath: "/usr/bin/which")
    let located = try? await shell.runLogin(which, ["claude"], nil, log: false).stdout
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let fallbacks = ForgeCLIExecutableResolver.defaultFallbackExecutableURLs(executableName: "claude")
    let candidates = [located].compactMap { $0 }.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) } + fallbacks
    guard let url = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
      throw ClaudeAccountsError.claudeNotFound
    }
    cachedExecutableURL = url
    return url
  }

  func run(_ arguments: [String], as account: ClaudeAccount) async throws -> String {
    let executable = try await executableURL()
    @Dependency(\.shellClient) var shell
    let variable = ClaudeAccount.configDirectoryVariable
    let assignment = account.configDirectoryPath.map { ["\(variable)=\($0)"] } ?? ["-u", variable]
    do {
      return try await shell.runLogin(
        URL(fileURLWithPath: "/usr/bin/env"),
        assignment + [executable.path] + arguments,
        nil,
        log: false
      ).stdout
    } catch let error as ShellClientError {
      let message = [error.stderr, error.stdout]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
      throw ClaudeAccountsError.commandFailed(message ?? "claude \(arguments.joined(separator: " ")) failed.")
    }
  }
}
