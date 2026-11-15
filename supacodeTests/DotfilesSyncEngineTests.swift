import Foundation
import Testing

@testable import supacode

/// Two machines (`alice` and `bob` home folders, different user names and
/// checkout paths) syncing through a real bare repository.
struct DotfilesSyncEngineTests {
  private let sandbox: URL
  private let remote: URL

  init() throws {
    sandbox = FileManager.default.temporaryDirectory
      .appending(path: "kage-dotfiles-\(UUID().uuidString)")
      .resolvingSymlinksInPath()
    remote = sandbox.appending(path: "remote.git")
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    try Self.runGit(["init", "-q", "--bare", "-b", "main", remote.path], in: sandbox)
  }

  // MARK: - Harness.

  @discardableResult
  nonisolated private static func runGit(_ arguments: [String], in directory: URL) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    process.environment = environment
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let message = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw DotfilesGitError(arguments: arguments, message: String(bytes: message, encoding: .utf8) ?? "")
    }
    return data
  }

  private func home(_ name: String) -> URL { sandbox.appending(path: "Users/\(name)") }

  private func engine(
    _ name: String,
    knownRoots: [URL] = [],
    resolveText: @escaping @Sendable (String, String?, String, String) async -> String? = { _, _, _, _ in nil }
  ) -> DotfilesSyncEngine {
    let home = home(name)
    return DotfilesSyncEngine(
      environment: .init(
        home: home,
        repository: home.appending(path: ".kage/dotfiles"),
        remoteURL: remote.path,
        conflictsDirectory: home.appending(path: ".kage/dotfiles-conflicts"),
        roots: DotfilesSyncRoot.defaults(kageConfigPath: ".config/kage"),
        knownRepositoryRoots: knownRoots,
        machineName: name,
        git: { arguments, directory in try Self.runGit(arguments, in: directory) },
        gitNetwork: { arguments, directory in try Self.runGit(arguments, in: directory) },
        resolveText: resolveText
      )
    )
  }

  private func write(_ text: String, _ path: String, in home: URL) throws {
    let url = home.appending(path: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private func read(_ path: String, in home: URL) -> String? {
    FileManager.default.contents(atPath: home.appending(path: path).path).flatMap { String(bytes: $0, encoding: .utf8) }
  }

  /// A checkout of the same project at `path` under `home`, plus Claude's memory for it.
  private func project(at path: String, in home: URL, memory: String? = nil) throws -> URL {
    let root = home.appending(path: path)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Self.runGit(["init", "-q"], in: root)
    try Self.runGit(["remote", "add", "origin", "git@github.com:Owner/Proj.git"], in: root)
    if let memory {
      let folder = DotfilesProjectIdentity.claudeProjectDirectoryName(for: root.path)
      try write(memory, ".claude/projects/\(folder)/memory/MEMORY.md", in: home)
    }
    return root
  }

  private func memoryPath(for root: URL) -> String {
    ".claude/projects/\(DotfilesProjectIdentity.claudeProjectDirectoryName(for: root.path))/memory/MEMORY.md"
  }

  // MARK: - Tests.

  @Test func settingsAndMemoryReachAnotherMachineUnderItsOwnPaths() async throws {
    let alice = home("alice")
    let bob = home("bob")
    try write(#"{"statusLine": {"command": "\#(alice.path)/.claude/status.sh"}}"#, ".claude/settings.json", in: alice)
    try write("# Rules\n", ".claude/CLAUDE.md", in: alice)
    try write("skill body\n", ".claude/skills/demo/SKILL.md", in: alice)
    try write("never synced\n", ".claude/history.jsonl", in: alice)
    try write("font-size = 14\n", ".config/kage/config.ghostty", in: alice)
    let aliceProject = try project(at: "code/proj", in: alice, memory: "- remembered\n")
    let bobProject = try project(at: "work/projects/proj", in: bob)

    let first = try await engine("alice", knownRoots: [aliceProject]).sync()
    #expect(first.pushed)
    _ = try await engine("bob", knownRoots: [bobProject]).sync()

    #expect(read(".claude/settings.json", in: bob) == #"{"statusLine": {"command": "\#(bob.path)/.claude/status.sh"}}"#)
    #expect(read(".claude/CLAUDE.md", in: bob) == "# Rules\n")
    #expect(read(".claude/skills/demo/SKILL.md", in: bob) == "skill body\n")
    #expect(read(".config/kage/config.ghostty", in: bob) == "font-size = 14\n")
    #expect(read(".claude/history.jsonl", in: bob) == nil)
    #expect(read(memoryPath(for: bobProject), in: bob) == "- remembered\n")
    let stored = try Self.runGit(["show", "main:claude/settings.json"], in: remote)
    #expect((String(bytes: stored, encoding: .utf8) ?? "").contains("{{HOME}}/.claude/status.sh"))
    let memory = try Self.runGit(["show", "main:claude-memory/github.com/owner/proj/MEMORY.md"], in: remote)
    #expect(String(bytes: memory, encoding: .utf8) == "- remembered\n")
  }

  @Test func deletionsPropagateButUnknownProjectsAreNotDeleted() async throws {
    let alice = home("alice")
    let bob = home("bob")
    try write("# Rules\n", ".claude/CLAUDE.md", in: alice)
    let aliceProject = try project(at: "code/proj", in: alice, memory: "- remembered\n")
    _ = try await engine("alice", knownRoots: [aliceProject]).sync()
    // Bob doesn't have the project: its memory must survive his passes.
    _ = try await engine("bob").sync()
    #expect(read(".claude/CLAUDE.md", in: bob) == "# Rules\n")

    try FileManager.default.removeItem(at: bob.appending(path: ".claude/CLAUDE.md"))
    let report = try await engine("bob").sync()
    #expect(report.pushed)
    _ = try await engine("alice", knownRoots: [aliceProject]).sync()
    #expect(read(".claude/CLAUDE.md", in: alice) == nil)
    #expect(read(memoryPath(for: aliceProject), in: alice) == "- remembered\n")
  }

  @Test func jsonEditsOnBothMachinesMerge() async throws {
    let alice = home("alice")
    let bob = home("bob")
    try write(#"{"model": "opus"}"#, ".claude/settings.json", in: alice)
    _ = try await engine("alice").sync()
    _ = try await engine("bob").sync()

    try write(#"{"model": "opus", "theme": "dark"}"#, ".claude/settings.json", in: alice)
    try write(#"{"model": "opus", "permissions": {"allow": ["Bash(ls)"]}}"#, ".claude/settings.json", in: bob)
    _ = try await engine("alice").sync()
    _ = try await engine("bob").sync()
    _ = try await engine("alice").sync()

    for home in [alice, bob] {
      let data = try #require(FileManager.default.contents(atPath: home.appending(path: ".claude/settings.json").path))
      let value = try DotfilesJSONMerge.Value.parse(data)
      #expect(
        value
          == (try DotfilesJSONMerge.Value.parse(
            Data(#"{"model": "opus", "theme": "dark", "permissions": {"allow": ["Bash(ls)"]}}"#.utf8)
          ))
      )
    }
  }

  @Test func clashingTextGoesToTheResolverThenFallsBackToLocal() async throws {
    let alice = home("alice")
    let bob = home("bob")
    try write("line\n", ".claude/CLAUDE.md", in: alice)
    _ = try await engine("alice").sync()
    _ = try await engine("bob").sync()
    try write("alice line\n", ".claude/CLAUDE.md", in: alice)
    try write("bob line\n", ".claude/CLAUDE.md", in: bob)
    _ = try await engine("alice").sync()

    let resolved = try await engine(
      "bob",
      resolveText: { _, base, ours, theirs in
        #expect(base == "line\n")
        return ours + theirs
      }
    ).sync()
    #expect(resolved.resolvedByClaude == ["claude/CLAUDE.md"])
    #expect(read(".claude/CLAUDE.md", in: bob) == "bob line\nalice line\n")

    try write("alice again\n", ".claude/CLAUDE.md", in: alice)
    try write("bob again\n", ".claude/CLAUDE.md", in: bob)
    _ = try await engine("alice").sync()
    let unresolved = try await engine("bob").sync()
    #expect(unresolved.unresolved == ["claude/CLAUDE.md"])
    #expect(read(".claude/CLAUDE.md", in: bob) == "bob again\n")
    #expect(read(".kage/dotfiles-conflicts/claude/CLAUDE.md", in: bob) == "alice again\n")
  }

  @Test func filesWithSecretsStayLocal() async throws {
    let alice = home("alice")
    try write(
      #"{"env": {"ANTHROPIC_API_KEY": "sk-ant-api03-abcdefghijklmnopqrstuvwxyz"}}"#, ".claude/settings.json", in: alice)
    try write("# Rules\n", ".claude/CLAUDE.md", in: alice)
    let report = try await engine("alice").sync()
    #expect(report.blockedSecrets == ["claude/settings.json"])
    #expect((try? Self.runGit(["show", "main:claude/settings.json"], in: remote)) == nil)
    #expect(read(".claude/settings.json", in: alice)?.contains("sk-ant") == true)
  }

  @Test func firstPassOnASecondMachineMergesInsteadOfOverwriting() async throws {
    let alice = home("alice")
    let bob = home("bob")
    try write(#"{"permissions": {"allow": ["A"]}}"#, ".claude/settings.json", in: alice)
    _ = try await engine("alice").sync()
    try write(#"{"permissions": {"allow": ["B"]}}"#, ".claude/settings.json", in: bob)
    _ = try await engine("bob").sync()
    let data = try #require(FileManager.default.contents(atPath: bob.appending(path: ".claude/settings.json").path))
    #expect(
      try DotfilesJSONMerge.Value.parse(data)
        == DotfilesJSONMerge.Value.parse(Data(#"{"permissions": {"allow": ["B", "A"]}}"#.utf8)))
  }

  @Test func symlinkedSkillsStayLinks() async throws {
    let alice = home("alice")
    let bob = home("bob")
    try write("shared\n", ".agents/skills/tool/SKILL.md", in: alice)
    try FileManager.default.createDirectory(
      at: alice.appending(path: ".claude/skills"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: alice.appending(path: ".claude/skills/tool").path,
      withDestinationPath: "../../.agents/skills/tool"
    )
    _ = try await engine("alice").sync()
    _ = try await engine("bob").sync()
    let link = try FileManager.default.destinationOfSymbolicLink(
      atPath: bob.appending(path: ".claude/skills/tool").path)
    #expect(link == "../../.agents/skills/tool")
    #expect(read(".claude/skills/tool/SKILL.md", in: bob) == "shared\n")
  }
}
