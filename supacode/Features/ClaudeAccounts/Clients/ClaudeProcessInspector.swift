import Darwin
import Foundation

/// Reads a running Claude Code process for `ClaudeLaunchReplay`: its argv and
/// start environment (`KERN_PROCARGS2`, readable for this user's processes
/// without privileges), its parent, and the conversation in its config
/// directory's `sessions/<pid>.json`. Everything returns nil when the process is
/// gone or unreadable, so a restart falls back to the plain resume command.
nonisolated enum ClaudeProcessInspector {
  /// The relaunch command for the Claude Code session among `pids` (the pids the
  /// presence hooks reported for one surface), or nil.
  static func relaunch(pids: Set<pid_t>) -> ClaudeLaunchReplay.Relaunch? {
    guard let pid = ClaudeLaunchReplay.rootPID(of: pids, parent: parentPID(of:)),
      let launch = launch(pid: pid),
      ClaudeLaunchReplay.programArguments(launch.arguments) != nil
    else { return nil }
    let parentEnvironment = parentPID(of: pid).flatMap { self.launch(pid: $0)?.environment }
    return ClaudeLaunchReplay.relaunch(
      launch: launch,
      parentEnvironment: parentEnvironment,
      sessionID: sessionID(pid: pid, environment: launch.environment)
    )
  }

  /// argv and the environment `pid` was started with.
  static func launch(pid: pid_t) -> ClaudeLaunchReplay.Launch? {
    guard pid > 0 else { return nil }
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    return parse(procargs: Array(buffer.prefix(size)))
  }

  /// Layout: argc (Int32), the executable path, NUL padding, argc argument
  /// strings, NUL padding, the environment strings, an empty string, then the
  /// kernel's own `apple[]` strings (not part of the environment).
  static func parse(procargs buffer: [UInt8]) -> ClaudeLaunchReplay.Launch? {
    guard buffer.count > MemoryLayout<Int32>.size else { return nil }
    let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
    guard argc > 0 else { return nil }
    var index = MemoryLayout<Int32>.size
    func skipPadding() {
      while index < buffer.count, buffer[index] == 0 { index += 1 }
    }
    func nextString() -> String? {
      guard index < buffer.count else { return nil }
      let start = index
      while index < buffer.count, buffer[index] != 0 { index += 1 }
      defer { index += 1 }
      // Never "": an empty string ends the environment.
      return String(bytes: buffer[start..<index], encoding: .utf8) ?? "\u{FFFD}"
    }
    _ = nextString()  // The executable path.
    skipPadding()
    var arguments: [String] = []
    while arguments.count < argc, let argument = nextString() { arguments.append(argument) }
    guard arguments.count == argc else { return nil }
    skipPadding()
    var entries: [String] = []
    while let entry = nextString(), !entry.isEmpty { entries.append(entry) }
    var environment: [String: String] = [:]
    for entry in entries {
      guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else { continue }
      environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
    }
    return ClaudeLaunchReplay.Launch(arguments: arguments, environment: environment)
  }

  static func parentPID(of pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    let parent = pid_t(info.pbi_ppid)
    return parent > 1 ? parent : nil
  }

  /// The conversation `pid` is in, from the config directory it runs under
  /// (`CLAUDE_CONFIG_DIR`, else `~/.claude`): sessions are kept per account.
  static func sessionID(pid: pid_t, environment: [String: String]) -> String? {
    let directory =
      environment[ClaudeAccount.configDirectoryVariable].map { URL(filePath: $0, directoryHint: .isDirectory) }
      ?? ClaudeAccount.hubDirectory()
    let file = directory.appending(path: "sessions/\(pid).json", directoryHint: .notDirectory)
    guard let data = try? Data(contentsOf: file) else { return nil }
    return ClaudeLaunchReplay.sessionID(fromSessionFile: data, pid: pid)
  }
}
