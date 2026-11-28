import Foundation

/// Rebuilds the command line that restarts a running Claude Code session the
/// way it was started, so "Restart Tab with Claude Account" keeps experimental
/// switches (`CLAUDE_CODE_EXPERIMENTAL_CODE_MODE=1 claude`), flags such as
/// `--dangerously-skip-permissions`, and the exact conversation. Pure: the live
/// process is read by `ClaudeProcessInspector`.
///
/// Anything it cannot replay faithfully it leaves out rather than guess: an
/// unknown flag that may take a value drops the flags (the variables stay), and
/// a launch that is not an interactive Claude Code session gives nil, so the
/// caller falls back to the plain resume command.
nonisolated enum ClaudeLaunchReplay {
  /// A process's arguments (argv[0] first) and the environment it was started with.
  struct Launch: Equatable, Sendable {
    var arguments: [String]
    var environment: [String: String]
  }

  struct Relaunch: Equatable, Sendable {
    /// What the new shell types, without the trailing newline.
    var command: String
    /// Variables the new session gets from its environment instead of the typed
    /// line, so a credential never lands in shell history or the scrollback.
    var environment: [String: String]
  }

  /// The relaunch command for `launch`, or nil when it isn't an interactive Claude
  /// Code session. `parentEnvironment` is the environment of the process that
  /// started Claude (the shell): only variables that differ from it were set for
  /// this launch, so only those are carried. `sessionID` resumes that exact
  /// conversation; without one the folder's latest is continued.
  static func relaunch(launch: Launch, parentEnvironment: [String: String]?, sessionID: String?) -> Relaunch? {
    guard let arguments = programArguments(launch.arguments) else { return nil }
    let flags: [String]
    switch replayedFlags(arguments) {
    case .notInteractive: return nil
    case .replay(let kept): flags = kept
    case .unsure: flags = []
    }
    let carried = carriedEnvironment(own: launch.environment, parent: parentEnvironment ?? [:])
    var tokens = carried.typed.map { "\($0.key)=\(shellQuoted($0.value))" }
    tokens.append("claude")
    tokens += flags.map(shellQuoted)
    if let sessionID, UUID(uuidString: sessionID) != nil {
      tokens += ["--resume", sessionID.lowercased()]
    } else {
      tokens.append("--continue")
    }
    return Relaunch(command: tokens.joined(separator: " "), environment: carried.hidden)
  }

  // MARK: - Program.

  /// The arguments after the program when `argv` runs Claude Code (the native
  /// `claude` binary, or `node …/claude-code/cli.js`); nil for any other process.
  static func programArguments(_ argv: [String]) -> [String]? {
    guard let program = argv.first else { return nil }
    if basename(program) == "claude" { return Array(argv.dropFirst()) }
    if ["node", "bun"].contains(basename(program)), argv.count > 1, argv[1].contains("claude-code") {
      return Array(argv.dropFirst(2))
    }
    return nil
  }

  private static func basename(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
  }

  // MARK: - Flags.

  enum FlagReplay: Equatable {
    /// The flags to type again, in their original order.
    case replay([String])
    /// A print, background or subcommand run: not a session to restart.
    case notInteractive
    /// A flag this table doesn't know may have taken a value; replay none.
    case unsure
  }

  private enum Arity {
    case none
    case one
    case optional
    case list
  }

  /// Flags that pick, fork or relocate the conversation. The relaunch picks the
  /// conversation itself (`--resume <id>`) and already runs in the right folder.
  private static let dropped: [String: Arity] = [
    "-c": .none, "--continue": .none,
    "-r": .optional, "--resume": .optional,
    "--session-id": .one, "--fork-session": .none,
    "--from-pr": .optional, "--teleport": .optional,
    "-w": .optional, "--worktree": .optional, "--tmux": .none,
    "--desktop": .none, "--environment": .one, "--cloud": .optional,
  ]

  /// Flags that mean the process is not an interactive session.
  private static let nonInteractive: Set<String> = [
    "-p", "--print", "--bg", "--background", "-h", "--help", "-v", "--version",
  ]

  /// Claude Code's options as `claude --help` lists them (2.1). Values are
  /// consumed the way its parser does, so the replayed tokens parse the same.
  private static let kept: [String: Arity] = [
    "--agent": .one, "--agents": .one, "--append-system-prompt": .one, "--append-system-prompt-file": .one,
    "--autocompact": .one, "--debug-file": .one, "--effort": .one, "--fallback-model": .one,
    "--input-format": .one, "--json-schema": .one, "--max-budget-usd": .one, "--model": .one,
    "-n": .one, "--name": .one, "--output-format": .one, "--permission-mode": .one,
    "--permission-prompts": .one, "--plugin-dir": .one, "--plugin-url": .one,
    "--remote-control-session-name-prefix": .one, "--setting-sources": .one, "--settings": .one,
    "--system-prompt": .one, "--system-prompt-file": .one, "--system-prompt-snapshot": .one,
    "--add-dir": .list, "--allowedTools": .list, "--allowed-tools": .list, "--betas": .list,
    "--disallowedTools": .list, "--disallowed-tools": .list, "--file": .list, "--mcp-config": .list,
    "--tools": .list,
    "-d": .optional, "--debug": .optional, "--prompt-suggestions": .optional, "--remote-control": .optional,
    "--allow-dangerously-skip-permissions": .none, "--ax-screen-reader": .none, "--bare": .none,
    "--brief": .none, "--chrome": .none, "--no-chrome": .none, "--dangerously-skip-permissions": .none,
    "--disable-slash-commands": .none, "--exclude-dynamic-system-prompt-sections": .none,
    "--forward-subagent-text": .none, "--ide": .none, "--include-hook-events": .none,
    "--include-partial-messages": .none, "--no-session-persistence": .none,
    "--replay-user-messages": .none, "--restricted": .none, "--safe-mode": .none,
    "--strict-mcp-config": .none, "--verbose": .none,
  ]

  /// Subcommands: a process running one of these is not a session.
  private static let subcommands: Set<String> = [
    "agents", "attach", "auth", "auto-mode", "doctor", "gateway", "import", "install", "logs", "mcp",
    "plugin", "plugins", "purge", "respawn", "rm", "setup-token", "stop", "kill", "ultrareview", "update",
    "upgrade",
  ]

  static func replayedFlags(_ arguments: [String]) -> FlagReplay {
    var result: [String] = []
    var index = 0
    var sawPositional = false
    func isValue(_ position: Int) -> Bool {
      position < arguments.count && !arguments[position].hasPrefix("-")
    }
    while index < arguments.count {
      let token = arguments[index]
      if token == "--" { break }
      guard token.hasPrefix("-"), token.count > 1 else {
        // A positional: the starting prompt, never sent again, or a subcommand.
        if !sawPositional, subcommands.contains(token) { return .notInteractive }
        sawPositional = true
        index += 1
        continue
      }
      let name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
      let hasInlineValue = name.count < token.count
      if nonInteractive.contains(name) { return .notInteractive }
      if let arity = dropped[name] {
        index += 1
        if !hasInlineValue { index = skipValues(arity, from: index, isValue: isValue) }
        continue
      }
      guard let arity = kept[name] else {
        // Unknown: unambiguous only when nothing that could be its value follows.
        if !hasInlineValue, isValue(index + 1) { return .unsure }
        result.append(token)
        index += 1
        continue
      }
      let end = hasInlineValue ? index + 1 : skipValues(arity, from: index + 1, isValue: isValue)
      result += arguments[index..<min(end, arguments.count)]
      index = end
    }
    guard result.allSatisfy({ !containsControlCharacter($0) }) else { return .unsure }
    return .replay(result)
  }

  /// The index after the values a flag of `arity` consumes, starting at `index`.
  private static func skipValues(_ arity: Arity, from index: Int, isValue: (Int) -> Bool) -> Int {
    switch arity {
    case .none:
      return index
    case .one:
      return index + 1
    case .optional:
      return isValue(index) ? index + 1 : index
    case .list:
      var end = index
      while isValue(end) { end += 1 }
      return end
    }
  }

  // MARK: - Environment.

  /// Name prefixes of variables Claude Code reads.
  private static let carriedPrefixes = ["CLAUDE_", "ANTHROPIC_", "DISABLE_"]
  private static let carriedNames: Set<String> = ["MAX_THINKING_TOKENS", "MCP_TIMEOUT", "MCP_TOOL_TIMEOUT"]

  /// Never carried: the account directory is exactly what the restart changes,
  /// these credentials would override the new account's login, and the rest are
  /// what a running Claude Code sets for the processes it starts (a session
  /// started from inside another one inherits them).
  private static let neverCarried: Set<String> = [
    "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_CHILD_NOTES_DIR",
    "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_PID",
  ]

  private static let secretMarkers = ["KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL", "AUTH", "HEADERS"]

  /// The Claude Code variables set for this launch (differing from the parent's),
  /// split into those safe to type and those passed through the environment.
  static func carriedEnvironment(
    own: [String: String],
    parent: [String: String]
  ) -> (typed: [(key: String, value: String)], hidden: [String: String]) {
    var typed: [(key: String, value: String)] = []
    var hidden: [String: String] = [:]
    for (key, value) in own where parent[key] != value && isCarried(key) {
      if secretMarkers.contains(where: key.contains) || containsControlCharacter(value) {
        hidden[key] = value
      } else {
        typed.append((key, value))
      }
    }
    return (typed.sorted { $0.key < $1.key }, hidden)
  }

  private static func isCarried(_ key: String) -> Bool {
    guard !neverCarried.contains(key) else { return false }
    return carriedNames.contains(key) || carriedPrefixes.contains(where: key.hasPrefix)
  }

  // MARK: - Shell.

  private static let shellSafe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-")

  /// `value` as one POSIX shell word: bare when it has only safe characters,
  /// else single-quoted with embedded quotes closed and escaped.
  static func shellQuoted(_ value: String) -> String {
    if !value.isEmpty, value.allSatisfy(shellSafe.contains) { return value }
    return "'" + value.replacing("'", with: #"'\''"#) + "'"
  }

  private static func containsControlCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
  }

  // MARK: - Session and process.

  /// The conversation id in Claude Code's `sessions/<pid>.json`, when the file
  /// belongs to `pid` and names one. The file is undocumented, so anything
  /// unexpected reads as "unknown" and the folder's latest is continued.
  static func sessionID(fromSessionFile data: Data, pid: pid_t) -> String? {
    struct SessionFile: Decodable {
      var pid: Int?
      var sessionId: String?
    }
    guard let file = try? JSONDecoder().decode(SessionFile.self, from: data),
      file.pid == Int(pid),
      let sessionID = file.sessionId,
      UUID(uuidString: sessionID) != nil
    else { return nil }
    return sessionID
  }

  /// The session to relaunch among the pids the presence hooks reported for a
  /// surface: one whose parent isn't itself tracked (a subagent's shell runs
  /// under the session), the newest when several are unrelated.
  static func rootPID(of pids: Set<pid_t>, parent: (pid_t) -> pid_t?) -> pid_t? {
    let roots = pids.filter { pid in parent(pid).map { !pids.contains($0) } ?? true }
    return roots.max()
  }
}
