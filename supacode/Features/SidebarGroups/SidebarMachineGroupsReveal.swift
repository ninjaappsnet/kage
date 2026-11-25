import ComposableArchitecture
import Sharing
import SwiftUI

/// Opens whatever machine group, host and workspace holds a row the sidebar
/// is asked to show: any selection change (hotkey, notification click,
/// palette, remote click-through) and every reveal request. Lives on the
/// sidebar `List` as one appended modifier so `SidebarListView` stays free
/// of the accordion bookkeeping. Does nothing without remote hosts, when
/// there are no groups to open.
struct SidebarMachineGroupsReveal: ViewModifier {
  let selection: SidebarSelection?
  let pendingRevealID: Int?
  @Environment(\.remoteKageStore) private var remoteKageStore
  @Shared(.sidebarThisMacExpanded) private var isThisMacExpanded: Bool
  @Shared(.sidebarRemoteHostsExpanded) private var isRemoteHostsExpanded: Bool
  @Shared(.remoteKageSidebarExpansion) private var expansion: RemoteKageSidebarExpansion

  func body(content: Content) -> some View {
    content
      .onChange(of: selection) { _, newSelection in
        reveal(newSelection)
      }
      .onChange(of: pendingRevealID) { _, newID in
        guard newID != nil else { return }
        revealThisMac()
      }
  }

  private var hasGroups: Bool {
    remoteKageStore.map { SidebarMachineGroups.showsGroupHeaders(hostCount: $0.hosts.count) } ?? false
  }

  private func revealThisMac() {
    guard hasGroups, !isThisMacExpanded else { return }
    $isThisMacExpanded.withLock { $0 = true }
  }

  private func reveal(_ selection: SidebarSelection?) {
    guard hasGroups, let remoteKageStore else { return }
    switch SidebarMachineGroup.containing(selection) {
    case .thisMac:
      revealThisMac()
    case .remoteHosts:
      if !isRemoteHostsExpanded { $isRemoteHostsExpanded.withLock { $0 = true } }
      guard let selected = selection?.remoteKageSelection else { return }
      let model = RemoteKageSidebarModel.make(hosts: remoteKageStore.hosts, hostStates: remoteKageStore.hostStates)
      guard let target = model.revealTarget(for: selected) else { return }
      let revealed = expansion.revealing(target)
      if revealed != expansion { $expansion.withLock { $0 = revealed } }
    case nil:
      break
    }
  }
}
