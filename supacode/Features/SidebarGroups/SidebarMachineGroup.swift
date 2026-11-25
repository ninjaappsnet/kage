import Foundation
import Sharing

/// The two top-level accordion groups the sidebar shows once a remote Kage
/// host is configured: every local section under "This Mac", every host
/// section under "Remote Hosts". With no host configured the groups do not
/// exist and the sidebar renders as it always did.
enum SidebarMachineGroup: String, Equatable, Sendable, CaseIterable {
  case thisMac
  case remoteHosts

  var title: String {
    switch self {
    case .thisMac: "This Mac"
    case .remoteHosts: "Remote Hosts"
    }
  }

  var systemImage: String {
    switch self {
    case .thisMac: "laptopcomputer"
    case .remoteHosts: "network"
    }
  }

  /// The group a sidebar selection lives in, so a selection made while that
  /// group is collapsed (hotkey, notification click, palette) can open it.
  static func containing(_ selection: SidebarSelection?) -> Self? {
    switch selection {
    case .worktree, .archivedWorktrees, .failedRepository: .thisMac
    case .remoteKage: .remoteHosts
    case nil: nil
    }
  }
}

/// Pure decisions behind the machine groups, kept out of the views so they
/// are testable and so `SidebarListView` only carries one-line calls.
enum SidebarMachineGroups {
  static func showsGroupHeaders(hostCount: Int) -> Bool {
    hostCount > 0
  }

  /// The local sections to render. Collapsing "This Mac" feeds an empty
  /// array into the sidebar's `ForEach`; the `onMove` offsets stay correct
  /// because nothing is draggable while the group is closed. Without remote
  /// hosts there is no header to reopen the group, so nothing is ever hidden.
  static func visibleLocalSections<Section>(
    _ sections: [Section],
    hasRemoteHosts: Bool,
    isThisMacExpanded: Bool
  ) -> [Section] {
    guard hasRemoteHosts, !isThisMacExpanded else { return sections }
    return []
  }
}

nonisolated extension SharedReaderKey where Self == AppStorageKey<Bool>.Default {
  /// "This Mac" group open / closed. Open by default.
  static var sidebarThisMacExpanded: Self {
    Self[.appStorage("sidebarThisMacExpanded"), default: true]
  }

  /// "Remote Hosts" group open / closed. Open by default.
  static var sidebarRemoteHostsExpanded: Self {
    Self[.appStorage("sidebarRemoteHostsExpanded"), default: true]
  }
}
