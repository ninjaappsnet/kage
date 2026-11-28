import Foundation
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct ClaudeRelaunchEnvironmentTests {
  private let tabID = UUID()

  @Test func stagedVariablesReachTheTabsNextSurfaceOnce() {
    ClaudeRelaunchEnvironment.stage(["ANTHROPIC_CUSTOM_HEADERS": "X-Key: abc"], forTab: tabID)
    #expect(ClaudeRelaunchEnvironment.take(forTab: UUID()) == [:])
    #expect(ClaudeRelaunchEnvironment.take(forTab: tabID) == ["ANTHROPIC_CUSTOM_HEADERS": "X-Key: abc"])
    #expect(ClaudeRelaunchEnvironment.take(forTab: tabID) == [:])
  }

  @Test func aStagedEnvironmentThatOutlivesItsRestartIsDropped() {
    ClaudeRelaunchEnvironment.stage(["CLAUDE_CODE_X_TOKEN": "t"], forTab: tabID)
    let late = ContinuousClock.now.advanced(by: ClaudeRelaunchEnvironment.lifetime + .seconds(1))
    #expect(ClaudeRelaunchEnvironment.take(forTab: tabID, now: late) == [:])
    #expect(ClaudeRelaunchEnvironment.take(forTab: tabID) == [:])
  }

  @Test func stagingNothingLeavesNothing() {
    ClaudeRelaunchEnvironment.stage([:], forTab: tabID)
    #expect(ClaudeRelaunchEnvironment.take(forTab: tabID) == [:])
  }
}
