import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
struct RemoteKageWorktreeDetailTests {
  private let hostID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
  private var host: RemoteKageHost { RemoteKageHost(id: hostID, name: "Mini 1", username: "me", address: "mini1") }

  private func tab(_ id: String, session: String? = "supa-\(UUID().uuidString)", isFocused: Bool = false)
    -> HostSnapshot.Tab
  {
    HostSnapshot.Tab(id: id, title: id, isFocused: isFocused, surfaceID: id, zmxSession: session, agents: [])
  }

  private func snapshot(tabs: [HostSnapshot.Tab] = []) -> HostSnapshot {
    HostSnapshot(
      schemaVersion: 1,
      kageVersion: "1.4.0",
      machineName: "Mac mini",
      zmxPath: "/z/zmx",
      cliPath: "/c",
      workspaces: [],
      repositories: [
        HostSnapshot.Repository(
          id: "/r/app",
          name: "app",
          rootPath: "/r/app",
          workspaceID: nil,
          isGitRepository: true,
          color: nil,
          worktrees: [
            HostSnapshot.Worktree(id: "/r/app", name: "main", path: "/r/app", isMain: true, isPinned: false, tabs: tabs)
          ]
        )
      ]
    )
  }

  // MARK: - Quick answers.

  @Test func quickAnswersMapToTheKeysTheyType() {
    #expect(RemoteKageQuickAnswer.allCases.map(\.title) == ["1", "2", "3", "Esc", "Enter"])
    #expect(RemoteKageQuickAnswer.allCases.map(\.text) == ["1", "2", "3", "\u{1B}", "\r"])
    #expect(RemoteKageQuickAnswer.allCases.allSatisfy { !$0.help.isEmpty })
  }

  // MARK: - Attach availability.

  @Test func attachNeedsBothZmxPathAndSession() {
    let attachable = tab("t1", session: "supa-1")
    #expect(
      RemoteKageAttachAvailability.resolve(zmxPath: "/z/zmx", tab: attachable)
        == .available(zmxPath: "/z/zmx", session: "supa-1")
    )
    guard case .unavailable(let noZmx) = RemoteKageAttachAvailability.resolve(zmxPath: nil, tab: attachable) else {
      Issue.record("Expected unavailable without a zmx path")
      return
    }
    #expect(noZmx.contains("zmx"))
    guard
      case .unavailable(let noSession) = RemoteKageAttachAvailability.resolve(
        zmxPath: "/z/zmx",
        tab: tab("t2", session: nil)
      )
    else {
      Issue.record("Expected unavailable without a session")
      return
    }
    #expect(!noSession.isEmpty)
  }

  // MARK: - Unavailable states.

  @Test func unavailableReasonFollowsHostStatus() {
    let snap = snapshot()
    let worktree = snap.repositories[0].worktrees[0]
    #expect(RemoteKageWorktreeDetail.unavailable(host: nil, hostState: nil, worktree: nil) == .hostRemoved)
    #expect(RemoteKageWorktreeDetail.unavailable(host: host, hostState: nil, worktree: nil) == .connecting)
    #expect(
      RemoteKageWorktreeDetail.unavailable(
        host: host,
        hostState: .init(status: .connecting, lastSnapshot: snap),
        worktree: worktree
      ) == nil
    )
    #expect(
      RemoteKageWorktreeDetail.unavailable(
        host: host,
        hostState: .init(status: .offline("timeout"), lastSnapshot: snap),
        worktree: worktree
      ) == .offline("timeout")
    )
    #expect(
      RemoteKageWorktreeDetail.unavailable(host: host, hostState: .init(status: .kageNotRunning), worktree: nil)
        == .kageNotRunning
    )
    #expect(
      RemoteKageWorktreeDetail.unavailable(host: host, hostState: .init(status: .needsUpdate), worktree: nil)
        == .needsUpdate
    )
    #expect(
      RemoteKageWorktreeDetail.unavailable(
        host: host,
        hostState: .init(status: .online, lastSnapshot: snap),
        worktree: nil
      ) == .worktreeMissing
    )
    #expect(
      RemoteKageWorktreeDetail.unavailable(
        host: host,
        hostState: .init(status: .online, lastSnapshot: snap),
        worktree: worktree
      ) == nil
    )
  }

  @Test func everyUnavailableReasonHasCopy() {
    let reasons: [RemoteKageWorktreeDetail.Unavailable] = [
      .hostRemoved, .connecting, .offline("timeout"), .kageNotRunning, .needsUpdate, .worktreeMissing,
    ]
    #expect(reasons.allSatisfy { !$0.title.isEmpty && !$0.message.isEmpty && !$0.systemImage.isEmpty })
    #expect(RemoteKageWorktreeDetail.Unavailable.offline("timeout").message.contains("timeout"))
  }

  // MARK: - Tab choice.

  @Test func shownTabIsTheStoredOneWhileItExistsThenTheFocusedThenTheFirst() {
    let tabs = [tab("t1"), tab("t2", isFocused: true), tab("t3")]
    #expect(RemoteKageWorktreeDetail.selectedTabID(in: tabs, stored: "t3") == "t3")
    #expect(RemoteKageWorktreeDetail.selectedTabID(in: tabs, stored: "gone") == "t2")
    #expect(RemoteKageWorktreeDetail.selectedTabID(in: tabs, stored: nil) == "t2")
    #expect(RemoteKageWorktreeDetail.selectedTabID(in: [tab("t1"), tab("t3")], stored: nil) == "t1")
    #expect(RemoteKageWorktreeDetail.selectedTabID(in: [], stored: "t1") == nil)
  }

  // MARK: - Mounted terminals.

  @Test func everyAttachedTabOfTheWorktreeStaysMountedInStripOrder() {
    let tabs = [tab("t1", session: "s1"), tab("t2", session: "s2"), tab("t3", session: nil), tab("t4", session: "s4")]
    let otherHost = UUID()
    let attached: Set<RemoteKageTabKey> = [
      .init(hostID: hostID, tabID: "t4"),
      .init(hostID: hostID, tabID: "t1"),
      .init(hostID: hostID, tabID: "t3"),
      .init(hostID: otherHost, tabID: "t2"),
    ]

    let mounted = RemoteKageWorktreeDetail.mountedTerminals(
      hostID: hostID,
      tabs: tabs,
      attachedTabs: attached,
      zmxPath: "/z/zmx"
    )

    #expect(mounted.map(\.key.tabID) == ["t1", "t4"])
    #expect(mounted.map(\.session) == ["s1", "s4"])
    #expect(mounted.allSatisfy { $0.zmxPath == "/z/zmx" })
    #expect(
      RemoteKageWorktreeDetail.mountedTerminals(hostID: hostID, tabs: tabs, attachedTabs: attached, zmxPath: nil)
        .isEmpty
    )
  }

  // MARK: - Title.

  @Test func titleNamesHostRepositoryAndWorktree() {
    let snap = snapshot()
    #expect(
      RemoteKageWorktreeDetail.title(hostName: "Mini 1", snapshot: snap, worktreeID: "/r/app") == "Mini 1 · app · main")
    #expect(RemoteKageWorktreeDetail.title(hostName: "Mini 1", snapshot: snap, worktreeID: "/nope") == "Mini 1")
    #expect(RemoteKageWorktreeDetail.title(hostName: "Mini 1", snapshot: nil, worktreeID: "/r/app") == "Mini 1")
  }
}
