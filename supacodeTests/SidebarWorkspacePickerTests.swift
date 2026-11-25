import Testing

@testable import supacode

@MainActor
struct SidebarWorkspacePickerTests {
  // MARK: - Placement.

  @Test func withoutRemoteHostsThePickerStaysPinnedAboveTheList() {
    #expect(SidebarWorkspacePicker.placement(hostCount: 0) == .pinnedAboveList)
  }

  @Test func withARemoteHostThePickerMovesIntoTheThisMacBand() {
    #expect(SidebarWorkspacePicker.placement(hostCount: 1) == .thisMacBand)
    #expect(SidebarWorkspacePicker.placement(hostCount: 4) == .thisMacBand)
  }

  @Test func placementFollowsWhetherTheGroupHeadersExist() {
    for count in 0...3 {
      let inBand = SidebarWorkspacePicker.placement(hostCount: count) == .thisMacBand
      #expect(inBand == SidebarMachineGroups.showsGroupHeaders(hostCount: count))
    }
  }

  // MARK: - Title.

  @Test func noActiveWorkspaceReadsAllProjects() {
    #expect(SidebarWorkspacePicker.title(activeWorkspaceName: nil) == "All Projects")
  }

  @Test func anActiveWorkspaceReadsItsName() {
    #expect(SidebarWorkspacePicker.title(activeWorkspaceName: "Client work") == "Client work")
  }

  @Test func aBlankWorkspaceNameFallsBackToAllProjects() {
    #expect(SidebarWorkspacePicker.title(activeWorkspaceName: "  ") == "All Projects")
  }

  // MARK: - Band title budget.

  @Test func aTitleWithinTheBandBudgetIsShownWhole() {
    #expect(SidebarWorkspacePicker.bandTitle("All Projects") == "All Projects")
    #expect(SidebarWorkspacePicker.bandTitle("Exactly13char") == "Exactly13char")
  }

  @Test func aLongerTitleIsCutToTheBudgetWithAnEllipsis() {
    let shown = SidebarWorkspacePicker.bandTitle("Quarterly client delivery work")
    #expect(shown == "Quarterly cl…")
    #expect(shown.count == SidebarWorkspacePicker.bandTitleLimit)
  }

  // MARK: - Collapsed band.

  @Test func theCollapsedBandShowsOnlyTheBareProjectCountBesideTheWorkspaceName() {
    // The workspace name is the band's menu and stays visible; the word
    // "projects" is dropped so the name keeps its room in a narrow sidebar.
    #expect(SidebarMachineGroup.thisMac.compactSummary(count: 28) == "28")
    #expect(SidebarMachineGroup.thisMac.compactSummary(count: 0) == "0")
  }

  @Test func theCompactSummaryOfRemoteHostsMatchesTheFullOne() {
    #expect(SidebarMachineGroup.remoteHosts.compactSummary(count: 2) == "2 hosts")
  }
}
