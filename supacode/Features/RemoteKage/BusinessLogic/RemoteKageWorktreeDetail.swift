import Foundation

/// The keys the remote detail can type into an awaiting-input session without
/// attaching (`RemoteKageFeature.Action.quickAnswer`).
enum RemoteKageQuickAnswer: CaseIterable, Identifiable {
  case one
  case two
  case three
  case escape
  case enter

  var id: Self { self }

  var title: String {
    switch self {
    case .one: "1"
    case .two: "2"
    case .three: "3"
    case .escape: "Esc"
    case .enter: "Enter"
    }
  }

  /// Sent verbatim to the session.
  var text: String {
    switch self {
    case .one: "1"
    case .two: "2"
    case .three: "3"
    case .escape: "\u{1B}"
    case .enter: "\r"
    }
  }

  var help: String {
    switch self {
    case .one, .two, .three: "Choose option \(title) in the remote prompt"
    case .escape: "Send Escape to the remote prompt (cancel)"
    case .enter: "Send Enter to the remote prompt (confirm the highlighted choice)"
    }
  }
}

/// Whether a remote tab can be attached as a live terminal, and with what.
enum RemoteKageAttachAvailability: Equatable {
  case available(zmxPath: String, session: String)
  /// The tooltip explaining why Attach is disabled.
  case unavailable(String)

  static func resolve(zmxPath: String?, tab: HostSnapshot.Tab) -> Self {
    guard let zmxPath else {
      return .unavailable("The host's Kage doesn't run its sessions under zmx, so they can't be attached.")
    }
    guard let session = tab.zmxSession else {
      return .unavailable("This tab doesn't run under zmx on the host, so it can't be attached.")
    }
    return .available(zmxPath: zmxPath, session: session)
  }
}

/// Pure decisions behind `RemoteKageWorktreeView`.
enum RemoteKageWorktreeDetail {
  /// Why the detail can't show the remote worktree right now.
  enum Unavailable: Equatable {
    case hostRemoved
    case connecting
    case offline(String)
    case kageNotRunning
    case needsUpdate
    case worktreeMissing

    var title: String {
      switch self {
      case .hostRemoved: "Host Removed"
      case .connecting: "Connecting…"
      case .offline: "Host Offline"
      case .kageNotRunning: "Kage Isn't Running"
      case .needsUpdate: "Host Needs an Update"
      case .worktreeMissing: "Worktree Not Found"
      }
    }

    var message: String {
      switch self {
      case .hostRemoved: "This host is no longer in Settings → Remote Hosts."
      case .connecting: "Waiting for the host's first answer."
      case .offline(let reason): "Can't reach the host: \(reason)"
      case .kageNotRunning: "Open Kage on that Mac to see its sessions here."
      case .needsUpdate: "The host's Kage is too old to report its sessions. Update Kage on that Mac."
      case .worktreeMissing: "The host no longer reports this worktree. It may have been archived or removed."
      }
    }

    var systemImage: String {
      switch self {
      case .hostRemoved: "desktopcomputer.trianglebadge.exclamationmark"
      case .connecting: "network"
      case .offline: "bolt.horizontal.circle"
      case .kageNotRunning: "pause.circle"
      case .needsUpdate: "arrow.down.circle"
      case .worktreeMissing: "questionmark.folder"
      }
    }
  }

  /// One remote tab that keeps a live terminal mounted.
  struct MountedTerminal: Equatable, Identifiable {
    let key: RemoteKageTabKey
    let zmxPath: String
    let session: String

    var id: RemoteKageTabKey { key }
  }

  static func unavailable(
    host: RemoteKageHost?,
    hostState: RemoteKageFeature.HostState?,
    worktree: HostSnapshot.Worktree?
  ) -> Unavailable? {
    guard host != nil else { return .hostRemoved }
    guard let hostState else { return .connecting }
    switch hostState.status {
    case .offline(let reason): return .offline(reason)
    case .kageNotRunning: return .kageNotRunning
    case .needsUpdate: return .needsUpdate
    case .connecting where hostState.lastSnapshot == nil: return .connecting
    case .connecting, .online: return worktree == nil ? .worktreeMissing : nil
    }
  }

  /// The tab the detail shows: the one the user picked while it still exists,
  /// else the host's focused tab, else the first.
  static func selectedTabID(in tabs: [HostSnapshot.Tab], stored: String?) -> String? {
    if let stored, tabs.contains(where: { $0.id == stored }) { return stored }
    return (tabs.first(where: \.isFocused) ?? tabs.first)?.id
  }

  /// The directory a file explorer for this worktree roots at: the selected
  /// tab's working directory, else the worktree path.
  static func explorerRoot(tabs: [HostSnapshot.Tab], selectedTabID: String?, worktreePath: String) -> String {
    guard let selectedTabID,
      let directory = tabs.first(where: { $0.id == selectedTabID })?.workingDirectory,
      !directory.isEmpty
    else { return worktreePath }
    return directory
  }

  /// Every attached tab of this worktree that can stay mounted, in strip
  /// order. All of them stay mounted (hidden when not shown) so switching
  /// tabs never drops an SSH session; unmounting one detaches it.
  static func mountedTerminals(
    hostID: RemoteKageHost.ID,
    tabs: [HostSnapshot.Tab],
    attachedTabs: Set<RemoteKageTabKey>,
    zmxPath: String?
  ) -> [MountedTerminal] {
    guard let zmxPath else { return [] }
    return tabs.compactMap { tab in
      let key = RemoteKageTabKey(hostID: hostID, tabID: tab.id)
      guard attachedTabs.contains(key), let session = tab.zmxSession else { return nil }
      return MountedTerminal(key: key, zmxPath: zmxPath, session: session)
    }
  }

  /// "Host · repository · worktree", or just the host name when the snapshot
  /// doesn't (or no longer) carry the worktree.
  static func title(hostName: String, snapshot: HostSnapshot?, worktreeID: String) -> String {
    guard let snapshot,
      let repository = snapshot.repositories.first(where: { $0.worktrees.contains { $0.id == worktreeID } }),
      let worktree = repository.worktrees.first(where: { $0.id == worktreeID })
    else { return hostName }
    return "\(hostName) · \(repository.name) · \(worktree.name)"
  }
}
