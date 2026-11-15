import Foundation

/// Names a project the same way on every machine, whatever its local path, so
/// Claude's per-project memory can follow it: the normalized `origin` remote
/// (`github.com/owner/repo`), or `local/<root commit>` for a repository without one.
nonisolated enum DotfilesProjectIdentity {
  /// `github.com/owner/repo` for any spelling of a hosted remote (scp-like,
  /// https with credentials, ssh with a port); nil for a local path or file URL.
  static func key(forRemote remote: String) -> String? {
    var value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !value.hasPrefix("/"), !value.hasPrefix("file:") else { return nil }
    var host: String
    var path: String
    if let schemeEnd = value.range(of: "://") {
      value = String(value[schemeEnd.upperBound...])
      guard let slash = value.firstIndex(of: "/") else { return nil }
      host = String(value[..<slash])
      path = String(value[value.index(after: slash)...])
    } else if let colon = value.firstIndex(of: ":") {
      host = String(value[..<colon])
      path = String(value[value.index(after: colon)...])
    } else {
      return nil
    }
    if let atSign = host.lastIndex(of: "@") { host = String(host[host.index(after: atSign)...]) }
    if let port = host.firstIndex(of: ":") { host = String(host[..<port]) }
    while path.hasSuffix("/") { path.removeLast() }
    if path.hasSuffix(".git") { path.removeLast(4) }
    let components = ([host] + path.split(separator: "/").map(String.init))
      .map { sanitize($0.lowercased()) }
      .filter { !$0.isEmpty }
    guard components.count >= 2 else { return nil }
    return components.joined(separator: "/")
  }

  static func key(forRootCommit sha: String) -> String {
    "local/" + sanitize(sha.lowercased())
  }

  /// The folder Claude Code keeps a project's data in under `~/.claude/projects`:
  /// the absolute path with every character other than a letter or digit
  /// replaced by `-`.
  static func claudeProjectDirectoryName(for path: String) -> String {
    String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
  }

  /// The working directory recorded in a Claude transcript (`"cwd":"…"`).
  static func cwd(inTranscript text: String) -> String? {
    guard let match = text.firstMatch(of: /"cwd":"((?:[^"\\]|\\.)*)"/) else { return nil }
    let raw = String(match.output.1)
    let decoded = try? JSONDecoder().decode(String.self, from: Data("\"\(raw)\"".utf8))
    return decoded ?? raw
  }

  private static func sanitize(_ component: String) -> String {
    String(component.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) })
  }
}
