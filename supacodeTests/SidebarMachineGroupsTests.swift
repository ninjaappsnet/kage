import Foundation
import Testing

@testable import supacode

@MainActor
struct SidebarMachineGroupsTests {
  private let selection = RemoteKageSelection(
    hostID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
    worktreeID: "/r/a"
  )

  // MARK: - Local sections.

  @Test func withoutRemoteHostsLocalSectionsAlwaysShowEvenWhenThisMacIsCollapsed() {
    let sections = SidebarMachineGroups.visibleLocalSections(
      [1, 2, 3],
      hasRemoteHosts: false,
      isThisMacExpanded: false
    )

    #expect(sections == [1, 2, 3])
  }

  @Test func withRemoteHostsAnExpandedThisMacShowsEverySection() {
    let sections = SidebarMachineGroups.visibleLocalSections(
      [1, 2, 3],
      hasRemoteHosts: true,
      isThisMacExpanded: true
    )

    #expect(sections == [1, 2, 3])
  }

  @Test func withRemoteHostsACollapsedThisMacHidesEverySection() {
    let sections = SidebarMachineGroups.visibleLocalSections(
      [1, 2, 3],
      hasRemoteHosts: true,
      isThisMacExpanded: false
    )

    #expect(sections.isEmpty)
  }

  // MARK: - Group headers and remote content.

  @Test func groupHeadersShowOnlyWhenAHostIsConfigured() {
    #expect(!SidebarMachineGroups.showsGroupHeaders(hostCount: 0))
    #expect(SidebarMachineGroups.showsGroupHeaders(hostCount: 1))
    #expect(SidebarMachineGroups.showsGroupHeaders(hostCount: 3))
  }

  // MARK: - Which group a selection lives in.

  @Test func localSelectionsBelongToThisMac() {
    #expect(SidebarMachineGroup.containing(.worktree("/w")) == .thisMac)
    #expect(SidebarMachineGroup.containing(.archivedWorktrees) == .thisMac)
    #expect(SidebarMachineGroup.containing(.failedRepository("/r")) == .thisMac)
  }

  @Test func remoteSelectionBelongsToRemoteHosts() {
    #expect(SidebarMachineGroup.containing(.remoteKage(selection)) == .remoteHosts)
  }

  @Test func noSelectionBelongsToNoGroup() {
    #expect(SidebarMachineGroup.containing(nil) == nil)
  }

  @Test func groupsCarryAStableTitleAndIcon() {
    #expect(SidebarMachineGroup.thisMac.title == "This Mac")
    #expect(SidebarMachineGroup.remoteHosts.title == "Remote Hosts")
    #expect(SidebarMachineGroup.thisMac.systemImage != SidebarMachineGroup.remoteHosts.systemImage)
  }

  // MARK: - Collapsed summary.

  @Test func thisMacSummaryCountsProjects() {
    #expect(SidebarMachineGroup.thisMac.summary(count: 0) == "No projects")
    #expect(SidebarMachineGroup.thisMac.summary(count: 1) == "1 project")
    #expect(SidebarMachineGroup.thisMac.summary(count: 4) == "4 projects")
  }

  @Test func remoteHostsSummaryCountsHosts() {
    #expect(SidebarMachineGroup.remoteHosts.summary(count: 1) == "1 host")
    #expect(SidebarMachineGroup.remoteHosts.summary(count: 2) == "2 hosts")
  }
}
