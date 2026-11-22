import Foundation
import SupacodeSettingsShared

/// What the sidebar's remote Kage host sections render, derived purely from
/// `RemoteKageFeature` state. Remote rows never enter `SidebarStructure` or
/// `sidebarItems`: the host sections read only this projection, so a poll
/// tick invalidates the remote sections and nothing local.
struct RemoteKageSidebarModel: Equatable {
  var hosts: [Host]

  struct Host: Equatable, Identifiable {
    let id: RemoteKageHost.ID
    var name: String
    var indicator: RemoteKageHostIndicator
    /// nil until the host's first snapshot: the section shows one status row.
    var groups: [Group]?
    /// Some agent on the host waits for input (shown on the header, so a
    /// collapsed section still says so).
    var isAwaitingInput: Bool
  }

  /// One of the host's workspaces, or its ungrouped repositories (last).
  struct Group: Equatable, Identifiable {
    enum GroupID: Hashable {
      case workspace(String)
      case ungrouped
    }

    let id: GroupID
    /// The workspace name; for ungrouped repositories "Other Projects" when
    /// they follow workspace groups, nil when the host has no workspaces.
    var title: String?
    var repositories: [Repository]
  }

  struct Repository: Equatable, Identifiable {
    let id: String
    var name: String
    var color: RepositoryColor?
    var isGitRepository: Bool
    var worktrees: [Worktree]

    /// A repository with a single worktree renders as that one row.
    var soleWorktree: Worktree? { worktrees.count == 1 ? worktrees.first : nil }
  }

  struct Worktree: Equatable, Identifiable {
    let selection: RemoteKageSelection
    var name: String
    var isMain: Bool
    var isPinned: Bool
    var tabCount: Int
    /// Agents across the worktree's tabs that map to a known `SkillAgent`,
    /// error first, then awaiting input (like the local sidebar's badges).
    var agents: [AgentPresenceFeature.AgentInstance]
    /// Agents of a kind this Mac's Kage doesn't know (a newer host).
    var unknownAgentCount: Int
    var isAwaitingInput: Bool
    var isBusy: Bool

    var id: RemoteKageSelection { selection }
  }

  static let ungroupedTitle = "Other Projects"

  static func make(
    hosts: [RemoteKageHost],
    hostStates: [RemoteKageHost.ID: RemoteKageFeature.HostState]
  ) -> Self {
    Self(
      hosts: hosts.map { host in
        let hostState = hostStates[host.id] ?? RemoteKageFeature.HostState()
        let snapshot = hostState.lastSnapshot
        let groups = snapshot.map { groups(for: $0, hostID: host.id) }
        let isAwaitingInput =
          groups?.contains { group in
            group.repositories.contains { $0.worktrees.contains(where: \.isAwaitingInput) }
          } ?? false
        return Host(
          id: host.id,
          name: host.name,
          indicator: RemoteKageHostIndicator.make(status: hostState.status, snapshot: snapshot),
          groups: groups,
          isAwaitingInput: isAwaitingInput
        )
      }
    )
  }

  /// The host's own grouping: its workspaces in switcher order (empty ones
  /// omitted), each with its repositories in sidebar order, then the
  /// repositories in no (or an unknown) workspace.
  static func groups(for snapshot: HostSnapshot, hostID: RemoteKageHost.ID) -> [Group] {
    let workspaceIDs = Set(snapshot.workspaces.map(\.id))
    var groups: [Group] = snapshot.workspaces.compactMap { workspace in
      let repositories = snapshot.repositories
        .filter { $0.workspaceID == workspace.id }
        .map { repository(from: $0, hostID: hostID) }
      guard !repositories.isEmpty else { return nil }
      return Group(id: .workspace(workspace.id), title: workspace.name, repositories: repositories)
    }
    let ungrouped = snapshot.repositories
      .filter { repository in repository.workspaceID.map { !workspaceIDs.contains($0) } ?? true }
      .map { repository(from: $0, hostID: hostID) }
    if !ungrouped.isEmpty {
      groups.append(
        Group(id: .ungrouped, title: groups.isEmpty ? nil : ungroupedTitle, repositories: ungrouped)
      )
    }
    return groups
  }

  /// Every agent across `tabs`, duplicates kept, as badge instances.
  static func agentInstances(
    for tabs: [HostSnapshot.Tab]
  ) -> (known: [AgentPresenceFeature.AgentInstance], unknownCount: Int) {
    var known: [AgentPresenceFeature.AgentInstance] = []
    var unknownCount = 0
    for agent in tabs.flatMap(\.agents) {
      guard let kind = SkillAgent(rawValue: agent.kind) else {
        unknownCount += 1
        continue
      }
      let activity = AgentPresenceFeature.Activity(rawValue: agent.activity) ?? .idle
      known.append(AgentPresenceFeature.AgentInstance(agent: kind, activity: activity))
    }
    known.sort { lhs, rhs in
      let lhsError = lhs.activity == .error
      let rhsError = rhs.activity == .error
      if lhsError != rhsError { return lhsError }
      if lhs.awaitingInput != rhs.awaitingInput { return lhs.awaitingInput }
      return lhs.agent.rawValue < rhs.agent.rawValue
    }
    return (known, unknownCount)
  }

  private static func repository(
    from repository: HostSnapshot.Repository,
    hostID: RemoteKageHost.ID
  ) -> Repository {
    Repository(
      id: repository.id,
      name: repository.name,
      color: repository.color.flatMap { RepositoryColor.parse($0.rawValue) },
      isGitRepository: repository.isGitRepository,
      worktrees: repository.worktrees.map { worktree in
        let agents = agentInstances(for: worktree.tabs)
        return Worktree(
          selection: RemoteKageSelection(hostID: hostID, worktreeID: worktree.id),
          name: worktree.name,
          isMain: worktree.isMain,
          isPinned: worktree.isPinned,
          tabCount: worktree.tabs.count,
          agents: agents.known,
          unknownAgentCount: agents.unknownCount,
          isAwaitingInput: worktree.tabs.contains(where: \.isAwaitingInput),
          isBusy: worktree.tabs.contains(where: \.isBusy)
        )
      }
    )
  }
}

/// The small status mark on a host's sidebar header, with its tooltip.
struct RemoteKageHostIndicator: Equatable {
  /// Mapped to system colors by the view.
  enum Tint: Equatable {
    case green
    case orange
    case red
    case yellow
    case secondary
  }

  var systemImage: String
  var tint: Tint
  var label: String
  var help: String

  static func make(status: RemoteKageFeature.HostStatus, snapshot: HostSnapshot?) -> Self {
    var indicator: Self =
      switch status {
      case .connecting:
        Self(systemImage: "circle.dotted", tint: .secondary, label: "Connecting…", help: "Connecting…")
      case .online:
        Self(systemImage: "circle.fill", tint: .green, label: "Online", help: "Online")
      case .offline(let message):
        Self(systemImage: "bolt.horizontal.circle", tint: .red, label: "Offline", help: "Offline: \(message)")
      case .kageNotRunning:
        Self(
          systemImage: "pause.circle.fill",
          tint: .orange,
          label: "Kage isn't running",
          help: "Kage isn't running: open Kage on that Mac."
        )
      case .needsUpdate:
        Self(
          systemImage: "arrow.down.circle.fill",
          tint: .yellow,
          label: "Needs update",
          help: "Needs update: update Kage on that Mac."
        )
      }
    if let snapshot {
      indicator.help += "\n\(snapshot.machineName) · Kage \(snapshot.kageVersion)"
    }
    return indicator
  }
}
