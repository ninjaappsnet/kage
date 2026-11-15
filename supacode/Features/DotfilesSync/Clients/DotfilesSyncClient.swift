import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Runs one sync pass against the given remote.
nonisolated struct DotfilesSyncClient: Sendable {
  var sync:
    @Sendable (
      _ remoteURL: String,
      _ choices: [String: DotfilesVersionChoice],
      _ progress: @escaping @Sendable (DotfilesSyncProgress) async -> Void
    ) async throws -> DotfilesSyncReport
}

extension DotfilesSyncClient: DependencyKey {
  static let liveValue = Self { remoteURL, choices, progress in
    @Dependency(RepositoryPersistenceClient.self) var persistence
    let roots = await persistence.loadRoots().map { URL(fileURLWithPath: $0) }
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    let engine = DotfilesSyncEngine(
      environment: .init(
        home: home,
        repository: SupacodePaths.dotfilesRepositoryDirectory,
        remoteURL: remoteURL,
        conflictsDirectory: SupacodePaths.dotfilesConflictsDirectory,
        roots: DotfilesSyncRoot.defaults(kageConfigPath: relativePath(of: SupacodePaths.configBaseDirectory, to: home)),
        knownRepositoryRoots: roots,
        machineName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
        git: { arguments, directory in try await DotfilesGitProcess.run(arguments, in: directory) },
        gitNetwork: { arguments, directory in try await DotfilesGitProcess.runNetwork(arguments, in: directory) },
        resolveText: { path, base, ours, theirs in
          await DotfilesClaudeMerge.resolve(path: path, base: base, ours: ours, theirs: theirs)
        },
        versionChoices: choices,
        progress: progress
      )
    )
    return try await engine.sync()
  }

  static let testValue = Self { _, _, _ in DotfilesSyncReport() }

  /// `.config/kage` for a config folder inside home; nil when it lives elsewhere
  /// (an absolute `XDG_CONFIG_HOME`), which then isn't synced.
  nonisolated static func relativePath(of url: URL, to home: URL) -> String? {
    let path = url.standardizedFileURL.path
    let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
    guard path.hasPrefix(prefix) else { return nil }
    return String(path.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }
}

/// git as a child process. Local commands run `/usr/bin/git` directly (fast:
/// a pass makes dozens of them); network ones go through the login shell so the
/// user's ssh agent and credential helpers apply, with prompts disabled so a
/// missing credential fails instead of hanging.
nonisolated enum DotfilesGitProcess {
  static func run(_ arguments: [String], in directory: URL) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = arguments
      process.currentDirectoryURL = directory
      var environment = ProcessInfo.processInfo.environment
      environment["GIT_TERMINAL_PROMPT"] = "0"
      process.environment = environment
      let output = Pipe()
      let errors = Pipe()
      process.standardOutput = output
      process.standardError = errors
      process.standardInput = FileHandle.nullDevice
      // Read while running: a large `git show` would otherwise fill the pipe and block.
      let collected = LockIsolated(Data())
      output.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        collected.withValue { $0.append(chunk) }
      }
      process.terminationHandler = { process in
        output.fileHandleForReading.readabilityHandler = nil
        let rest = output.fileHandleForReading.readDataToEndOfFile()
        let data = collected.withValue { $0 + rest }
        let message = String(bytes: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus == 0 {
          continuation.resume(returning: data)
        } else {
          continuation.resume(
            throwing: DotfilesGitError(
              arguments: arguments,
              message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
          )
        }
      }
      do {
        try process.run()
      } catch {
        output.fileHandleForReading.readabilityHandler = nil
        continuation.resume(throwing: error)
      }
    }
  }

  static func runNetwork(_ arguments: [String], in directory: URL) async throws {
    @Dependency(\.shellClient) var shell
    do {
      _ = try await shell.runLogin(
        URL(fileURLWithPath: "/usr/bin/env"),
        ["GIT_TERMINAL_PROMPT=0", "GIT_SSH_COMMAND=ssh -o BatchMode=yes", "git"] + arguments,
        directory,
        log: false
      )
    } catch let error as ShellClientError {
      let message = [error.stderr, error.stdout]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
      throw DotfilesGitError(arguments: arguments, message: message ?? "failed")
    }
  }
}

/// The live `claude -p` behind `DotfilesConflictResolver`: the main account,
/// a scratch working directory, and a time limit.
nonisolated enum DotfilesClaudeMerge {
  static let timeout: Duration = .seconds(180)

  static func resolve(path: String, base: String?, ours: String, theirs: String) async -> String? {
    guard let executable = try? await ClaudeCLIRunner().executableURL() else { return nil }
    @Dependency(\.shellClient) var shellDependency
    let shell = shellDependency
    let scratch = FileManager.default.temporaryDirectory.appending(path: "kage-dotfiles-merge")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let prompt = DotfilesConflictResolver.prompt(path: path, base: base, ours: ours, theirs: theirs)
    let arguments =
      ["-u", ClaudeAccount.configDirectoryVariable, executable.path]
      + DotfilesConflictResolver.arguments + [prompt]
    return await withTaskGroup(of: String?.self) { group in
      group.addTask {
        let output = try? await shell.runLogin(URL(fileURLWithPath: "/usr/bin/env"), arguments, scratch, log: false)
        return output.map { DotfilesConflictResolver.cleanedOutput($0.stdout) }
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }
}
