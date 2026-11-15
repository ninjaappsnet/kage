import CryptoKit
import Foundation

nonisolated struct DotfilesGitError: Error, Equatable, LocalizedError {
  var arguments: [String]
  var message: String

  var errorDescription: String? { "git \(arguments.first ?? "") failed: \(message)" }
}

nonisolated struct DotfilesSyncReport: Equatable, Sendable {
  var exported: [String] = []
  var imported: [String] = []
  var deletedLocally: [String] = []
  var pushed = false
  /// Files not synced because they look like they hold a secret.
  var blockedSecrets: [String] = []
  /// Files both sides changed that were merged by `claude -p`.
  var resolvedByClaude: [String] = []
  /// Files whose remote edit could not be merged: the local copy was kept and
  /// the remote one saved under the conflicts folder.
  var unresolved: [String] = []
  /// JSON keys both sides changed differently; the local value was kept.
  var jsonConflicts: [String] = []
}

/// One sync pass between the machine's home folder and its clone of the user's
/// dotfiles repository (`~/.kage/dotfiles`).
///
/// Files are copied, never linked: Claude Code saves `settings.json` by replacing
/// it, which would silently turn a symlink back into a plain file. A pass:
/// 1. copies local changes into the clone and commits them,
/// 2. fetches and merges the remote (JSON three-way, then git's line merge,
///    then `claude -p` for what is left, else local wins and remote is saved),
/// 3. copies the merged result back home and pushes.
///
/// Deletions compare against this machine's own record of the last pass
/// (`.git/kage-sync-state.json`), never against the repository, so a file this
/// machine never had (a project it hasn't opened Claude in) is not read as deleted.
actor DotfilesSyncEngine {
  struct Environment: Sendable {
    var home: URL
    var repository: URL
    var remoteURL: String
    var conflictsDirectory: URL
    var roots: [DotfilesSyncRoot]
    /// Local git repositories the user works in (Kage's sidebar), used to name
    /// memory folders Claude hasn't created on this machine yet.
    var knownRepositoryRoots: [URL]
    var machineName: String
    /// Runs git in a directory and returns its raw stdout; throws `DotfilesGitError`.
    var git: @Sendable (_ arguments: [String], _ directory: URL) async throws -> Data
    /// Same, for commands that reach the network (clone, fetch, push).
    var gitNetwork: @Sendable (_ arguments: [String], _ directory: URL) async throws -> Void
    /// Merges two edited copies of a text file; nil when it can't.
    var resolveText: @Sendable (_ path: String, _ base: String?, _ ours: String, _ theirs: String) async -> String?
  }

  enum Entry: Equatable, Sendable {
    case file(Data, executable: Bool)
    case symlink(String)

    var digest: String {
      let bytes: Data
      switch self {
      case .file(let data, let executable): bytes = Data((executable ? "x" : "f").utf8) + data
      case .symlink(let target): bytes = Data(("l" + target).utf8)
      }
      return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
  }

  private struct State: Codable {
    /// Repository path → digest of what this machine held after the last pass.
    var synced: [String: String] = [:]
    /// Claude project folder name → project key, so transcripts are read once.
    var memoryKeys: [String: String] = [:]
  }

  private let env: Environment
  private let fileManager = FileManager.default

  init(environment: Environment) {
    self.env = environment
  }

  // MARK: - Pass.

  /// What one pass knows and has done so far.
  private struct Pass {
    var targets: Targets
    /// Repository path → this machine's current copy, as stored in the repository.
    var local: [String: Entry]
    /// Paths held back because they look like they contain a secret.
    var blocked: Set<String> = []
    var report = DotfilesSyncReport()
  }

  func sync() async throws -> DotfilesSyncReport {
    try await ensureRepository()
    let previous = loadState()
    var state = previous ?? State()
    let targets = Targets(env: env, memoryDirectories: await memoryDirectoriesByKey(state: &state))
    var pass = Pass(targets: targets, local: try await snapshotLocal(targets: targets))

    try await export(&pass, previous: previous)
    try await commitAll(message: "Sync from \(env.machineName)")

    let beforeMerge = try snapshotRepository()
    if try await fetchRemote() {
      try await mergeRemote(report: &pass.report)
    }
    let merged = try snapshotRepository()
    try await importChanges(&pass, beforeMerge: beforeMerge, merged: merged)

    pass.report.pushed = try await pushIfAhead()
    state.synced = pass.local.reduce(into: [:]) { result, item in
      if merged[item.key] == item.value { result[item.key] = item.value.digest }
    }
    saveState(state)
    return pass.report
  }

  /// Copies local changes and deletions into the clone.
  private func export(_ pass: inout Pass, previous: State?) async throws {
    let tracked = try snapshotRepository()
    for (path, entry) in pass.local.sorted(by: { $0.key < $1.key }) where tracked[path] != entry {
      if case .file(let data, _) = entry, let text = String(data: data, encoding: .utf8),
        DotfilesSecretScanner.containsSecret(text)
      {
        pass.report.blockedSecrets.append(path)
        pass.blocked.insert(path)
        continue
      }
      var outgoing = entry
      if previous == nil, let existing = tracked[path] {
        // First pass on this machine and the repository already has its own
        // copy: merge the two instead of letting either side win.
        outgoing = await merge(path: path, base: nil, ours: entry, theirs: existing, report: &pass.report)
        if outgoing != entry {
          try write(outgoing, to: pass.targets.localURL(for: path))
          pass.local[path] = outgoing
        }
      }
      try write(outgoing, to: env.repository.appending(path: path))
      pass.report.exported.append(path)
    }
    guard let previous else { return }
    for path in previous.synced.keys.sorted() where pass.local[path] == nil && tracked[path] != nil {
      guard pass.targets.localURL(for: path) != nil, !Self.isNestedMarker(path) else { continue }
      try? fileManager.removeItem(at: env.repository.appending(path: path))
      pass.report.exported.append(path)
    }
  }

  /// Copies what the merge brought in back home, and removes what it deleted.
  private func importChanges(_ pass: inout Pass, beforeMerge: [String: Entry], merged: [String: Entry]) async throws {
    for (path, entry) in merged.sorted(by: { $0.key < $1.key })
    where pass.local[path] != entry && !pass.blocked.contains(path) {
      guard let target = pass.targets.localURL(for: path) else { continue }
      // Edited again while this pass ran: the next pass exports it.
      guard currentEntry(at: target, repoPath: path) == pass.local[path] else { continue }
      if Self.isNestedMarker(path) {
        if try await cloneNestedRepository(entry, marker: target) { pass.report.imported.append(path) }
        continue
      }
      try write(entry, to: target)
      pass.local[path] = entry
      pass.report.imported.append(path)
    }
    for (path, entry) in beforeMerge
    where merged[path] == nil && pass.local[path] == entry && !pass.blocked.contains(path) {
      guard let target = pass.targets.localURL(for: path), !Self.isNestedMarker(path) else { continue }
      try? fileManager.removeItem(at: target)
      pass.local[path] = nil
      pass.report.deletedLocally.append(path)
    }
  }

  private static func isNestedMarker(_ path: String) -> Bool {
    path.hasSuffix(DotfilesMemoryLayout.nestedRepositorySuffix)
  }

  // MARK: - Repository.

  /// git's stdout as text, surrounding whitespace trimmed.
  private func git(_ arguments: [String], in directory: URL? = nil) async throws -> String {
    let data = try await env.git(arguments, directory ?? env.repository)
    return (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func succeeds(_ arguments: [String], in directory: URL? = nil) async -> Bool {
    (try? await env.git(arguments, directory ?? env.repository)) != nil
  }

  private func ensureRepository() async throws {
    defer {
      // JSON never goes through git's line merge, which can produce valid-looking
      // but broken JSON: it always conflicts, and `DotfilesJSONMerge` takes over.
      let attributes = env.repository.appending(path: ".gitattributes")
      if !fileManager.fileExists(atPath: attributes.path) {
        try? Data("*.json -merge\n".utf8).write(to: attributes)
      }
    }
    guard !fileManager.fileExists(atPath: env.repository.appending(path: ".git").path) else { return }
    let parent = env.repository.deletingLastPathComponent()
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    try await env.gitNetwork(["clone", env.remoteURL, env.repository.path], parent)
    let hasCommits = await succeeds(["rev-parse", "--verify", "-q", "HEAD"])
    guard !hasCommits else { return }
    _ = try await git(["symbolic-ref", "HEAD", "refs/heads/main"])
    let readme = """
      # Kage dotfiles

      Claude Code, Codex and Kage settings plus per-project Claude memory, kept in
      sync between machines by Kage (Settings → Sync). Kage commits and pulls here
      on its own; edit the files on any machine, not in this repository.

      - `claude/`, `agents/`, `codex/`, `kage/`: files from `~/.claude`, `~/.agents`,
        `~/.codex` and Kage's config folder. `{{HOME}}` stands for the home folder.
      - `claude-memory/<host>/<owner>/<repo>/`: Claude's memory for each project,
        named by its git remote so it finds the project wherever it is checked out.
      - `*.kage-git-repo`: a skill installed with `git clone`; holds its clone URL.

      """
    try Data(readme.utf8).write(to: env.repository.appending(path: "README.md"))
  }

  private func commitAll(message: String) async throws {
    _ = try await git(["add", "-A"])
    guard try await !git(["diff", "--cached", "--name-only"]).isEmpty else { return }
    _ = try await git(commitArguments(["commit", "-q", "-m", message]))
  }

  /// Background commits must never stop for a GPG passphrase, and still work on
  /// a machine with no git identity configured.
  private func commitArguments(_ arguments: [String]) async throws -> [String] {
    var options = ["-c", "commit.gpgsign=false"]
    let email = (try? await git(["config", "user.email"])) ?? ""
    if email.isEmpty {
      options += ["-c", "user.name=Kage", "-c", "user.email=kage@localhost"]
    }
    return options + arguments
  }

  /// Fetches; false when the remote has no `main` yet (a brand-new repository).
  private func fetchRemote() async throws -> Bool {
    try await env.gitNetwork(["fetch", "-q", "origin"], env.repository)
    return await succeeds(["rev-parse", "--verify", "-q", "refs/remotes/origin/main"])
  }

  private func mergeRemote(report: inout DotfilesSyncReport) async throws {
    guard await succeeds(["rev-parse", "--verify", "-q", "HEAD"]) else {
      _ = try await git(["reset", "-q", "--hard", "origin/main"])
      return
    }
    do {
      _ = try await git(commitArguments(["merge", "-q", "--no-edit", "--allow-unrelated-histories", "origin/main"]))
      return
    } catch {
      let conflicted = try await git(["diff", "--name-only", "--diff-filter=U"])
        .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
      guard !conflicted.isEmpty else { throw error }
      for path in conflicted {
        let base = await stage(1, path)
        let ours = await stage(2, path)
        let theirs = await stage(3, path)
        let file = env.repository.appending(path: path)
        switch (ours, theirs) {
        case (let ours?, let theirs?):
          let merged = await merge(path: path, base: base, ours: ours, theirs: theirs, report: &report)
          try write(merged, to: file)
        case (let kept?, nil), (nil, let kept?):
          // Edited on one side, deleted on the other: keep the edit.
          try write(kept, to: file)
        case (nil, nil):
          try? fileManager.removeItem(at: file)
        }
      }
      _ = try await git(["add", "-A"])
      _ = try await git(commitArguments(["commit", "-q", "--no-edit"]))
    }
  }

  private func stage(_ number: Int, _ path: String) async -> Entry? {
    guard let data = try? await env.git(["show", ":\(number):\(path)"], env.repository) else { return nil }
    return .file(data, executable: false)
  }

  private func pushIfAhead() async throws -> Bool {
    guard await succeeds(["rev-parse", "--verify", "-q", "HEAD"]) else { return false }
    if await succeeds(["rev-parse", "--verify", "-q", "refs/remotes/origin/main"]) {
      guard Int(try await git(["rev-list", "--count", "origin/main..HEAD"])) ?? 0 > 0 else { return false }
    }
    try await env.gitNetwork(["push", "-q", "-u", "origin", "HEAD:main"], env.repository)
    return true
  }

  // MARK: - Merging one file.

  /// Both sides changed `path`: JSON merges structurally, text goes to
  /// `claude -p`, and when that fails ours is kept and theirs saved aside.
  private func merge(
    path: String,
    base: Entry?,
    ours: Entry,
    theirs: Entry,
    report: inout DotfilesSyncReport
  ) async -> Entry {
    guard case .file(let ourData, let executable) = ours, case .file(let theirData, _) = theirs else { return ours }
    let baseData: Data? = if case .file(let data, _) = base { data } else { nil }
    if path.hasSuffix(".json"), let mine = try? DotfilesJSONMerge.Value.parse(ourData),
      let other = try? DotfilesJSONMerge.Value.parse(theirData)
    {
      let original = baseData.flatMap { try? DotfilesJSONMerge.Value.parse($0) }
      let result = DotfilesJSONMerge.merge(base: original, ours: mine, theirs: other)
      report.jsonConflicts += result.conflicts.map { "\(path): \($0)" }
      if let value = result.value, let data = try? value.serialized() {
        return .file(data, executable: executable)
      }
      return ours
    }
    if let mine = String(data: ourData, encoding: .utf8), let other = String(data: theirData, encoding: .utf8) {
      let original = baseData.flatMap { String(data: $0, encoding: .utf8) }
      if let merged = await env.resolveText(path, original, mine, other),
        DotfilesConflictResolver.isAcceptable(merged, ours: mine, theirs: other),
        !DotfilesSecretScanner.containsSecret(merged)
      {
        report.resolvedByClaude.append(path)
        return .file(Data(merged.utf8), executable: executable)
      }
    }
    let saved = env.conflictsDirectory.appending(path: path)
    try? write(theirs, to: saved)
    report.unresolved.append(path)
    return ours
  }

  // MARK: - Snapshots.

  /// Entries collected by a walk, plus nested git checkouts found on the way.
  private struct Walk {
    /// Reading from home: encode `{{HOME}}` and stop at nested checkouts.
    var fromHome: Bool
    var excluded: [String] = []
    var entries: [String: Entry] = [:]
    var nested: [(repoPath: String, url: URL)] = []
  }

  private func snapshotRepository() throws -> [String: Entry] {
    var walk = Walk(fromHome: false)
    for prefix in DotfilesMemoryLayout.managedPrefixes(roots: env.roots) {
      collect(env.repository.appending(path: prefix), repoPath: prefix, into: &walk)
    }
    return walk.entries
  }

  private func snapshotLocal(targets: Targets) async throws -> [String: Entry] {
    var walk = Walk(fromHome: true)
    for root in env.roots {
      let base = env.home.appending(path: root.localPath)
      guard let names = try? fileManager.contentsOfDirectory(atPath: base.path) else { continue }
      walk.excluded = root.excludedPaths.map { "\(root.repoPrefix)/\($0)" }
      for name in names.sorted() where !DotfilesSyncRoot.isExcluded(name: name) {
        let url = base.appending(path: name)
        let repoPath = "\(root.repoPrefix)/\(name)"
        if root.directories.contains(name), isDirectory(url) {
          collect(url, repoPath: repoPath, into: &walk)
        } else if root.files.contains(name)
          || root.fileExtensions.contains((name as NSString).pathExtension) && !isDirectory(url)
        {
          if let entry = entry(at: url, encode: true) { walk.entries[repoPath] = entry }
        }
      }
    }
    walk.excluded = []
    for (key, directory) in targets.memoryDirectories {
      collect(directory, repoPath: "\(DotfilesMemoryLayout.prefix)/\(key)", into: &walk)
    }
    for item in walk.nested {
      let remote = try? await git(["config", "--get", "remote.origin.url"], in: item.url)
      guard let remote, !remote.isEmpty, DotfilesProjectIdentity.key(forRemote: remote) != nil else { continue }
      walk.entries[item.repoPath + DotfilesMemoryLayout.nestedRepositorySuffix] = .file(
        Data((remote + "\n").utf8),
        executable: false
      )
    }
    return walk.entries
  }

  private func collect(_ url: URL, repoPath: String, into walk: inout Walk) {
    guard !walk.excluded.contains(repoPath) else { return }
    guard isDirectory(url), !isSymlink(url) else {
      if let entry = entry(at: url, encode: walk.fromHome) { walk.entries[repoPath] = entry }
      return
    }
    if walk.fromHome, fileManager.fileExists(atPath: url.appending(path: ".git").path) {
      walk.nested.append((repoPath, url))
      return
    }
    guard let names = try? fileManager.contentsOfDirectory(atPath: url.path) else { return }
    for name in names.sorted() where !DotfilesSyncRoot.isExcluded(name: name) {
      collect(url.appending(path: name), repoPath: "\(repoPath)/\(name)", into: &walk)
    }
  }

  /// A file or symlink as stored in the repository: text with the home folder
  /// written as `{{HOME}}` when `encode` (reading from home), verbatim otherwise.
  private func entry(at url: URL, encode: Bool) -> Entry? {
    if isSymlink(url) {
      guard let target = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else { return nil }
      return .symlink(encode ? DotfilesHomeToken.encode(target, home: env.home.path) : target)
    }
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      (attributes[.size] as? Int ?? 0) <= DotfilesSyncRoot.maximumFileSize,
      let data = fileManager.contents(atPath: url.path)
    else { return nil }
    let executable = ((attributes[.posixPermissions] as? Int ?? 0) & 0o100) != 0
    guard encode, !data.contains(0), let text = String(data: data, encoding: .utf8) else {
      return .file(data, executable: executable)
    }
    return .file(Data(DotfilesHomeToken.encode(text, home: env.home.path).utf8), executable: executable)
  }

  private func currentEntry(at url: URL, repoPath: String) -> Entry? {
    if repoPath.hasSuffix(DotfilesMemoryLayout.nestedRepositorySuffix) { return nil }
    guard fileManager.fileExists(atPath: url.path) || isSymlink(url) else { return nil }
    return entry(at: url, encode: true)
  }

  /// Writes a repository entry to `url`, expanding `{{HOME}}` when the
  /// destination is outside the repository.
  private func write(_ entry: Entry, to url: URL?) throws {
    guard let url else { return }
    let expand = !url.path.hasPrefix(env.repository.path + "/")
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if isSymlink(url) || (isDirectory(url) && !isSymlink(url)) {
      try fileManager.removeItem(at: url)
    }
    switch entry {
    case .symlink(let target):
      if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
      let resolved = expand ? DotfilesHomeToken.decode(target, home: env.home.path) : target
      try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: resolved)
    case .file(let data, let executable):
      var bytes = data
      if expand, !data.contains(0), let text = String(data: data, encoding: .utf8) {
        bytes = Data(DotfilesHomeToken.decode(text, home: env.home.path).utf8)
      }
      try bytes.write(to: url, options: .atomic)
      try fileManager.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }
  }

  private func cloneNestedRepository(_ entry: Entry, marker: URL) async throws -> Bool {
    guard case .file(let data, _) = entry,
      let remote = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
      DotfilesProjectIdentity.key(forRemote: remote) != nil
    else { return false }
    let path = String(marker.path.dropLast(DotfilesMemoryLayout.nestedRepositorySuffix.count))
    guard !fileManager.fileExists(atPath: path) else { return false }
    let destination = URL(fileURLWithPath: path)
    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try await env.gitNetwork(["clone", "-q", remote, path], destination.deletingLastPathComponent())
    return true
  }

  private func isSymlink(_ url: URL) -> Bool {
    (try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
  }

  private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  // MARK: - Claude project memory.

  /// Project key → this machine's memory folder for it
  /// (`~/.claude/projects/<encoded root>/memory`).
  private func memoryDirectoriesByKey(state: inout State) async -> [String: URL] {
    let projects = env.home.appending(path: ".claude/projects")
    var result: [String: URL] = [:]
    for root in env.knownRepositoryRoots {
      guard let key = await projectKey(forRoot: root.path) else { continue }
      let name = DotfilesProjectIdentity.claudeProjectDirectoryName(for: root.path)
      result[key] = projects.appending(path: name).appending(path: "memory")
    }
    let names = (try? fileManager.contentsOfDirectory(atPath: projects.path)) ?? []
    for name in names.sorted() {
      let memory = projects.appending(path: name).appending(path: "memory")
      guard isDirectory(memory) else { continue }
      if let key = state.memoryKeys[name] {
        if result[key] == nil { result[key] = memory }
        continue
      }
      guard let cwd = transcriptWorkingDirectory(in: projects.appending(path: name)),
        let root = await repositoryRoot(containing: cwd),
        DotfilesProjectIdentity.claudeProjectDirectoryName(for: root) == name,
        let key = await projectKey(forRoot: root)
      else { continue }
      state.memoryKeys[name] = key
      if result[key] == nil { result[key] = memory }
    }
    return result
  }

  private func transcriptWorkingDirectory(in folder: URL) -> String? {
    let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in names where name.hasSuffix(".jsonl") {
      guard let handle = try? FileHandle(forReadingFrom: folder.appending(path: name)) else { continue }
      defer { try? handle.close() }
      let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
      if let cwd = DotfilesProjectIdentity.cwd(inTranscript: String(bytes: data, encoding: .utf8) ?? "") { return cwd }
    }
    return nil
  }

  private func repositoryRoot(containing path: String) async -> String? {
    guard isDirectory(URL(fileURLWithPath: path)),
      let common = try? await git(
        ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: URL(fileURLWithPath: path)
      )
    else { return nil }
    guard common.hasSuffix("/.git") else { return nil }
    return String(common.dropLast(5))
  }

  private func projectKey(forRoot root: String) async -> String? {
    let url = URL(fileURLWithPath: root)
    guard isDirectory(url) else { return nil }
    if let remote = try? await git(["config", "--get", "remote.origin.url"], in: url),
      let key = DotfilesProjectIdentity.key(forRemote: remote)
    {
      return key
    }
    guard let commits = try? await git(["rev-list", "--max-parents=0", "HEAD"], in: url),
      let first = commits.split(separator: "\n").last
    else { return nil }
    return DotfilesProjectIdentity.key(forRootCommit: String(first))
  }

  // MARK: - State.

  private var stateURL: URL { env.repository.appending(path: ".git/kage-sync-state.json") }

  private func loadState() -> State? {
    guard let data = fileManager.contents(atPath: stateURL.path) else { return nil }
    return try? JSONDecoder().decode(State.self, from: data)
  }

  private func saveState(_ state: State) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try? encoder.encode(state).write(to: stateURL, options: .atomic)
  }

  /// Where a repository path lives on this machine; nil when it has no place
  /// here (memory of a project this machine doesn't have).
  struct Targets {
    var env: Environment
    var memoryDirectories: [String: URL]

    func localURL(for repoPath: String) -> URL? {
      if repoPath.hasPrefix(DotfilesMemoryLayout.prefix + "/") {
        let rest = repoPath.dropFirst(DotfilesMemoryLayout.prefix.count + 1)
        // Keys are host/owner/repo (or local/sha): match the longest one known.
        for (key, directory) in memoryDirectories.sorted(by: { $0.key.count > $1.key.count })
        where rest.hasPrefix(key + "/") {
          return directory.appending(path: String(rest.dropFirst(key.count + 1)))
        }
        return nil
      }
      for root in env.roots where repoPath.hasPrefix(root.repoPrefix + "/") {
        let relative = String(repoPath.dropFirst(root.repoPrefix.count + 1))
        return env.home.appending(path: root.localPath).appending(path: relative)
      }
      return nil
    }
  }
}
