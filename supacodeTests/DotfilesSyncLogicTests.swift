import Foundation
import Testing

@testable import supacode

struct DotfilesHomeTokenTests {
  private let home = "/Users/alice"

  @Test func homePathBecomesTheToken() {
    let text = #"{"command": "/Users/alice/.claude/statusline.sh", "cwd": "/Users/alice"}"#
    let encoded = DotfilesHomeToken.encode(text, home: home)
    #expect(encoded == #"{"command": "{{HOME}}/.claude/statusline.sh", "cwd": "{{HOME}}"}"#)
    #expect(
      DotfilesHomeToken.decode(encoded, home: "/Users/bob")
        == #"{"command": "/Users/bob/.claude/statusline.sh", "cwd": "/Users/bob"}"#)
  }

  @Test func longerUserNamesAreLeftAlone() {
    #expect(
      DotfilesHomeToken.encode("/Users/alice2/x and /Users/alice.bak", home: home)
        == "/Users/alice2/x and /Users/alice.bak")
  }
}

struct DotfilesProjectIdentityTests {
  @Test(arguments: [
    ("git@github.com:Owner/Repo.git", "github.com/owner/repo"),
    ("https://github.com/owner/repo", "github.com/owner/repo"),
    ("https://user:tok@github.com/owner/repo.git/", "github.com/owner/repo"),
    ("ssh://git@github.com:22/owner/repo.git", "github.com/owner/repo"),
    ("git@gitlab.example.com:group/sub/repo.git", "gitlab.example.com/group/sub/repo"),
  ])
  func remotesNormalizeToOneKey(remote: String, key: String) {
    #expect(DotfilesProjectIdentity.key(forRemote: remote) == key)
  }

  @Test func localRemotesHaveNoKey() {
    #expect(DotfilesProjectIdentity.key(forRemote: "/Users/alice/repos/x.git") == nil)
    #expect(DotfilesProjectIdentity.key(forRemote: "file:///tmp/x") == nil)
  }

  @Test func claudeProjectDirectoryName() {
    #expect(
      DotfilesProjectIdentity.claudeProjectDirectoryName(for: "/Users/alice/Developer/sides/.my_app")
        == "-Users-alice-Developer-sides--my-app"
    )
  }

  @Test func cwdIsReadFromATranscript() {
    let line = #"{"type":"user","cwd":"/Users/alice/Developer/kage","sessionId":"x"}"#
    #expect(DotfilesProjectIdentity.cwd(inTranscript: "{}\n" + line) == "/Users/alice/Developer/kage")
    #expect(DotfilesProjectIdentity.cwd(inTranscript: "{}") == nil)
  }
}

struct DotfilesSecretScannerTests {
  @Test(arguments: [
    "ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123",
    #"{"env": {"GITHUB_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123456789"}}"#,
    "key: AKIAABCDEFGHIJKLMNOP",
    "-----BEGIN OPENSSH PRIVATE KEY-----",
    #"{"apiKey": "a8f5f167f44f4964e6c998dee827110c"}"#,
    "token = \"xoxb-1234567890-abcdefghij\"",
  ])
  func secretsAreFound(text: String) {
    #expect(DotfilesSecretScanner.containsSecret(text))
  }

  @Test(arguments: [
    #"{"permissions": {"allow": ["Bash(git status)"]}, "model": "opus"}"#,
    "Use the API key from the Keychain; never paste a token here.",
    #"{"apiKeyHelper": "{{HOME}}/.claude/key.sh"}"#,
    #"headers: {"xi-api-key": process.env.ELEVENLABS_API_KEY!}"#,
  ])
  func ordinaryTextIsNot(text: String) {
    #expect(!DotfilesSecretScanner.containsSecret(text))
  }
}

struct DotfilesJSONMergeTests {
  private func json(_ string: String) -> DotfilesJSONMerge.Value {
    (try? DotfilesJSONMerge.Value.parse(Data(string.utf8))) ?? .null
  }

  @Test func independentKeysFromBothSidesAreKept() {
    let result = DotfilesJSONMerge.merge(
      base: json(#"{"a": 1}"#),
      ours: json(#"{"a": 1, "b": 2}"#),
      theirs: json(#"{"a": 1, "c": 3}"#)
    )
    #expect(result.value == json(#"{"a": 1, "b": 2, "c": 3}"#))
    #expect(result.conflicts.isEmpty)
  }

  @Test func oneSidedChangesAndRemovalsWin() {
    let result = DotfilesJSONMerge.merge(
      base: json(#"{"a": 1, "b": 2, "c": 3}"#),
      ours: json(#"{"a": 9, "b": 2, "c": 3}"#),
      theirs: json(#"{"a": 1, "c": 3}"#)
    )
    #expect(result.value == json(#"{"a": 9, "c": 3}"#))
  }

  @Test func arraysMergeAsSetsHonoringRemovals() {
    let result = DotfilesJSONMerge.merge(
      base: json(#"{"allow": ["x", "y"]}"#),
      ours: json(#"{"allow": ["x", "y", "ours"]}"#),
      theirs: json(#"{"allow": ["y", "theirs"]}"#)
    )
    #expect(result.value == json(#"{"allow": ["y", "ours", "theirs"]}"#))
  }

  @Test func clashingScalarsKeepOursAndAreReported() {
    let result = DotfilesJSONMerge.merge(
      base: json(#"{"model": "a"}"#),
      ours: json(#"{"model": "b"}"#),
      theirs: json(#"{"model": "c"}"#)
    )
    #expect(result.value == json(#"{"model": "b"}"#))
    #expect(result.conflicts == ["model"])
  }

  @Test func missingBaseMeansBothAdded() {
    let result = DotfilesJSONMerge.merge(base: nil, ours: json(#"{"a": [1]}"#), theirs: json(#"{"a": [2], "b": true}"#))
    #expect(result.value == json(#"{"a": [1, 2], "b": true}"#))
  }
}

struct DotfilesConflictResolverTests {
  @Test func fencedOutputIsUnwrapped() {
    #expect(DotfilesConflictResolver.cleanedOutput("```markdown\n# Title\nbody\n```\n") == "# Title\nbody\n")
    #expect(DotfilesConflictResolver.cleanedOutput("# Title\n") == "# Title\n")
  }

  @Test func outputWithMarkersOrEmptyIsRejected() {
    #expect(!DotfilesConflictResolver.isAcceptable("", ours: "a", theirs: "b"))
    #expect(
      !DotfilesConflictResolver.isAcceptable("<<<<<<< ours\na\n=======\nb\n>>>>>>> theirs\n", ours: "a", theirs: "b"))
    #expect(DotfilesConflictResolver.isAcceptable("a\nb\n", ours: "a\n", theirs: "b\n"))
  }

  @Test func drasticallyShorterOutputIsRejected() {
    let long = String(repeating: "line of notes\n", count: 50)
    #expect(!DotfilesConflictResolver.isAcceptable("short\n", ours: long, theirs: long))
  }
}
