import SupacodeSettingsShared
import SwiftUI

/// The prominent top-level row above a machine group's sections ("This Mac" /
/// "Remote Hosts"). A plain, unselectable row in the sidebar `List`: heavier
/// than any repository or host header so it reads as the level above them.
struct SidebarMachineGroupHeader: View {
  let group: SidebarMachineGroup
  @Binding var isExpanded: Bool
  /// Marks a collapsed group that hides an agent waiting for input.
  var isAwaitingInput = false

  var body: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: group.systemImage)
          .foregroundStyle(.secondary)
          .frame(width: 20)
          .accessibilityHidden(true)
        Text(group.title)
          .appFont(.headline)
          .foregroundStyle(.primary)
          .lineLimit(1)
        Spacer(minLength: 4)
        if isAwaitingInput, !isExpanded {
          RemoteKageAwaitingInputMark()
        }
        SidebarDisclosureChevron(isExpanded: isExpanded)
      }
      .padding(.vertical, 2)
      .contentShape(.rect)
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

/// The disclosure chevron shared by the machine group and workspace headers.
struct SidebarDisclosureChevron: View {
  let isExpanded: Bool

  var body: some View {
    Image(systemName: "chevron.right")
      .imageScale(.small)
      .fontWeight(.semibold)
      .foregroundStyle(.tertiary)
      .rotationEffect(.degrees(isExpanded ? 90 : 0))
      .accessibilityHidden(true)
  }
}
