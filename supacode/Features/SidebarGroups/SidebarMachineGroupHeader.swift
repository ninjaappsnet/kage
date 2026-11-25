import ComposableArchitecture
import OrderedCollections
import SupacodeSettingsShared
import SwiftUI

extension SidebarMachineGroup {
  /// System tints that tell the two groups apart at a glance.
  var tint: Color {
    switch self {
    case .thisMac: .accentColor
    case .remoteHosts: .purple
    }
  }
}

/// The prominent top-level row above a machine group's sections ("This Mac" /
/// "Remote Hosts"): a full-width tinted band, so it reads as the level above
/// the repository and host headers and as something to click. A plain,
/// unselectable row in the sidebar `List`; the whole band toggles the group,
/// except the optional `accessory` (the workspace picker on "This Mac"),
/// which is its own control between the title and the collapsed summary.
struct SidebarMachineGroupHeader<Accessory: View>: View {
  let group: SidebarMachineGroup
  @Binding var isExpanded: Bool
  /// Shown on the right while the group is collapsed ("3 projects").
  var summary: String?
  /// Marks a collapsed group that hides an agent waiting for input.
  var isAwaitingInput = false
  @ViewBuilder var accessory: Accessory

  var body: some View {
    HStack(spacing: 6) {
      toggleButton {
        HStack(spacing: 8) {
          Image(systemName: group.systemImage)
            .foregroundStyle(group.tint)
            .frame(width: 22)
            .accessibilityHidden(true)
          Text(group.title)
            .appFont(.headline)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
        }
      }
      .accessibilityLabel(group.title)
      .accessibilityValue(isExpanded ? "expanded" : "collapsed")
      .accessibilityAddTraits(.isHeader)
      accessory
        .layoutPriority(1)
      toggleButton {
        HStack(spacing: 8) {
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
        .contentShape(.rect)
      }
      // The leading button already announces the group; this one only
      // widens the click target.
      .accessibilityHidden(true)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(group.tint.opacity(0.2), in: .rect(cornerRadius: 8))
    .contentShape(.rect(cornerRadius: 8))
    .selectionDisabled()
    .moveDisabled(true)
  }

  private func toggleButton<ButtonLabel: View>(@ViewBuilder label: () -> ButtonLabel) -> some View {
    Button {
      withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
    } label: {
      label()
    }
    .buttonStyle(.plain)
    .help(isExpanded ? "Collapse \(group.title)" : "Expand \(group.title)")
  }
}

extension SidebarMachineGroupHeader where Accessory == EmptyView {
  init(
    group: SidebarMachineGroup,
    isExpanded: Binding<Bool>,
    summary: String? = nil,
    isAwaitingInput: Bool = false
  ) {
    self.init(
      group: group,
      isExpanded: isExpanded,
      summary: summary,
      isAwaitingInput: isAwaitingInput,
      accessory: { EmptyView() }
    )
  }
}

/// The workspace picker as it sits in the "This Mac" band: "<workspace> ⌃⌄"
/// next to the group title. Same menu and prompt as the pinned strip
/// (`WorkspacePickerMenu`); only the label differs.
struct SidebarWorkspaceBandMenu: View {
  let store: StoreOf<RepositoriesFeature>

  private var activeTitle: String {
    let sidebar = store.state.sidebar
    return SidebarWorkspacePicker.title(
      activeWorkspaceName: sidebar.activeWorkspaceID.flatMap { sidebar.workspaces[$0]?.name })
  }

  var body: some View {
    WorkspacePickerMenu(store: store) { title in
      HStack(spacing: 4) {
        Text("·")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(SidebarWorkspacePicker.bandTitle(title))
          .appFont(.footnote, weight: .medium)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .contentShape(.rect)
    }
    // A SwiftUI-drawn label (`.button` + plain): the `.borderlessButton` style
    // hands the label to AppKit, which drops everything but the first image.
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .accessibilityLabel("Switch workspace")
    .accessibilityValue(activeTitle)
    .help("Switch workspace (now \(activeTitle)): create, rename, or delete one to filter the projects shown")
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
