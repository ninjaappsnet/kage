import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// The detail for a remote Kage worktree selected in the sidebar: a flat strip
/// of its tabs on the host, and for the shown tab either a live attached
/// terminal or a polled screen preview with quick answers.
struct RemoteKageWorktreeView: View {
  let store: StoreOf<RemoteKageFeature>
  let selection: RemoteKageSelection

  var body: some View {
    let state = store.state
    let host = state.host(selection.hostID)
    let hostState = state.hostStates[selection.hostID]
    let worktree = state.worktree(for: selection)
    if let unavailable = RemoteKageWorktreeDetail.unavailable(host: host, hostState: hostState, worktree: worktree) {
      if unavailable == .connecting {
        ProgressView(unavailable.message)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView(
          unavailable.title,
          systemImage: unavailable.systemImage,
          description: Text(unavailable.message)
        )
      }
    } else if let host, let worktree {
      RemoteKageWorktreeContent(
        store: store,
        host: host,
        selection: selection,
        worktree: worktree,
        snapshot: hostState?.lastSnapshot
      )
    }
  }
}

private struct RemoteKageWorktreeContent: View {
  let store: StoreOf<RemoteKageFeature>
  let host: RemoteKageHost
  let selection: RemoteKageSelection
  let worktree: HostSnapshot.Worktree
  let snapshot: HostSnapshot?
  /// Shared with local worktrees, so ⌥⌘E means the same thing everywhere.
  @Shared(.appStorage("fileExplorerVisible")) private var isFileExplorerVisible = false
  @Shared(.settingsFile) private var settingsFile
  /// One viewer per remote worktree, so switching worktrees and back keeps an
  /// unsaved buffer instead of dropping it.
  @State private var viewers: [RemoteKageSelection: FileViewerModel] = [:]
  /// A file whose opening would replace unsaved edits, awaiting confirmation.
  @State private var pendingFileToOpen: URL?
  /// Debug driver only (`explorer-root:`).
  @State private var debugExplorerRoot: URL?

  var body: some View {
    let selectedTabID = RemoteKageWorktreeDetail.selectedTabID(
      in: worktree.tabs,
      stored: store.selectedTabByWorktree[selection]
    )
    let selectedTab = worktree.tabs.first { $0.id == selectedTabID }
    let mounted = RemoteKageWorktreeDetail.mountedTerminals(
      hostID: host.id,
      tabs: worktree.tabs,
      attachedTabs: store.attachedTabs,
      zmxPath: snapshot?.zmxPath
    )
    let viewer = viewers[selection]
    let needsFiles = RemoteKageFiles.needsConnection(
      isExplorerVisible: isFileExplorerVisible,
      isViewerOpen: viewer != nil
    )
    // Created (not opened) on demand; the session opens only while held below.
    let source = needsFiles ? RemoteKageFileSessions.shared.source(for: host, reportedCLIPath: snapshot?.cliPath) : nil
    HStack(spacing: 0) {
      if isFileExplorerVisible, let source {
        RemoteKageExplorerColumn(
          hostName: host.name,
          source: source,
          rootURL: debugExplorerRoot
            ?? RemoteKageFiles.explorerRootURL(
              tabs: worktree.tabs,
              selectedTabID: selectedTabID,
              worktreePath: worktree.path
            ),
          openFileURL: viewer?.fileURL,
          status: RemoteKageFileSessions.shared.status(for: host.id),
          onOpenFile: { openFile($0, source: source) },
          onClose: toggleFileExplorer
        )
        .id(selection)
        .transition(.move(edge: .leading).combined(with: .opacity))
      }
      VStack(spacing: 0) {
        RemoteKageWorktreeHeader(
          title: RemoteKageWorktreeDetail.title(
            hostName: host.name,
            snapshot: snapshot,
            worktreeID: selection.worktreeID
          ),
          hostName: host.name,
          isFileExplorerVisible: isFileExplorerVisible,
          fileExplorerShortcut: AppShortcuts.toggleFileExplorer.effective(from: settingsFile.global.shortcutOverrides),
          toggleFileExplorer: toggleFileExplorer,
          newTab: { command in store.send(.newTab(selection, command: command)) }
        )
        RemoteKageTabStrip(
          hostID: host.id,
          tabs: worktree.tabs,
          selectedTabID: selectedTabID,
          attachedTabs: store.attachedTabs,
          select: { tabID in store.send(.selectTab(selection, tabID: tabID)) }
        )
        Divider()
        HStack(spacing: 0) {
          VStack(spacing: 0) {
            ZStack {
              // Every attached tab stays mounted, hidden when not shown, so switching
              // tabs never drops its SSH session. Unmounting one detaches it.
              ForEach(mounted) { terminal in
                let isShown = terminal.key.tabID == selectedTabID
                RemoteKageAttachedTerminalView(
                  host: host,
                  zmxPath: terminal.zmxPath,
                  session: terminal.session,
                  onExit: { store.send(.detachTab(terminal.key)) }
                )
                .opacity(isShown ? 1 : 0)
                .allowsHitTesting(isShown)
                .accessibilityHidden(!isShown)
              }
              if let selectedTab {
                let key = RemoteKageTabKey(hostID: host.id, tabID: selectedTab.id)
                if !mounted.contains(where: { $0.key == key }) {
                  RemoteKageScreenPreview(screen: store.screens[key])
                }
              } else {
                ContentUnavailableView(
                  "No Tabs",
                  systemImage: "terminal",
                  description: Text("This worktree has no terminal tabs on \(host.name). Start one with New Tab.")
                )
              }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let selectedTab {
              let key = RemoteKageTabKey(hostID: host.id, tabID: selectedTab.id)
              Divider()
              RemoteKageTabActionBar(
                hostName: host.name,
                tab: selectedTab,
                isAttached: mounted.contains { $0.key == key },
                availability: RemoteKageAttachAvailability.resolve(zmxPath: snapshot?.zmxPath, tab: selectedTab),
                send: { store.send($0(key)) }
              )
            }
          }
          if let viewer {
            RemoteKageFileViewerPane(model: viewer, onClose: { viewers[selection] = nil })
              .transition(.move(edge: .trailing).combined(with: .opacity))
          }
        }
      }
    }
    .task(id: selection) {
      // Records the shown tab and loads its preview when the worktree opens.
      if let selectedTabID {
        store.send(.selectTab(selection, tabID: selectedTabID))
      }
    }
    .onChange(of: selectedTabID) { _, newValue in
      // The recorded tab closed on the host: record the fallback, loading its preview.
      guard let newValue, store.selectedTabByWorktree[selection] != newValue else { return }
      store.send(.selectTab(selection, tabID: newValue))
    }
    // Holds the host's file channel while the explorer or the viewer is on
    // screen; leaving (or closing both) releases it, and it closes 30 s later.
    .task(id: RemoteKageFilesLease(hostID: host.id, isNeeded: needsFiles)) {
      guard let source else { return }
      await source.session.hold()
    }
    .confirmationDialog(
      "Discard unsaved changes to \(viewer?.displayName ?? "the open file")?",
      isPresented: Binding(
        get: { pendingFileToOpen != nil },
        set: { if !$0 { pendingFileToOpen = nil } }
      )
    ) {
      Button("Discard Changes", role: .destructive) {
        if let url = pendingFileToOpen, let viewer {
          Task { await viewer.open(url) }
        }
        pendingFileToOpen = nil
      }
      Button("Cancel", role: .cancel) { pendingFileToOpen = nil }
    } message: {
      Text("Opening another file replaces the edits in the viewer.")
    }
    #if DEBUG
      .onChange(of: RemoteKageFilesDebugCommands.shared.latest?.sequence) { _, _ in
        guard let command = RemoteKageFilesDebugCommands.shared.latest?.command else { return }
        runDebugCommand(command)
      }
    #endif
  }

  private func toggleFileExplorer() {
    withAnimation(.easeOut(duration: 0.2)) {
      $isFileExplorerVisible.withLock { $0.toggle() }
    }
  }

  private func openFile(_ url: URL, source: RemoteFileSystemSource) {
    let viewer = viewers[selection]
    switch RemoteKageFileViewerOpening.decide(
      requested: url,
      shown: viewer?.fileURL,
      isDirty: viewer?.isDirty ?? false
    ) {
    case .alreadyShown:
      return
    case .confirmDiscard:
      pendingFileToOpen = url
    case .open:
      let model = viewer ?? FileViewerModel(source: source)
      if viewer == nil {
        withAnimation(.easeOut(duration: 0.2)) { viewers[selection] = model }
      }
      Task { await model.open(url) }
    }
  }

  #if DEBUG
    private func runDebugCommand(_ command: RemoteKageFilesDebugCommand) {
      let viewer = viewers[selection]
      switch command.verb {
      case "explorer":
        $isFileExplorerVisible.withLock { $0 = command.argument != "off" }
      case "explorer-root":
        debugExplorerRoot =
          command.argument.isEmpty ? nil : URL(filePath: command.argument, directoryHint: .isDirectory)
      case "open":
        openFile(
          URL(filePath: command.argument),
          source: RemoteKageFileSessions.shared.source(for: host, reportedCLIPath: snapshot?.cliPath)
        )
      case "append":
        viewer?.text += command.argument
      case "save":
        if let viewer { Task { await viewer.save() } }
      case "reload":
        if let viewer { Task { await viewer.reloadFromDisk() } }
      case "close":
        viewers[selection] = nil
      default:
        break
      }
    }
  #endif
}

/// Identity of the file channel hold: re-evaluated when the host changes or
/// when the files UI appears / goes away.
private struct RemoteKageFilesLease: Hashable {
  let hostID: RemoteKageHost.ID
  let isNeeded: Bool
}

private struct RemoteKageWorktreeHeader: View {
  let title: String
  let hostName: String
  let isFileExplorerVisible: Bool
  let fileExplorerShortcut: AppShortcut?
  let toggleFileExplorer: () -> Void
  let newTab: (_ command: String?) -> Void

  var body: some View {
    HStack(spacing: 8) {
      Button(action: toggleFileExplorer) {
        Image(systemName: "folder")
          .symbolVariant(isFileExplorerVisible ? .fill : .none)
          .accessibilityLabel(isFileExplorerVisible ? "Hide File Explorer" : "Show File Explorer")
      }
      .buttonStyle(.borderless)
      .help(
        AppShortcut.helpText(
          isFileExplorerVisible ? "Hide the files of \(hostName)" : "Browse the files of \(hostName)",
          shortcut: fileExplorerShortcut
        )
      )
      Image(systemName: "desktopcomputer")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(title)
        .appFont(.headline)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      Button("New Tab", systemImage: "plus") {
        newTab(nil)
      }
      .help("Open a new shell tab in this worktree on \(hostName)")
      Button("New Claude Tab", systemImage: "sparkles") {
        newTab("claude")
      }
      .help("Open a new tab running claude in this worktree on \(hostName)")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}

private struct RemoteKageTabStrip: View {
  let hostID: RemoteKageHost.ID
  let tabs: [HostSnapshot.Tab]
  let selectedTabID: String?
  let attachedTabs: Set<RemoteKageTabKey>
  let select: (String) -> Void

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 4) {
        ForEach(tabs) { tab in
          RemoteKageTabButton(
            tab: tab,
            isSelected: tab.id == selectedTabID,
            isAttached: attachedTabs.contains(RemoteKageTabKey(hostID: hostID, tabID: tab.id)),
            select: { select(tab.id) }
          )
        }
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 6)
    }
    .scrollIndicators(.never)
  }
}

private struct RemoteKageTabButton: View {
  let tab: HostSnapshot.Tab
  let isSelected: Bool
  let isAttached: Bool
  let select: () -> Void

  var body: some View {
    let title = tab.title.isEmpty ? "Tab" : tab.title
    Button(action: select) {
      HStack(spacing: 4) {
        if isAttached {
          Image(systemName: "link")
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Attached")
        }
        Text(title)
          .appFont(.callout, weight: tab.isAwaitingInput ? .semibold : nil)
          .lineLimit(1)
        AgentAvatarGroupView(instances: RemoteKageSidebarModel.agentInstances(for: [tab]).known, size: 12)
        if tab.isAwaitingInput {
          RemoteKageAwaitingInputMark()
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: 6).fill(.quaternary)
        }
      }
      .overlay {
        if tab.isAwaitingInput {
          RoundedRectangle(cornerRadius: 6).strokeBorder(.orange)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help(isAttached ? "Show \(title) (attached)" : "Show \(title)")
  }
}

private struct RemoteKageScreenPreview: View {
  let screen: String?

  var body: some View {
    if let screen {
      ScrollView([.vertical, .horizontal]) {
        Text(screen)
          .appFont(.body, monospaced: true)
          .textSelection(.enabled)
          .fixedSize()
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
      .defaultScrollAnchor(.bottomLeading)
    } else {
      ProgressView("Loading screen…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct RemoteKageTabActionBar: View {
  let hostName: String
  let tab: HostSnapshot.Tab
  let isAttached: Bool
  let availability: RemoteKageAttachAvailability
  /// Sends the action built from the shown tab's key.
  let send: ((RemoteKageTabKey) -> RemoteKageFeature.Action) -> Void

  var body: some View {
    HStack(spacing: 8) {
      if isAttached {
        Spacer(minLength: 0)
        Button("Detach", systemImage: "eject") {
          send { .detachTab($0) }
        }
        .help("Close the live terminal. The session keeps running on \(hostName).")
      } else {
        if tab.isAwaitingInput {
          Label("Waiting for input", systemImage: "exclamationmark.bubble.fill")
            .foregroundStyle(.orange)
            .appFont(.callout)
          ForEach(RemoteKageQuickAnswer.allCases) { answer in
            Button(answer.title) {
              send { .quickAnswer($0, text: answer.text) }
            }
            .help(answer.help)
          }
        }
        Spacer(minLength: 0)
        Button("Refresh", systemImage: "arrow.clockwise") {
          send { .refreshScreen($0) }
        }
        .help("Reload this tab's screen from \(hostName)")
        attachButton
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private var attachButton: some View {
    switch availability {
    case .available:
      Button("Attach", systemImage: "terminal") {
        send { .attachTab($0) }
      }
      .help("Open a live terminal on this session over SSH")
    case .unavailable(let reason):
      Button("Attach", systemImage: "terminal") {}
        .disabled(true)
        .help(reason)
    }
  }
}
