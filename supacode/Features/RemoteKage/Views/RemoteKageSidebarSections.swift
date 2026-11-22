import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// One collapsible sidebar section per remote Kage host, appended after the
/// local sections inside the sidebar's `List`. Reads only `RemoteKageFeature`
/// state, through the pure `RemoteKageSidebarModel`, so a poll tick never
/// invalidates a local row. Worktree rows tag `SidebarSelection.remoteKage`
/// and share the list's selection with the local rows.
struct RemoteKageSidebarSections: View {
  let store: StoreOf<RemoteKageFeature>
  @State private var collapsedHostIDs: Set<RemoteKageHost.ID> = []

  var body: some View {
    let model = RemoteKageSidebarModel.make(hosts: store.hosts, hostStates: store.hostStates)
    ForEach(model.hosts) { host in
      RemoteKageHostSection(host: host, isExpanded: expansionBinding(for: host.id))
    }
  }

  private func expansionBinding(for hostID: RemoteKageHost.ID) -> Binding<Bool> {
    Binding(
      get: { !collapsedHostIDs.contains(hostID) },
      set: { isExpanded in
        if isExpanded {
          collapsedHostIDs.remove(hostID)
        } else {
          collapsedHostIDs.insert(hostID)
        }
      }
    )
  }
}

private struct RemoteKageHostSection: View {
  let host: RemoteKageSidebarModel.Host
  @Binding var isExpanded: Bool

  var body: some View {
    Section(isExpanded: $isExpanded) {
      if let groups = host.groups {
        if groups.isEmpty {
          Text("No projects on this host")
            .appFont(.footnote)
            .foregroundStyle(.secondary)
            .moveDisabled(true)
        }
        ForEach(groups) { group in
          RemoteKageGroupRows(hostName: host.name, group: group)
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

  var body: some View {
    if let title = group.title {
      Text(title)
        .appFont(.caption, weight: .medium)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .padding(.top, 4)
        .moveDisabled(true)
        .accessibilityAddTraits(.isHeader)
    }
    ForEach(group.repositories) { repository in
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
        .foregroundStyle(.secondary)
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
