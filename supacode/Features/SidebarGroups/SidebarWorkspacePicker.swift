import Foundation

/// Where the workspace picker lives. The pinned control above the sidebar
/// list is the only placement without remote hosts; once a host is configured
/// the "This Mac" band carries the picker so the pinned strip is not shown.
enum SidebarWorkspacePickerPlacement: Equatable, Sendable {
  case pinnedAboveList
  case thisMacBand
}

/// Pure decisions behind the workspace picker, shared by both placements so
/// they cannot drift apart.
enum SidebarWorkspacePicker {
  static let allProjectsTitle = "All Projects"

  static func placement(hostCount: Int) -> SidebarWorkspacePickerPlacement {
    SidebarMachineGroups.showsGroupHeaders(hostCount: hostCount) ? .thisMacBand : .pinnedAboveList
  }

  /// Most characters the band shows of a workspace name. The band's menu is
  /// laid out at its natural width (SwiftUI cannot give an AppKit-backed menu
  /// the room that is left), so a long name is cut here rather than pushing
  /// the expand chevron out of the sidebar. The full name stays in the help
  /// text and the accessibility value.
  static let bandTitleLimit = 13

  static func bandTitle(_ title: String) -> String {
    guard title.count > bandTitleLimit else { return title }
    return title.prefix(bandTitleLimit - 1).trimmingCharacters(in: .whitespaces) + "…"
  }

  /// The label both placements show: the active workspace's name, or
  /// "All Projects" when no workspace filters the sidebar.
  static func title(activeWorkspaceName: String?) -> String {
    let name = activeWorkspaceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.isEmpty ? allProjectsTitle : name
  }
}
