import Foundation
import Testing

@testable import supacode

nonisolated struct RemoteKageFilesPresentationTests {
  @Test(arguments: [
    RemoteKageServeSession.Status?.none, .idle, .connecting,
  ])
  func showsTheExplorerWhileConnecting(status: RemoteKageServeSession.Status?) {
    #expect(RemoteKageFilesPresentation.resolve(status: status, hostName: "Mini") == .explorer(isConnecting: true))
  }

  @Test func showsTheExplorerWhenConnectedOrOffline() {
    #expect(RemoteKageFilesPresentation.resolve(status: .connected, hostName: "Mini") == .explorer(isConnecting: false))
    // Offline keeps the last listing; the panel's own banner says why.
    #expect(
      RemoteKageFilesPresentation.resolve(status: .unavailable(.offline("gone")), hostName: "Mini")
        == .explorer(isConnecting: false))
  }

  @Test func anOldHostSaysToUpdateKageThere() {
    let presentation = RemoteKageFilesPresentation.resolve(status: .unavailable(.needsUpdate), hostName: "Mini")
    guard case .unavailable(let title, let message, _) = presentation else {
      Issue.record("expected unavailable")
      return
    }
    #expect(title == "Update Kage on Mini")
    #expect(message.contains("Mini"))
  }

  @Test func aNewerHostSaysToUpdateThisMac() {
    let presentation = RemoteKageFilesPresentation.resolve(
      status: .unavailable(.hostIsNewer(protocolVersion: 2)), hostName: "Mini")
    guard case .unavailable(let title, _, _) = presentation else {
      Issue.record("expected unavailable")
      return
    }
    #expect(title == "Update Kage on This Mac")
  }
}

nonisolated struct RemoteKageFileViewerOpeningTests {
  private let file = URL(filePath: "/w/a.swift")
  private let other = URL(filePath: "/w/b.swift")

  @Test func opensWhenNothingIsShown() {
    #expect(RemoteKageFileViewerOpening.decide(requested: file, shown: nil, isDirty: false) == .open)
  }

  @Test func reopeningTheShownFileKeepsTheBuffer() {
    #expect(RemoteKageFileViewerOpening.decide(requested: file, shown: file, isDirty: true) == .alreadyShown)
    #expect(RemoteKageFileViewerOpening.decide(requested: file, shown: file, isDirty: false) == .alreadyShown)
  }

  @Test func replacingACleanFileJustOpens() {
    #expect(RemoteKageFileViewerOpening.decide(requested: other, shown: file, isDirty: false) == .open)
  }

  @Test func replacingUnsavedEditsAsksFirst() {
    #expect(RemoteKageFileViewerOpening.decide(requested: other, shown: file, isDirty: true) == .confirmDiscard)
  }

  @Test func viewerWidthIsClamped() {
    #expect(RemoteKageFileViewerOpening.clampedWidth(100) == RemoteKageFileViewerOpening.minimumWidth)
    #expect(RemoteKageFileViewerOpening.clampedWidth(5000) == RemoteKageFileViewerOpening.maximumWidth)
    #expect(RemoteKageFileViewerOpening.clampedWidth(600) == 600)
  }
}

@MainActor
struct RemoteKageFilesExplorerRootTests {
  private func tab(_ id: String, workingDirectory: String?) -> HostSnapshot.Tab {
    HostSnapshot.Tab(
      id: id, title: id, isFocused: false, surfaceID: id, zmxSession: nil, agents: [],
      workingDirectory: workingDirectory)
  }

  @Test func rootsAtTheSelectedTabsFolder() {
    let tabs = [
      tab("t1", workingDirectory: "/w/src"),
      tab("t2", workingDirectory: nil),
    ]
    #expect(
      RemoteKageFiles.explorerRootURL(tabs: tabs, selectedTabID: "t1", worktreePath: "/w")
        == URL(filePath: "/w/src", directoryHint: .isDirectory))
    #expect(
      RemoteKageFiles.explorerRootURL(tabs: tabs, selectedTabID: "t2", worktreePath: "/w")
        == URL(filePath: "/w", directoryHint: .isDirectory))
  }

  @Test func holdsTheConnectionOnlyWhileSomethingIsShown() {
    #expect(!RemoteKageFiles.needsConnection(isExplorerVisible: false, isViewerOpen: false))
    #expect(RemoteKageFiles.needsConnection(isExplorerVisible: true, isViewerOpen: false))
    #expect(RemoteKageFiles.needsConnection(isExplorerVisible: false, isViewerOpen: true))
  }
}
