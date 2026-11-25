import SupacodeSettingsShared
import SwiftUI

/// A remote host's band at the top of its sidebar section: its own quiet
/// fill (lighter than the "Remote Hosts" group band, different from a
/// repository header), the host name in primary color, the status mark and a
/// chevron. A plain unselectable row; the whole band is the button, and the
/// awaiting-input mark stays visible while the host is collapsed.
struct RemoteKageHostHeaderRow: View {
  let host: RemoteKageSidebarModel.Host
  @Binding var isExpanded: Bool

  var body: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "desktopcomputer")
          .foregroundStyle(SidebarMachineGroup.remoteHosts.tint)
          .frame(width: 20)
          .accessibilityHidden(true)
        Text(host.name)
          .appFont(.subheadline, weight: .semibold)
          .foregroundStyle(.primary)
          .lineLimit(1)
        Image(systemName: host.indicator.systemImage)
          .imageScale(.small)
          .foregroundStyle(host.indicator.tint.color)
          .accessibilityHidden(true)
        Spacer(minLength: 4)
        if host.isAwaitingInput {
          RemoteKageAwaitingInputMark()
        }
        SidebarDisclosureChevron(isExpanded: isExpanded, isProminent: true)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(.fill.quaternary, in: .rect(cornerRadius: 6))
      .contentShape(.rect(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .help("\(host.indicator.help)\n\(isExpanded ? "Click to collapse" : "Click to expand")")
    .accessibilityLabel("\(host.name), \(host.indicator.label)")
    .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    .accessibilityAddTraits(.isHeader)
    .selectionDisabled()
    .moveDisabled(true)
  }
}

/// A workspace's (or "Other Projects") collapsible heading inside a host:
/// lighter than the host band (small secondary text and chevron, no fill).
struct RemoteKageWorkspaceHeader: View {
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

#Preview("Host and workspace headers") {
  func host(_ name: String, status: RemoteKageHostIndicator, awaiting: Bool) -> RemoteKageSidebarModel.Host {
    .init(id: UUID(), name: name, indicator: status, groups: [], isAwaitingInput: awaiting)
  }
  let online = RemoteKageHostIndicator.make(status: .online, snapshot: nil)
  let offline = RemoteKageHostIndicator.make(status: .offline("timeout"), snapshot: nil)
  return List {
    Section {
      RemoteKageHostHeaderRow(host: host("Mac mini", status: online, awaiting: false), isExpanded: .constant(true))
      RemoteKageWorkspaceHeader(title: "Work", isExpanded: .constant(true), isAwaitingInput: false)
      Text("A repository row").padding(.leading, 12)
      RemoteKageWorkspaceHeader(title: "Side", isExpanded: .constant(false), isAwaitingInput: true)
    }
    Section {
      RemoteKageHostHeaderRow(host: host("Studio", status: offline, awaiting: true), isExpanded: .constant(false))
    }
  }
  .listStyle(.sidebar)
  .frame(width: 260, height: 260)
}
