import Foundation
import Testing

@testable import supacode

// MARK: - The command that restarts Claude Code the way it was started.

struct ClaudeLaunchReplayTests {
  private let session = "4e7fcb91-bc51-4718-8aa6-9d3e02009ac5"
  private let shell: [String: String] = [
    "PATH": "/usr/bin:/bin",
    "HOME": "/Users/me",
    "CLAUDE_CONFIG_DIR": "/Users/me/.kage/claude-accounts/work",
  ]

  private func relaunch(
    _ arguments: [String],
    adding extra: [String: String] = [:],
    parent: [String: String]? = nil,
    sessionID: String? = nil
  ) -> ClaudeLaunchReplay.Relaunch? {
    ClaudeLaunchReplay.relaunch(
      launch: ClaudeLaunchReplay.Launch(arguments: arguments, environment: shell.merging(extra) { _, new in new }),
      parentEnvironment: parent ?? shell,
      sessionID: sessionID
    )
  }

  @Test func anInlineExperimentalVariableAndTheFlagsComeBackWithTheExactSession() {
    let result = relaunch(
      ["claude", "--dangerously-skip-permissions"],
      adding: ["CLAUDE_CODE_EXPERIMENTAL_CODE_MODE": "1"],
      sessionID: session
    )
    #expect(
      result?.command
        == "CLAUDE_CODE_EXPERIMENTAL_CODE_MODE=1 claude --dangerously-skip-permissions --resume \(session)")
    #expect(result?.environment == [:])
  }

  @Test func withoutAKnownSessionTheFolderLatestConversationIsContinued() {
    #expect(relaunch(["claude"])?.command == "claude --continue")
    #expect(relaunch(["claude"], sessionID: "not-a-uuid")?.command == "claude --continue")
  }

  @Test func variablesTheShellAlreadyHadAreNotTypedAgain() {
    let parent = shell.merging(["CLAUDE_CODE_EXPERIMENTAL_CODE_MODE": "1"]) { _, new in new }
    let result = relaunch(["claude"], adding: ["CLAUDE_CODE_EXPERIMENTAL_CODE_MODE": "1"], parent: parent)
    #expect(result?.command == "claude --continue")
  }

  @Test func aChangedValueIsTyped() {
    let parent = shell.merging(["ANTHROPIC_MODEL": "sonnet"]) { _, new in new }
    let result = relaunch(["claude"], adding: ["ANTHROPIC_MODEL": "opus"], parent: parent)
    #expect(result?.command == "ANTHROPIC_MODEL=opus claude --continue")
  }

  @Test func theAccountDirectoryIsNeverCarriedSinceItIsWhatTheRestartChanges() {
    let result = relaunch(["claude"], adding: ["CLAUDE_CONFIG_DIR": "/somewhere/else"])
    #expect(result?.command == "claude --continue")
    #expect(result?.environment == [:])
  }

  @Test func credentialsThatWouldOverrideTheNewAccountLoginAreDropped() {
    let result = relaunch(
      ["claude"],
      adding: [
        "ANTHROPIC_API_KEY": "sk-ant-123",
        "ANTHROPIC_AUTH_TOKEN": "tok",
        "CLAUDE_CODE_OAUTH_TOKEN": "oauth",
      ]
    )
    #expect(result?.command == "claude --continue")
    #expect(result?.environment == [:])
  }

  @Test func secretLookingVariablesRideTheSessionEnvironmentInsteadOfTheTypedLine() {
    let result = relaunch(
      ["claude"],
      adding: ["ANTHROPIC_CUSTOM_HEADERS": "X-Key: abc", "CLAUDE_CODE_PROXY_PASSWORD": "pw", "DISABLE_TELEMETRY": "1"]
    )
    #expect(result?.command == "DISABLE_TELEMETRY=1 claude --continue")
    #expect(result?.environment == ["ANTHROPIC_CUSTOM_HEADERS": "X-Key: abc", "CLAUDE_CODE_PROXY_PASSWORD": "pw"])
  }

  @Test func variablesUnrelatedToClaudeCodeAreLeftAlone() {
    #expect(relaunch(["claude"], adding: ["FOO": "1", "NODE_OPTIONS": "--x"])?.command == "claude --continue")
  }

  @Test func typedVariablesAreSortedAndQuoted() {
    let result = relaunch(
      ["claude"],
      adding: ["CLAUDE_CODE_B": "two words", "CLAUDE_CODE_A": "it's"]
    )
    #expect(result?.command == "CLAUDE_CODE_A='it'\\''s' CLAUDE_CODE_B='two words' claude --continue")
  }

  @Test func aValueWithAControlCharacterIsNeverTypedButStillCarried() {
    let result = relaunch(["claude"], adding: ["CLAUDE_CODE_X": "a\nb"])
    #expect(result?.command == "claude --continue")
    #expect(result?.environment == ["CLAUDE_CODE_X": "a\nb"])
  }

  @Test func conversationSelectingFlagsAreReplacedByTheResume() {
    #expect(
      relaunch(["claude", "-c", "--model", "opus"], sessionID: session)?.command
        == "claude --model opus --resume \(session)")
    #expect(relaunch(["claude", "--continue", "--verbose"])?.command == "claude --verbose --continue")
    #expect(relaunch(["claude", "--resume", "abc", "--verbose"])?.command == "claude --verbose --continue")
    #expect(relaunch(["claude", "-r", "--verbose"])?.command == "claude --verbose --continue")
    #expect(relaunch(["claude", "--resume=abc"])?.command == "claude --continue")
    #expect(relaunch(["claude", "--session-id", session, "--fork-session"])?.command == "claude --continue")
    #expect(relaunch(["claude", "--from-pr", "12", "--teleport"])?.command == "claude --continue")
  }

  @Test func worktreeFlagsAreDroppedBecauseTheShellIsAlreadyInThatFolder() {
    #expect(relaunch(["claude", "-w", "feature", "--tmux=classic"])?.command == "claude --continue")
    #expect(relaunch(["claude", "--worktree", "--verbose"])?.command == "claude --verbose --continue")
  }

  @Test func theStartingPromptIsNotSentAgain() {
    #expect(relaunch(["claude", "--model", "opus", "fix the bug"])?.command == "claude --model opus --continue")
    #expect(relaunch(["claude", "fix the bug", "--verbose"])?.command == "claude --verbose --continue")
    #expect(relaunch(["claude", "--verbose", "--", "-not-a-flag"])?.command == "claude --verbose --continue")
  }

  @Test func listAndOptionalValueFlagsKeepTheValuesClaudeCodeParsed() {
    #expect(
      relaunch(["claude", "--add-dir", "/a", "/b", "--verbose"])?.command
        == "claude --add-dir /a /b --verbose --continue")
    #expect(relaunch(["claude", "--debug", "hooks"])?.command == "claude --debug hooks --continue")
    #expect(relaunch(["claude", "--debug", "--verbose"])?.command == "claude --debug --verbose --continue")
    #expect(
      relaunch(["claude", "--model=opus", "-n", "my session"])?.command
        == "claude --model=opus -n 'my session' --continue")
  }

  @Test func valuesAreQuotedForTheShell() {
    #expect(
      relaunch(["claude", "--append-system-prompt", "be terse; it's fine"])?.command
        == "claude --append-system-prompt 'be terse; it'\\''s fine' --continue")
  }

  @Test func anUnknownFlagThatMayTakeAValueDropsTheFlagsButKeepsTheVariables() {
    let result = relaunch(
      ["claude", "--brand-new", "thing", "--verbose"], adding: ["CLAUDE_CODE_EXPERIMENTAL_CODE_MODE": "1"])
    #expect(result?.command == "CLAUDE_CODE_EXPERIMENTAL_CODE_MODE=1 claude --continue")
  }

  @Test func anUnknownFlagWithNothingAfterItIsKept() {
    #expect(relaunch(["claude", "--brand-new"])?.command == "claude --brand-new --continue")
    #expect(relaunch(["claude", "--brand-new", "--verbose"])?.command == "claude --brand-new --verbose --continue")
  }

  @Test func anArgumentWithAControlCharacterDropsTheFlags() {
    #expect(relaunch(["claude", "--append-system-prompt", "a\nb", "--verbose"])?.command == "claude --continue")
  }

  @Test func aNonInteractiveRunIsNotRelaunched() {
    #expect(relaunch(["claude", "-p", "hi"]) == nil)
    #expect(relaunch(["claude", "--print", "hi"]) == nil)
    #expect(relaunch(["claude", "--bg"]) == nil)
    #expect(relaunch(["claude", "attach", "abc"]) == nil)
  }

  @Test func onlyAClaudeProcessIsRelaunched() {
    #expect(relaunch(["/bin/zsh", "-l"]) == nil)
    #expect(relaunch([]) == nil)
    #expect(relaunch(["/Users/me/.local/bin/claude", "--verbose"])?.command == "claude --verbose --continue")
    #expect(
      relaunch(["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js", "--verbose"])?.command
        == "claude --verbose --continue")
  }

  // MARK: Session file.

  @Test func theSessionIDIsReadFromClaudeCodesFileForThatProcess() {
    let json = #"{"pid":9900,"sessionId":"\#(session)","cwd":"/tmp"}"#
    #expect(ClaudeLaunchReplay.sessionID(fromSessionFile: Data(json.utf8), pid: 9900) == session)
  }

  @Test func aSessionFileForAnotherProcessOrWithoutAnIDIsIgnored() {
    let other = #"{"pid":1234,"sessionId":"\#(session)"}"#
    #expect(ClaudeLaunchReplay.sessionID(fromSessionFile: Data(other.utf8), pid: 9900) == nil)
    #expect(ClaudeLaunchReplay.sessionID(fromSessionFile: Data(#"{"pid":9900}"#.utf8), pid: 9900) == nil)
    #expect(ClaudeLaunchReplay.sessionID(fromSessionFile: Data("nope".utf8), pid: 9900) == nil)
  }

  // MARK: Which process.

  @Test func theOutermostTrackedProcessIsTheSessionToRelaunch() {
    // 30 runs under 20 (a subagent shell); 20 is the root.
    let parents: [pid_t: pid_t] = [20: 10, 30: 20]
    #expect(ClaudeLaunchReplay.rootPID(of: [20, 30], parent: { parents[$0] }) == 20)
    #expect(ClaudeLaunchReplay.rootPID(of: [], parent: { parents[$0] }) == nil)
    // Two unrelated sessions: the newest (highest pid) wins, deterministically.
    #expect(ClaudeLaunchReplay.rootPID(of: [20, 40], parent: { _ in 1 }) == 40)
  }
}
