import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// The "Remote Hosts" group header and, under it, one collapsible sidebar
/// section per remote Kage host, appended after the local sections inside the
/// sidebar's `List`. Each host's workspaces collapse too; open / closed state
/// persists (`RemoteKageSidebarExpansion`) and never enters `SidebarStructure`. Reads only `RemoteKageFeature`
/// state, through the pure `RemoteKageSidebarModel`, so a poll tick never
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
    Section(isExpanded: $isHostExpanded) {
      if let groups = host.groups {
        if groups.isEmpty {
          Text("No projects on this host")
            .appFont(.footnote)
            .foregroundStyle(.secondary)
            .moveDisabled(true)
        }
        ForEach(groups) { group in
          RemoteKageGroupRows(hostName: host.name, group: group, isExpanded: groupBinding(group.id))
        }
      } else {
        RemoteKageHostStatusRow(indicator: host.indicator)
      }
    } header: {
      RemoteKageHostHeaderView(host: host)
    }
  }
}

private struct RemoteKageGroupRows: View {
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
        RemoteKageRepositoryRows(hostName: hostName, repository: repository)
      }
    }
  }
}

/// A workspace's (or "Other Projects") collapsible heading inside a host.
private struct RemoteKageWorkspaceHeader: View {
  let title: String
  @Binding var isExpanded: Bool
  let isAwaitingInput: Bool

  var body: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
    } label: {
      HStack(spacing: 6) {
        Text(title)
          .appFont(.caption, weight: .medium)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 4)
        if isAwaitingInput, !isExpanded {
          RemoteKageAwaitingInputMark()
        }
        SidebarDisclosureChevron(isExpanded: isExpanded)
      }
      .padding(.top, 4)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help(isExpanded ? "Collapse \(title)" : "Expand \(title)")
    .accessibilityLabel(title)
    .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    .accessibilityAddTraits(.isHeader)
    .selectionDisabled()
    .moveDisabled(true)
  }
}

private struct RemoteKageRepositoryRows: View {
  let hostName: String
  let repository: RemoteKageSidebarModel.Repository

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
      ForEach(repository.worktrees) { worktree in
        RemoteKageWorktreeRowView(
          hostName: hostName,
          repositoryName: repository.name,
          title: worktree.name,
          subtitle: nil,
          tint: nil,
          worktree: worktree
        )
        .padding(.leading, 12)
        .tag(SidebarSelection.remoteKage(worktree.selection))
      }
    }
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

private struct RemoteKageHostHeaderView: View {
  let host: RemoteKageSidebarModel.Host

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: "desktopcomputer")
        .imageScale(.small)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(host.name)
        .foregroundStyle(.primary)
        .lineLimit(1)
      Image(systemName: host.indicator.systemImage)
        .imageScale(.small)
        .foregroundStyle(host.indicator.tint.color)
        .accessibilityLabel(host.indicator.label)
      if host.isAwaitingInput {
        RemoteKageAwaitingInputMark()
      }
    }
    .appFontInheriting(.subheadline, weight: .semibold)
    .help(host.indicator.help)
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
