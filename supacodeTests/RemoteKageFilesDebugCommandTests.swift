import Testing

@testable import supacode

nonisolated struct RemoteKageFilesDebugCommandTests {
  @Test func parsesVerbAndArgument() {
    #expect(
      RemoteKageFilesDebugCommand.parse("open:/Users/me/a:b.txt")
        == RemoteKageFilesDebugCommand(verb: "open", argument: "/Users/me/a:b.txt"))
    #expect(RemoteKageFilesDebugCommand.parse("save") == RemoteKageFilesDebugCommand(verb: "save", argument: ""))
  }
}
