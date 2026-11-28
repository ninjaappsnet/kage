import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import OrderedCollections
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

// MARK: - Resuming the agent in the new shell.

struct TerminalTabRestartResumeTests {
  private let resume = TerminalTabRestart.Resume(agent: .claude, command: "claude --continue")

  @Test func claudeOnTheOldSurfaceIsResumed() {
    #expect(
      TerminalTabRestart.initialInput(resume: resume, agentsOnSurface: [.claude]) == "claude --continue\n")
  }

  @Test func claudeAlongsideAnotherAgentIsStillResumed() {
    #expect(
      TerminalTabRestart.initialInput(resume: resume, agentsOnSurface: [.codex, .claude]) == "claude --continue\n")
  }

  @Test func aPlainShellGetsNoInput() {
    #expect(TerminalTabRestart.initialInput(resume: resume, agentsOnSurface: []) == nil)
    #expect(TerminalTabRestart.initialInput(resume: resume, agentsOnSurface: [.codex]) == nil)
  }

  @Test func noResumeRequestedGetsNoInput() {
    #expect(TerminalTabRestart.initialInput(resume: nil, agentsOnSurface: [.claude]) == nil)
  }

  @Test func theReplayedLaunchReplacesThePlainResumeCommand() {
    let replayed = "CLAUDE_CODE_EXPERIMENTAL_CODE_MODE=1 claude --resume 4e7fcb91-bc51-4718-8aa6-9d3e02009ac5"
    #expect(
      TerminalTabRestart.initialInput(resume: resume, agentsOnSurface: [.claude], relaunchCommand: replayed)
        == replayed + "\n")
    #expect(
      TerminalTabRestart.initialInput(resume: resume, agentsOnSurface: [.claude], relaunchCommand: nil)
        == "claude --continue\n")
  }

  @Test func aReplayedLaunchNeverTypesIntoAShellWhereTheAgentWasNotRunning() {
    #expect(
      TerminalTabRestart.initialInput(resume: resume, agentsOnSurface: [], relaunchCommand: "claude --verbose")
        == nil)
  }

  @Test func theSeedKeepsTheFolderAndCarriesTheInputAsALiveOnlyLaunch() {
    let seed = TerminalTabRestart.seed(workingDirectory: "/tmp/repo/sub", initialInput: "claude --continue\n")
    #expect(
      seed
        == .terminal(
          TerminalContentState(
            workingDirectory: "/tmp/repo/sub", launch: LaunchOverride(initialInput: "claude --continue\n"))))
    #expect(
      TerminalTabRestart.seed(workingDirectory: nil, initialInput: nil)
        == .terminal(TerminalContentState(workingDirectory: nil)))
  }

  @Test func theWorkingDirectoryIsReadFromATerminalSnapshotOnly() {
    #expect(
      TerminalTabRestart.workingDirectory(of: .terminal(TerminalContentState(workingDirectory: "/tmp/a")))
        == "/tmp/a")
    #expect(
      TerminalTabRestart.workingDirectory(
        of: .fileViewer(FileViewerContentState(fileURL: URL(filePath: "/tmp/a/file.swift")))) == nil)
  }
}

// MARK: - The account a tab's session runs as.

struct ClaudeTabRestartCurrentAccountTests {
  private let work = ClaudeAccount(id: "work", name: "Work", configDirectoryPath: "/tmp/kage-claude/work")
  private let tabID = UUID()

  private func file(_ configure: (inout ClaudeAccountsFile) -> Void = { _ in }) -> ClaudeAccountsFile {
    var file = ClaudeAccountsFile()
    file.accounts = [work]
    configure(&file)
    return file
  }

  @Test func theAccountTheLiveSurfaceStartedUnderWins() {
    // The repository override changed after the tab started: the session still runs as main.
    let current = ClaudeTabRestart.currentAccountID(
      tabID: tabID, surfaceAccountID: ClaudeAccount.mainID, repositoryRootURL: URL(filePath: "/tmp/repo"),
      file: file { $0.repositoryAccountIDs["/tmp/repo"] = "work" })
    #expect(current == ClaudeAccount.mainID)
  }

  @Test func withoutALiveSurfaceTheResolvedAccountIsUsed() {
    #expect(
      ClaudeTabRestart.currentAccountID(
        tabID: tabID, surfaceAccountID: nil, repositoryRootURL: URL(filePath: "/tmp/repo/"),
        file: file { $0.repositoryAccountIDs["/tmp/repo"] = "work" }) == "work")
    #expect(
      ClaudeTabRestart.currentAccountID(
        tabID: tabID, surfaceAccountID: nil, repositoryRootURL: nil,
        file: file { $0.tabAccountIDs[tabID.uuidString] = "work" }) == "work")
  }

  @Test func aRemovedSurfaceAccountFallsBackToResolution() {
    #expect(
      ClaudeTabRestart.currentAccountID(
        tabID: tabID, surfaceAccountID: "gone", repositoryRootURL: nil, file: file()) == ClaudeAccount.mainID)
  }
}

// MARK: - Confirm, persist, restart.

@MainActor
struct ClaudeAccountRestartFeatureTests {
  private let work = ClaudeAccount(id: "work", name: "Work", configDirectoryPath: "/tmp/kage-claude/work")
  private let tabID = TabID(rawValue: UUID(3))
  private let localWorktree = Worktree(
    location: .local(
      workingDirectory: URL(filePath: "/tmp/repo/feature"), repositoryRoot: URL(filePath: "/tmp/repo")),
    kind: .git, name: "feature", detail: "", isAttached: false)

  private func state(_ configure: (inout ClaudeAccountsFile) -> Void = { _ in }) -> ClaudeAccountsFeature.State {
    let state = ClaudeAccountsFeature.State()
    state.$file.withLock { file in
      file = ClaudeAccountsFile()
      file.accounts = [work]
      configure(&file)
    }
    return state
  }

  @Test(.dependencies) func requestingARestartAsksFirstAndChangesNothing() async {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: state()) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
      $0.terminalClient.tabCanRename = { _, _ in true }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.restartTabRequested("work", localWorktree, tabID: tabID)) {
      $0.restartTabAlert = ClaudeTabRestart.alert(account: self.work, worktree: self.localWorktree, tabID: self.tabID)
    }
    #expect(store.state.file.tabAccountIDs.isEmpty)
    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func confirmingPersistsTheAssignmentThenRestartsTheTab() async {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: state()) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
      $0.terminalClient.tabCanRename = { _, _ in true }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.restartTabRequested("work", localWorktree, tabID: tabID))
    await store.send(.restartTabAlert(.presented(.confirm("work", localWorktree, tabID)))) {
      $0.restartTabAlert = nil
    }
    await store.finish()
    #expect(store.state.file.tabAccountIDs == [tabID.rawValue.uuidString: "work"])
    #expect(sent.value == [.restartTab(localWorktree, tabID: tabID, resume: ClaudeTabRestart.resume)])
  }

  @Test(.dependencies) func switchingBackToMainIsAnExplicitAssignment() async {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: state { $0.tabAccountIDs[tabID.rawValue.uuidString] = "work" }) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.restartTabAlert(.presented(.confirm(ClaudeAccount.mainID, localWorktree, tabID))))
    await store.finish()
    // Explicit, not removed: a repository override must not win back the tab.
    #expect(store.state.file.tabAccountIDs == [tabID.rawValue.uuidString: ClaudeAccount.mainID])
    #expect(sent.value.count == 1)
  }

  @Test(.dependencies) func cancellingLeavesTheTabAlone() async {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(initialState: state()) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
      $0.terminalClient.tabCanRename = { _, _ in true }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.restartTabRequested("work", localWorktree, tabID: tabID))
    await store.send(.restartTabAlert(.dismiss)) {
      $0.restartTabAlert = nil
    }
    await store.finish()
    #expect(store.state.file.tabAccountIDs.isEmpty)
    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func theFileMenuTargetsTheSelectedTab() async {
    let store = TestStore(initialState: state()) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.terminalClient.selectedTabID = { _ in self.tabID }
      $0.terminalClient.tabCanRename = { _, _ in true }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.restartTabRequested("work", localWorktree, tabID: nil)) {
      $0.restartTabAlert = ClaudeTabRestart.alert(account: self.work, worktree: self.localWorktree, tabID: self.tabID)
    }
  }

  @Test(.dependencies) func refusedTargetsRaiseNoAlert() async {
    let remote = Worktree(
      location: .remote(RemoteHost(alias: "box"), workingDirectory: "/srv/repo", repositoryRoot: "/srv/repo"),
      kind: .git, name: "repo", detail: "", isAttached: false)
    let store = TestStore(initialState: state()) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.terminalClient.selectedTabID = { _ in nil }
      $0.terminalClient.tabCanRename = { _, tabID in tabID != self.tabID }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    // Unknown account, remote worktree, no selected tab, a locked (script) tab.
    await store.send(.restartTabRequested("gone", localWorktree, tabID: TabID()))
    await store.send(.restartTabRequested("work", remote, tabID: TabID()))
    await store.send(.restartTabRequested("work", localWorktree, tabID: nil))
    await store.send(.restartTabRequested("work", localWorktree, tabID: tabID))
    #expect(store.state.restartTabAlert == nil)
  }
}

// MARK: - Swapping the tab's content.

@MainActor
struct LayoutReplaceTabContentTests {
  @MainActor
  private final class RecordingContent: TabContent {
    let id: ContentID
    let kind: ContentKind = .terminal
    private let state: ContentState
    private var view: NSView?
    private(set) var tornDown = false

    init(id: ContentID, state: ContentState) {
      self.id = id
      self.state = state
    }

    nonisolated deinit {}

    var renderer: NSView? { view }
    func startSession(at geometry: ContentGeometry) {
      if view == nil { view = NSView() }
    }
    func hibernate() { view = nil }
    func tearDown() {
      tornDown = true
      view = nil
    }
    func snapshot() -> ContentSnapshot { ContentSnapshot(id: id, state: state) }
  }

  @MainActor
  private final class Recorder {
    var requests: [ContentRequest] = []
    var contents: [ContentID: RecordingContent] = [:]
    nonisolated deinit {}

    func make(_ request: ContentRequest) -> any TabContent {
      let content = RecordingContent(id: request.contentID, state: request.content)
      requests.append(request)
      contents[request.contentID] = content
      return content
    }
  }

  private static let oldState = ContentState.terminal(TerminalContentState(workingDirectory: "/tmp/old"))

  @Test func theTabKeepsItsIdentityAndGetsAFreshSessionWhileTheOldOneIsKilled() async {
    let paneID = PaneID()
    let first = TabID()
    let target = TabID()
    let last = TabID()
    let oldContentID = ContentID()
    let runtime = ContentRuntime()
    let recorder = Recorder()
    let killed = LockIsolated<[ContentID]>([])
    func tab(_ id: TabID, _ title: String, content: ContentID = ContentID()) -> TabItem {
      TabItem(id: id, title: title, content: ContentSnapshot(id: content, state: Self.oldState))
    }
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [tab(first, "One"), tab(target, "Two", content: oldContentID), tab(last, "Three")],
          selectedTabID: target)
      ],
      focusedPaneID: paneID
    )
    let store = TestStore(initialState: LayoutFeature.State(id: WorktreeID("/tmp/repo"), layout: layout)) {
      LayoutFeature()
    } withDependencies: {
      $0.uuid = .constant(UUID(42))
      $0.contentRuntime = runtime
      $0.layoutContentFactory = LayoutContentFactory(make: { recorder.make($0) })
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { id, _ in killed.withValue { $0.append(id) } })
    }
    let oldContent = RecordingContent(id: oldContentID, state: Self.oldState)
    #expect(runtime.provision(oldContent, at: .fallback))

    let newContentID = ContentID(rawValue: UUID(42))
    let seed = TerminalTabRestart.seed(workingDirectory: "/tmp/old", initialInput: "claude --continue\n")
    await store.send(.replaceTabContent(id: target, content: seed)) {
      $0.layout.panes[id: paneID]?.tabs[id: target]?.content = ContentSnapshot(id: newContentID, state: seed)
    }
    await store.receive(.runtime(.killConfirmed(id: oldContentID)))

    // Same tab, same place, same title, still selected.
    let pane = store.state.layout.panes[id: paneID]
    #expect(pane?.tabs.ids.elements == [first, target, last])
    #expect(pane?.tabs[id: target]?.title == "Two")
    #expect(pane?.selectedTabID == target)
    // A new content id means a new zmx session name: nothing can reattach the old one.
    #expect(
      recorder.requests == [
        ContentRequest(
          worktreeID: WorktreeID("/tmp/repo"), tabID: target, contentID: newContentID, content: seed,
          origin: .tab, inheritedFrom: oldContentID)
      ])
    #expect(runtime.content(for: newContentID) != nil)
    #expect(runtime.content(for: oldContentID) == nil)
    #expect(oldContent.tornDown)
    #expect(killed.value == [oldContentID])
  }

  @Test func anUnknownTabIsIgnored() async {
    let paneID = PaneID()
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [
        Pane(
          id: paneID,
          tabs: [TabItem(id: TabID(), title: "One", content: ContentSnapshot(id: ContentID(), state: Self.oldState))])
      ],
      focusedPaneID: paneID
    )
    let recorder = Recorder()
    let store = TestStore(initialState: LayoutFeature.State(id: WorktreeID("/tmp/repo"), layout: layout)) {
      LayoutFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.contentRuntime = ContentRuntime()
      $0.layoutContentFactory = LayoutContentFactory(make: { recorder.make($0) })
      $0[ContentSessionKiller.self] = ContentSessionKiller(kill: { _, _ in })
    }
    await store.send(.replaceTabContent(id: TabID(), content: Self.oldState))
    #expect(recorder.requests.isEmpty)
  }
}
