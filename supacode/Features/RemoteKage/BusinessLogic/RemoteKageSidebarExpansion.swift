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

  /// The repository's collapsed branch groups (`RemoteKageBranchNesting`).
  func collapsedBranchGroups(host hostID: RemoteKageHost.ID, repository: String) -> Set<
    RemoteKageBranchNesting.GroupKey
  > {
    let start = Self.branchKeyStart(host: hostID, repository: repository)
    return Set(
      collapsed.compactMap { key -> RemoteKageBranchNesting.GroupKey? in
        guard key.hasPrefix(start) else { return nil }
        let rest = key.dropFirst(start.count)
        guard let slash = rest.firstIndex(of: "/"),
          let bucket = RemoteKageBranchNesting.Bucket(rawValue: String(rest[..<slash]))
        else { return nil }
        return RemoteKageBranchNesting.GroupKey(bucket: bucket, prefix: String(rest[rest.index(after: slash)...]))
      }
    )
  }

  mutating func setBranchGroup(
    host hostID: RemoteKageHost.ID,
    repository: String,
    _ key: RemoteKageBranchNesting.GroupKey,
    expanded: Bool
  ) {
    set(
      Self.branchKeyStart(host: hostID, repository: repository) + "\(key.bucket.rawValue)/\(key.prefix)",
      expanded: expanded)
  }

  /// The repository id is percent-encoded so its slashes can't run into the prefix's.
  private static func branchKeyStart(host hostID: RemoteKageHost.ID, repository: String) -> String {
    let encoded = repository.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? repository
    return "\(hostID.uuidString)/branch/\(encoded)/"
  }

  /// Opens the host and the workspace the target names, leaving everything
  /// else as the user left it.
  func revealing(_ target: RemoteKageSidebarModel.RevealTarget) -> Self {
    var next = self
    next.setHost(target.hostID, expanded: true)
    if let groupID = target.groupID {
      next.setGroup(host: target.hostID, group: groupID, expanded: true)
    }
    if let repositoryID = target.repositoryID, let branch = target.branch {
      // Every group prefix above the branch, as `SidebarBranchNesting.ancestorPrefixes`.
      let parts = branch.split(separator: "/", omittingEmptySubsequences: true)
      for end in parts.indices.dropFirst() {
        let prefix = parts[..<end].joined(separator: "/")
        for bucket in [RemoteKageBranchNesting.Bucket.pinned, .unpinned] {
          next.setBranchGroup(
            host: target.hostID, repository: repositoryID, .init(bucket: bucket, prefix: prefix), expanded: true)
        }
      }
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
