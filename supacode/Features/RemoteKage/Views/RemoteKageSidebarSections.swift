import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// The "Remote Hosts" group header and, under it, one collapsible sidebar
/// section per remote Kage host, appended after the local sections inside the
/// sidebar's `List`. Each host's workspaces collapse too; open / closed state
/// persists (`RemoteKageSidebarExpansion`) and never enters `SidebarStructure`.
/// Reads only `RemoteKageFeature` state, through the pure `RemoteKageSidebarModel`, so a poll tick never
/// invalidates a local row. Worktree rows tag `SidebarSelection.remoteKage`
/// and share the list's selection with the local rows.
struct RemoteKageSidebarSections: View {
  let store: StoreOf<RemoteKageFeature>
  @Shared(.sidebarRemoteHostsExpanded) private var isRemoteHostsExpanded: Bool
  @Shared(.remoteKageSidebarExpansion) private var expansion: RemoteKageSidebarExpansion

  var body: some View {
    let model = RemoteKageSidebarModel.make(hosts: store.hosts, hostStates: store.hostStates)
    if SidebarMachineGroups.showsGroupHeaders(hostCount: model.hosts.count) {
      SidebarMachineGroupHeader(
        group: .remoteHosts,
        isExpanded: Binding($isRemoteHostsExpanded),
        summary: SidebarMachineGroup.remoteHosts.summary(count: model.hosts.count),
        isAwaitingInput: model.isAwaitingInput
      )
      if isRemoteHostsExpanded {
        ForEach(model.hosts) { host in
          RemoteKageHostSection(
            host: host,
            isHostExpanded: hostBinding(for: host.id),
            groupBinding: { groupBinding(host: host.id, group: $0) }
          )
        }
      }
    }
  }

  private func hostBinding(for hostID: RemoteKageHost.ID) -> Binding<Bool> {
    Binding(
      get: { expansion.isHostExpanded(hostID) },
      set: { isExpanded in $expansion.withLock { $0.setHost(hostID, expanded: isExpanded) } }
    )
  }

  private func groupBinding(
    host hostID: RemoteKageHost.ID,
    group: RemoteKageSidebarModel.Group.GroupID
  ) -> Binding<Bool> {
    Binding(
      get: { expansion.isGroupExpanded(host: hostID, group: group) },
      set: { isExpanded in $expansion.withLock { $0.setGroup(host: hostID, group: group, expanded: isExpanded) } }
    )
  }
}

private struct RemoteKageHostSection: View {
  let host: RemoteKageSidebarModel.Host
  @Binding var isHostExpanded: Bool
  let groupBinding: (RemoteKageSidebarModel.Group.GroupID) -> Binding<Bool>

  var body: some View {
    // The band is an untagged header row rather than the `Section` header:
    // a sidebar `Section` header cannot carry a filled band, and a row keeps
    // the whole band clickable and the awaiting mark visible while collapsed.
    Section {
      RemoteKageHostHeaderRow(host: host, isExpanded: $isHostExpanded)
      if isHostExpanded {
        if let groups = host.groups {
          if groups.isEmpty {
            Text("No projects on this host")
              .appFont(.footnote)
              .foregroundStyle(.secondary)
              .moveDisabled(true)
          }
          ForEach(groups) { group in
            RemoteKageGroupRows(
              hostID: host.id, hostName: host.name, group: group, isExpanded: groupBinding(group.id))
          }
        } else {
          RemoteKageHostStatusRow(indicator: host.indicator)
        }
      }
    }
  }
}

private struct RemoteKageGroupRows: View {
  let hostID: RemoteKageHost.ID
  let hostName: String
  let group: RemoteKageSidebarModel.Group
  @Binding var isExpanded: Bool

  var body: some View {
    if let title = group.title {
      RemoteKageWorkspaceHeader(
        title: title,
        isExpanded: $isExpanded,
        isAwaitingInput: group.isAwaitingInput
      )
    }
    // A host without workspaces has one untitled group that cannot collapse.
    if isExpanded || group.title == nil {
      ForEach(group.repositories) { repository in
        RemoteKageRepositoryRows(hostID: hostID, hostName: hostName, repository: repository)
      }
    }
  }
}

private struct RemoteKageRepositoryRows: View {
  let hostID: RemoteKageHost.ID
  let hostName: String
  let repository: RemoteKageSidebarModel.Repository
  /// The local setting: remote worktrees nest by branch exactly when local ones do.
  @Shared(.sidebarNestWorktreesByBranch) private var nestWorktreesByBranch: Bool
  @Shared(.remoteKageSidebarExpansion) private var expansion: RemoteKageSidebarExpansion

  var body: some View {
    if let worktree = repository.soleWorktree {
      RemoteKageWorktreeRowView(
        hostName: hostName,
        repositoryName: repository.name,
        title: repository.name,
        subtitle: repository.isGitRepository ? worktree.name : nil,
        tint: repository.color,
        worktree: worktree
      )
      .tag(SidebarSelection.remoteKage(worktree.selection))
    } else {
      RemoteKageRepositoryLabel(repository: repository)
      let rows = RemoteKageBranchNesting.rows(
        for: repository,
        nestByBranch: nestWorktreesByBranch,
        collapsed: expansion.collapsedBranchGroups(host: hostID, repository: repository.id)
      )
      ForEach(rows) { row in
        switch row {
        case .worktree(let worktree, let depth, let title):
          RemoteKageWorktreeRowView(
            hostName: hostName,
            repositoryName: repository.name,
            title: title,
            subtitle: nil,
            tint: nil,
            worktree: worktree
          )
          .padding(.leading, 12 + CGFloat(depth) * SidebarNestLayout.indentStep)
          .tag(SidebarSelection.remoteKage(worktree.selection))
        case .group(let group):
          RemoteKageBranchGroupHeader(group: group) {
            $expansion.withLock {
              $0.setBranchGroup(host: hostID, repository: repository.id, group.key, expanded: group.isCollapsed)
            }
          }
          .padding(.leading, 12 + CGFloat(group.depth) * SidebarNestLayout.indentStep)
        }
      }
    }
  }
}

/// A branch path group among a remote repository's worktrees, like the local
/// sidebar's group header: click to collapse or expand; a collapsed group shows
/// what its worktrees are up to.
private struct RemoteKageBranchGroupHeader: View {
  let group: RemoteKageBranchNesting.Group
  let toggle: () -> Void

  var body: some View {
    Button {
      withAnimation(.easeOut(duration: 0.2)) { toggle() }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .appFont(.caption, weight: .semibold)
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
          .animation(.easeInOut(duration: 0.15), value: group.isCollapsed)
          .frame(width: SidebarNestLayout.groupChevronWidth)
          .padding(.trailing, SidebarNestLayout.leadingSlotWidth - SidebarNestLayout.groupChevronWidth)
          .accessibilityHidden(true)
        Text(group.label)
          .appFont(.body)
          .lineLimit(1)
        Spacer(minLength: 0)
        if group.isCollapsed {
          if group.isAwaitingInput {
            RemoteKageAwaitingInputMark()
          }
          AgentAvatarGroupView(instances: Array(group.worktrees.flatMap(\.agents).prefix(3)))
        }
      }
      .contentShape(.interaction, .rect)
    }
    .buttonStyle(.plain)
    .moveDisabled(true)
    .help(group.isCollapsed ? "Expand \(group.label)" : "Collapse \(group.label)")
    .accessibilityLabel("\(group.label) group, \(group.isCollapsed ? "collapsed" : "expanded")")
  }
}

/// A remote repository with several worktrees: an unselectable label above them.
private struct RemoteKageRepositoryLabel: View {
  let repository: RemoteKageSidebarModel.Repository

  var body: some View {
    Label {
      Text(repository.name)
        .appFont(.subheadline, weight: .semibold)
        .foregroundStyle(repository.color?.color ?? .secondary)
        .lineLimit(1)
    } icon: {
      Image(systemName: repository.isGitRepository ? "folder" : "folder.fill")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .moveDisabled(true)
  }
}

private struct RemoteKageWorktreeRowView: View {
  let hostName: String
  let repositoryName: String
  let title: String
  let subtitle: String?
  let tint: RepositoryColor?
  let worktree: RemoteKageSidebarModel.Worktree

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: worktree.isMain ? "arrow.triangle.branch" : "arrow.triangle.pull")
        .foregroundStyle(tint?.color ?? .secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .appFont(.body, weight: worktree.isAwaitingInput ? .semibold : nil)
          .lineLimit(1)
        if let subtitle {
          Text(subtitle)
            .appFont(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      if worktree.isAwaitingInput {
        RemoteKageAwaitingInputMark()
      }
      if worktree.unknownAgentCount > 0 {
        Image(systemName: "sparkles")
          .imageScale(.small)
          .foregroundStyle(.secondary)
          .help("\(worktree.unknownAgentCount) agent(s) of a kind this Kage doesn't recognize")
          .accessibilityLabel("\(worktree.unknownAgentCount) other agents")
      }
      AgentAvatarGroupView(instances: worktree.agents)
    }
    .contentShape(.rect)
    .moveDisabled(true)
    .help(helpText)
  }

  private var helpText: String {
    let tabs = worktree.tabCount == 1 ? "1 tab" : "\(worktree.tabCount) tabs"
    let waiting = worktree.isAwaitingInput ? " · waiting for input" : ""
    return "\(hostName) · \(repositoryName) · \(worktree.name) (\(tabs)\(waiting))"
  }
}

/// Marks a remote worktree, tab or host with an agent waiting for input.
struct RemoteKageAwaitingInputMark: View {
  var body: some View {
    Image(systemName: "exclamationmark.bubble.fill")
      .imageScale(.small)
      .foregroundStyle(.orange)
      .help("An agent is waiting for your input")
      .accessibilityLabel("Waiting for input")
  }
}

private struct RemoteKageHostStatusRow: View {
  let indicator: RemoteKageHostIndicator

  var body: some View {
    Label {
      Text(indicator.label)
        .appFont(.footnote)
        .foregroundStyle(.secondary)
    } icon: {
      Image(systemName: indicator.systemImage)
        .foregroundStyle(indicator.tint.color)
        .accessibilityHidden(true)
    }
    .help(indicator.help)
    .moveDisabled(true)
  }
}

extension RemoteKageHostIndicator.Tint {
  var color: Color {
    switch self {
    case .green: .green
    case .orange: .orange
    case .red: .red
    case .yellow: .yellow
    case .secondary: .secondary
    }
  }
}
