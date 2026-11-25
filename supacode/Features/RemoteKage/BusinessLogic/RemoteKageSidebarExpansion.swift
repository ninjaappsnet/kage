import Foundation
import Sharing

/// Which remote hosts and which of a host's workspaces are collapsed in the
/// sidebar. Stores only what is collapsed, so a new host or workspace is open
/// by default. Persisted as one JSON string in `UserDefaults`; kept out of
/// `SidebarStructure` so toggling a remote group never touches local rows.
nonisolated struct RemoteKageSidebarExpansion: Equatable, RawRepresentable, Sendable {
  private var collapsed: Set<String> = []

  init() {}

  init?(rawValue: String) {
    guard let data = rawValue.data(using: .utf8),
      let keys = try? JSONDecoder().decode([String].self, from: data)
    else { return nil }
    collapsed = Set(keys)
  }

  var rawValue: String {
    let data = (try? JSONEncoder().encode(collapsed.sorted())) ?? Data("[]".utf8)
    return String(bytes: data, encoding: .utf8) ?? "[]"
  }

  func isHostExpanded(_ hostID: RemoteKageHost.ID) -> Bool {
    !collapsed.contains(Self.key(host: hostID))
  }

  func isGroupExpanded(host hostID: RemoteKageHost.ID, group: RemoteKageSidebarModel.Group.GroupID) -> Bool {
    !collapsed.contains(Self.key(host: hostID, group: group))
  }

  mutating func setHost(_ hostID: RemoteKageHost.ID, expanded: Bool) {
    set(Self.key(host: hostID), expanded: expanded)
  }

  mutating func setGroup(
    host hostID: RemoteKageHost.ID,
    group: RemoteKageSidebarModel.Group.GroupID,
    expanded: Bool
  ) {
    set(Self.key(host: hostID, group: group), expanded: expanded)
  }

  /// Opens the host and the workspace the target names, leaving everything
  /// else as the user left it.
  func revealing(_ target: RemoteKageSidebarModel.RevealTarget) -> Self {
    var next = self
    next.setHost(target.hostID, expanded: true)
    if let groupID = target.groupID {
      next.setGroup(host: target.hostID, group: groupID, expanded: true)
    }
    return next
  }

  private mutating func set(_ key: String, expanded: Bool) {
    if expanded {
      collapsed.remove(key)
    } else {
      collapsed.insert(key)
    }
  }

  private static func key(host hostID: RemoteKageHost.ID) -> String {
    hostID.uuidString
  }

  private static func key(host hostID: RemoteKageHost.ID, group: RemoteKageSidebarModel.Group.GroupID) -> String {
    switch group {
    case .workspace(let id): "\(hostID.uuidString)/workspace/\(id)"
    case .ungrouped: "\(hostID.uuidString)/ungrouped"
    }
  }
}

nonisolated extension SharedReaderKey where Self == AppStorageKey<RemoteKageSidebarExpansion>.Default {
  static var remoteKageSidebarExpansion: Self {
    Self[.appStorage("remoteKageSidebarExpansion"), default: RemoteKageSidebarExpansion()]
  }
}
