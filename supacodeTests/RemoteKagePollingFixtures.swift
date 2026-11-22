import Dependencies
import Foundation

@testable import supacode

/// Snapshot builders shared by the Remote Kage polling tests.
nonisolated enum RemoteKagePollingFixtures {
  static let hostID = UUID(10)
  static let otherHostID = UUID(11)
  static let worktreeID = "/Users/ahmet/Developer/kage"

  static let host = RemoteKageHost(id: hostID, name: "Mini", username: "ahmet", address: "mini.example")
  static let otherHost = RemoteKageHost(id: otherHostID, name: "Mini 2", username: "ahmet", address: "mini2.example")

  static var selection: RemoteKageSelection {
    RemoteKageSelection(hostID: hostID, worktreeID: worktreeID)
  }

  static func key(_ tabID: String, host: UUID = hostID) -> RemoteKageTabKey {
    RemoteKageTabKey(hostID: host, tabID: tabID)
  }

  static func tab(
    _ id: String,
    title: String? = nil,
    focused: Bool = false,
    activity: String? = nil
  ) -> HostSnapshot.Tab {
    HostSnapshot.Tab(
      id: id,
      title: title ?? id,
      isFocused: focused,
      surfaceID: "surface-\(id)",
      zmxSession: "supa-\(id)",
      agents: activity.map { [HostSnapshot.Agent(kind: "claude", activity: $0)] } ?? []
    )
  }

  static func snapshot(tabs: [HostSnapshot.Tab], worktreeID: String = worktreeID) -> HostSnapshot {
    HostSnapshot(
      schemaVersion: HostSnapshot.currentSchemaVersion,
      kageVersion: "1.2.3",
      machineName: "Mini",
      zmxPath: "/Applications/Kage.app/Contents/Resources/zmx/zmx",
      cliPath: "/Applications/Kage.app/Contents/Resources/bin/supacode",
      workspaces: [HostSnapshot.Workspace(id: "w1", name: "Work")],
      repositories: [
        HostSnapshot.Repository(
          id: "/Users/ahmet/Developer/kage",
          name: "kage",
          rootPath: "/Users/ahmet/Developer/kage",
          workspaceID: "w1",
          isGitRepository: true,
          color: nil,
          worktrees: [
            HostSnapshot.Worktree(
              id: worktreeID,
              name: "main",
              path: worktreeID,
              isMain: true,
              isPinned: false,
              tabs: tabs
            )
          ]
        )
      ]
    )
  }
}
