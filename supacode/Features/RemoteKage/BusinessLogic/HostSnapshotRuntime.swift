import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

/// Thin main-actor gathering for the `host-snapshot` socket query: reads the
/// live app state and hands plain values to `HostSnapshotBuilder`. Kept free of
/// logic so the builder carries the tests.
enum HostSnapshotRuntime {
  private static let logger = SupaLogger("HostSnapshot")

  @MainActor
  static func inputs(store: StoreOf<AppFeature>, runtime: ContentRuntime = .liveValue) -> HostSnapshotBuilder.Inputs {
    @Dependency(\.zmxClient) var zmxClient
    let repositories = store.repositories
    let tabs = Dictionary(
      uniqueKeysWithValues: store.terminals.layouts.map { layoutState in
        (layoutState.id, tabInputs(layout: layoutState.layout, runtime: runtime))
      }
    )
    let agents = store.agentPresence.records.map { key, record in
      HostSnapshotBuilder.AgentInput(
        surfaceID: key.surfaceID,
        kind: key.agent.rawValue,
        activity: record.activity.rawValue
      )
    }
    let resources = Bundle.main.resourceURL
    return HostSnapshotBuilder.Inputs(
      repositories: Array(repositories.repositories),
      sidebar: repositories.sidebar,
      tabsByWorktree: tabs,
      agents: agents,
      zmxPath: zmxClient.executableURL()?.path(percentEncoded: false),
      cliPath: resources?.appending(path: "bin/supacode", directoryHint: .notDirectory).path(percentEncoded: false),
      kageVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
      machineName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    )
  }

  @MainActor
  private static func tabInputs(layout: PaneLayout, runtime: ContentRuntime) -> [HostSnapshotBuilder.TabInput] {
    let focusedTabID = layout.focusedPaneID.flatMap { layout.panes[id: $0]?.selectedTabID }
    return layout.panes.flatMap { pane in
      pane.tabs.map { tab in
        HostSnapshotBuilder.TabInput(
          id: tab.id.rawValue,
          title: TabTitle.resolved(for: tab, runtime: runtime),
          isFocused: tab.id == focusedTabID,
          surfaceID: tab.content.id.rawValue,
          isTerminal: tab.content.kind == .terminal,
          usesZmx: !tab.content.state.isEphemeral,
          workingDirectory: (runtime.content(for: tab.content.id) as? TerminalContent)?.reportedWorkingDirectory
        )
      }
    }
  }

  /// Answers the `host-snapshot` query: one row holding the snapshot JSON.
  @MainActor
  static func respond(clientFD: Int32, store: StoreOf<AppFeature>) {
    do {
      let snapshot = HostSnapshotBuilder.build(inputs(store: store))
      AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: try HostSnapshotBuilder.queryRows(snapshot))
    } catch {
      logger.warning("host-snapshot failed: \(error)")
      AgentHookSocketServer.sendCommandResponse(
        clientFD: clientFD, ok: false, error: "Could not build the host snapshot.")
    }
  }
}
