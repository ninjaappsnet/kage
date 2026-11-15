import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

// MARK: - Inheriting the source tab's account.

struct ClaudeAccountInheritanceTests {
  private let work = ClaudeAccount(id: "work", name: "Work", configDirectoryPath: "/tmp/kage-claude/work")
  private let tabID = UUID()
  private let sourceContentID = UUID()

  private func file(_ configure: (inout ClaudeAccountsFile) -> Void = { _ in }) -> ClaudeAccountsFile {
    var file = ClaudeAccountsFile()
    file.accounts = [work]
    configure(&file)
    return file
  }

  @Test func newTabFromAWorkSurfaceInheritsWork() {
    let inherited = ClaudeAccountEnvironment.inheritedAccountID(
      tabID: tabID, origin: .tab, inheritedFrom: sourceContentID,
      file: file(), surfaceAccounts: [sourceContentID: "work"])
    #expect(inherited == "work")
  }

  @Test func splitsInheritToo() {
    let inherited = ClaudeAccountEnvironment.inheritedAccountID(
      tabID: tabID, origin: .split, inheritedFrom: sourceContentID,
      file: file(), surfaceAccounts: [sourceContentID: "work"])
    #expect(inherited == "work")
  }

  @Test func anExplicitTabAssignmentWins() {
    let inherited = ClaudeAccountEnvironment.inheritedAccountID(
      tabID: tabID, origin: .tab, inheritedFrom: sourceContentID,
      file: file { $0.tabAccountIDs[tabID.uuidString] = ClaudeAccount.mainID },
      surfaceAccounts: [sourceContentID: "work"])
    #expect(inherited == nil)
  }

  @Test func restoredContentNeverInherits() {
    let inherited = ClaudeAccountEnvironment.inheritedAccountID(
      tabID: tabID, origin: .restored, inheritedFrom: sourceContentID,
      file: file(), surfaceAccounts: [sourceContentID: "work"])
    #expect(inherited == nil)
  }

  @Test func unknownOrRemovedSourceAccountFallsThrough() {
    #expect(
      ClaudeAccountEnvironment.inheritedAccountID(
        tabID: tabID, origin: .tab, inheritedFrom: sourceContentID, file: file(), surfaceAccounts: [:]) == nil)
    #expect(
      ClaudeAccountEnvironment.inheritedAccountID(
        tabID: tabID, origin: .tab, inheritedFrom: sourceContentID,
        file: file(), surfaceAccounts: [sourceContentID: "gone"]) == nil)
    #expect(
      ClaudeAccountEnvironment.inheritedAccountID(
        tabID: tabID, origin: .tab, inheritedFrom: nil, file: file(), surfaceAccounts: [sourceContentID: "work"])
        == nil)
  }
}

// MARK: - Forgetting closed tabs.

struct ClaudeAccountTabPruneTests {
  private static func layout(tabIDs: [TabID]) -> PaneLayout {
    let paneID = PaneID()
    return PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: IdentifiedArray(
            uniqueElements: tabIDs.map { tabID in
              TabItem(
                id: tabID, title: "Tab",
                content: ContentSnapshot(
                  id: ContentID(), state: .terminal(TerminalContentState(workingDirectory: nil))))
            }),
          selectedTabID: tabIDs.first
        )
      ],
      focusedPaneID: paneID
    )
  }

  @Test func assignmentsForTabsMissingFromEveryLayoutAreDropped() {
    let kept = TabID()
    let other = TabID()
    let layouts = LayoutsFile(worktrees: [
      "/tmp/a": LayoutRecord(layout: Self.layout(tabIDs: [kept])),
      "/tmp/b": LayoutRecord(layout: Self.layout(tabIDs: [other])),
    ])
    var file = ClaudeAccountsFile()
    file.tabAccountIDs = [
      kept.rawValue.uuidString: "work",
      other.rawValue.uuidString: "main",
      UUID().uuidString: "work",
    ]
    let pruned = file.pruneTabAssignments(toTabsIn: layouts)
    #expect(pruned)
    #expect(file.tabAccountIDs == [kept.rawValue.uuidString: "work", other.rawValue.uuidString: "main"])
  }

  @Test func aLossyLayoutsFileLeavesAssignmentsAlone() {
    var layouts = LayoutsFile(worktrees: [:])
    layouts.undecodedEntryCount = 1
    var file = ClaudeAccountsFile()
    file.tabAccountIDs = [UUID().uuidString: "work"]
    let pruned = file.pruneTabAssignments(toTabsIn: layouts)
    #expect(!pruned)
    #expect(file.tabAccountIDs.count == 1)
  }
}

// MARK: - Picking an account from the tab strip menu.

struct ClaudeAccountRequestedTabTests {
  private let work = ClaudeAccount(id: "work", name: "Work", configDirectoryPath: "/tmp/kage-claude/work")

  @Test func aRequestedAccountBeatsTheSourceSurfaceAccount() {
    var file = ClaudeAccountsFile()
    file.accounts = [work]
    let source = UUID()
    let inherited = ClaudeAccountEnvironment.inheritedAccountID(
      tabID: UUID(), origin: .tab, inheritedFrom: source, requested: "work",
      file: file, surfaceAccounts: [source: ClaudeAccount.mainID])
    #expect(inherited == "work")
  }

  @MainActor
  @Test func aRequestIsConsumedOnceAndExpires() {
    ClaudeSurfaceAccounts.requestAccountForNextTab("work")
    #expect(ClaudeSurfaceAccounts.takeRequestedAccount() == "work")
    #expect(ClaudeSurfaceAccounts.takeRequestedAccount() == nil)

    ClaudeSurfaceAccounts.requestAccountForNextTab("work")
    let late = ContinuousClock.now.advanced(by: ClaudeSurfaceAccounts.requestLifetime + .seconds(1))
    #expect(ClaudeSurfaceAccounts.takeRequestedAccount(now: late) == nil)
  }
}

// MARK: - Naming the main account.

@MainActor
struct ClaudeMainAccountNameTests {
  @Test(.dependencies) func theMainAccountCanBeRenamed() async {
    let state = ClaudeAccountsFeature.State()
    state.$file.withLock { $0 = ClaudeAccountsFile() }
    let store = TestStore(initialState: state) { ClaudeAccountsFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.renameAccount(ClaudeAccount.mainID, "  Personal "))
    #expect(store.state.file.mainAccountName == "Personal")
    #expect(store.state.file.allAccounts.first?.name == "Personal")
    #expect(store.state.file.allAccounts.first?.isMain == true)
  }

  @Test func fallbackResolutionKeepsTheMainName() {
    var file = ClaudeAccountsFile()
    file.mainAccountName = "Personal"
    #expect(file.resolvedAccount(tabID: nil, repositoryRootPath: nil).name == "Personal")
  }

  @Test func filesWithoutAMainNameStillSayMain() throws {
    let file = try JSONDecoder().decode(ClaudeAccountsFile.self, from: Data("{}".utf8))
    #expect(file.mainAccountName == nil)
    #expect(file.allAccounts.first?.name == "Main")
  }
}

// MARK: - Account tag on the tab.

@MainActor
struct ClaudeAccountTabTagTests {
  private let work = ClaudeAccount(id: "work", name: "Work", configDirectoryPath: "/tmp/kage-claude/work")
  private let contentID = UUID()

  @Test func tagShowsTheSurfaceAccountOnceASecondAccountExists() {
    var file = ClaudeAccountsFile()
    file.accounts = [work]
    #expect(ClaudeAccountTabTag.label(contentID: contentID, file: file, accountIDs: [contentID: "work"]) == "Work")
    file.mainAccountName = "Personal"
    #expect(
      ClaudeAccountTabTag.label(contentID: contentID, file: file, accountIDs: [contentID: ClaudeAccount.mainID])
        == "Personal")
  }

  @Test func noTagWithASingleAccountOrUnknownSurface() {
    var file = ClaudeAccountsFile()
    #expect(
      ClaudeAccountTabTag.label(contentID: contentID, file: file, accountIDs: [contentID: ClaudeAccount.mainID])
        == nil)
    file.accounts = [work]
    #expect(ClaudeAccountTabTag.label(contentID: contentID, file: file, accountIDs: [:]) == nil)
    #expect(ClaudeAccountTabTag.label(contentID: contentID, file: file, accountIDs: [contentID: "gone"]) == nil)
  }
}
