import Foundation
import IdentifiedCollections
import SupacodeSettingsShared
import Testing

@testable import supacode

/// The host's Claude accounts in its snapshot, so a viewing Mac can open and
/// restart the host's tabs under them.
@MainActor
struct HostSnapshotClaudeAccountsTests {
  private let work = ClaudeAccount(
    id: "work", name: "Work", configDirectoryPath: "/Users/me/.kage/claude-accounts/work")

  private func repository() -> Repository {
    let root = URL(fileURLWithPath: "/tmp/a")
    let main = Worktree(
      id: WorktreeID("/tmp/a"), name: "main", detail: "", workingDirectory: root, repositoryRootURL: root)
    return Repository(
      id: RepositoryID("/tmp/a"), rootURL: root, name: "a", worktrees: IdentifiedArray(uniqueElements: [main]),
      isGitRepository: true, host: nil)
  }

  private func build(
    tabs: [HostSnapshotBuilder.TabInput],
    claudeAccounts: [HostSnapshot.ClaudeAccountInfo]?
  ) -> HostSnapshot {
    let repository = repository()
    return HostSnapshotBuilder.build(
      HostSnapshotBuilder.Inputs(
        repositories: [repository],
        sidebar: SidebarState(),
        tabsByWorktree: [repository.worktrees[0].id: tabs],
        agents: [],
        zmxPath: "/z",
        cliPath: "/c",
        kageVersion: "1.6.0",
        machineName: "Mini",
        claudeAccounts: claudeAccounts
      )
    )
  }

  @Test func everyAccountIsListedMainFirstWithTheDefaultMarked() {
    var file = ClaudeAccountsFile()
    file.accounts = [work]
    file.mainAccountName = "Personal"
    file.defaultAccountID = "work"
    #expect(
      HostSnapshotBuilder.claudeAccounts(file: file, usages: [:])
        == [
          HostSnapshot.ClaudeAccountInfo(id: "main", name: "Personal", menuTitle: "Personal", isDefault: false),
          HostSnapshot.ClaudeAccountInfo(id: "work", name: "Work", menuTitle: "Work", isDefault: true),
        ])
  }

  @Test func theAccountsAndEachTabsAccountReachTheSnapshot() throws {
    let accounts = [HostSnapshot.ClaudeAccountInfo(id: "work", name: "Work", menuTitle: "Work", isDefault: true)]
    let tab = HostSnapshotBuilder.TabInput(
      id: UUID(), title: "zsh", isFocused: true, surfaceID: UUID(), isTerminal: true, usesZmx: true,
      workingDirectory: nil, claudeAccountID: "work")
    let snapshot = build(tabs: [tab], claudeAccounts: accounts)
    #expect(snapshot.claudeAccounts == accounts)
    #expect(snapshot.repositories.first?.worktrees.first?.tabs.first?.claudeAccountID == "work")

    let json = try HostSnapshotBuilder.encodeJSON(snapshot)
    #expect(try JSONDecoder().decode(HostSnapshot.self, from: Data(json.utf8)) == snapshot)
  }

  @Test func aSnapshotFromAHostThatPredatesAccountsStillDecodes() throws {
    let json = """
      {"schemaVersion":1,"kageVersion":"1.5.0","machineName":"M","workspaces":[],"repositories":[
      {"id":"/r","name":"r","rootPath":"/r","isGitRepository":true,"worktrees":[
      {"id":"/r","name":"main","path":"/r","isMain":true,"isPinned":false,"tabs":[
      {"id":"t","title":"zsh","isFocused":true,"surfaceID":"s","agents":[]}]}]}]}
      """
    let decoded = try JSONDecoder().decode(HostSnapshot.self, from: Data(json.utf8))
    #expect(decoded.claudeAccounts == nil)
    #expect(decoded.repositories.first?.worktrees.first?.tabs.first?.claudeAccountID == nil)
  }
}
