import SupacodeSettingsShared
import SwiftUI

extension SidebarMachineGroup {
  /// System tints that tell the two groups apart at a glance.
  var tint: Color {
    switch self {
    case .thisMac: .accentColor
    case .remoteHosts: .indigo
    }
  }
}

/// The prominent top-level row above a machine group's sections ("This Mac" /
/// "Remote Hosts"): a full-width tinted band, so it reads as the level above
/// the repository and host headers and as something to click. A plain,
/// unselectable row in the sidebar `List`; the whole band is the button.
struct SidebarMachineGroupHeader: View {
  let group: SidebarMachineGroup
  @Binding var isExpanded: Bool
  /// Shown on the right while the group is collapsed ("3 projects").
  var summary: String?
  /// Marks a collapsed group that hides an agent waiting for input.
  var isAwaitingInput = false

  var body: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: group.systemImage)
          .foregroundStyle(group.tint)
          .frame(width: 22)
          .accessibilityHidden(true)
        Text(group.title)
          .appFont(.headline)
          .foregroundStyle(.primary)
          .lineLimit(1)
        Spacer(minLength: 4)
        if !isExpanded {
          if isAwaitingInput {
            RemoteKageAwaitingInputMark()
          }
          if let summary {
            Text(summary)
              .appFont(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        SidebarDisclosureChevron(isExpanded: isExpanded, isProminent: true)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(group.tint.opacity(0.12), in: .rect(cornerRadius: 8))
      .contentShape(.rect(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .help(isExpanded ? "Collapse \(group.title)" : "Expand \(group.title)")
    .accessibilityLabel(group.title)
    .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    .accessibilityAddTraits(.isHeader)
    .selectionDisabled()
    .moveDisabled(true)
  }
}

/// The disclosure chevron shared by the group, host and workspace headers.
struct SidebarDisclosureChevron: View {
  let isExpanded: Bool
  /// A clearly visible chevron for the group and host bands; the subtle one
  /// is for workspace headings.
  var isProminent = false

  var body: some View {
    Image(systemName: "chevron.right")
      .imageScale(isProminent ? .medium : .small)
      .fontWeight(.semibold)
      .foregroundStyle(isProminent ? .secondary : .tertiary)
      .rotationEffect(.degrees(isExpanded ? 90 : 0))
      .accessibilityHidden(true)
  }
}

#Preview("Machine group headers") {
  VStack(spacing: 8) {
    SidebarMachineGroupHeader(group: .thisMac, isExpanded: .constant(true))
    SidebarMachineGroupHeader(group: .thisMac, isExpanded: .constant(false), summary: "4 projects")
    SidebarMachineGroupHeader(group: .remoteHosts, isExpanded: .constant(true))
    SidebarMachineGroupHeader(
      group: .remoteHosts,
      isExpanded: .constant(false),
      summary: "2 hosts",
      isAwaitingInput: true
    )
  }
  .padding()
  .frame(width: 260)
}
