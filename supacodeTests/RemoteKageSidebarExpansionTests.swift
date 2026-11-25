import Foundation
import Testing

@testable import supacode

@MainActor
struct RemoteKageSidebarExpansionTests {
  private let hostA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
  private let hostB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

  @Test func everythingIsExpandedByDefault() {
    let expansion = RemoteKageSidebarExpansion()

    #expect(expansion.isHostExpanded(hostA))
    #expect(expansion.isGroupExpanded(host: hostA, group: .workspace("w1")))
    #expect(expansion.isGroupExpanded(host: hostA, group: .ungrouped))
  }

  @Test func collapsingAHostLeavesOtherHostsAndItsOwnGroupsAlone() {
    var expansion = RemoteKageSidebarExpansion()

    expansion.setHost(hostA, expanded: false)

    #expect(!expansion.isHostExpanded(hostA))
    #expect(expansion.isHostExpanded(hostB))
    #expect(expansion.isGroupExpanded(host: hostA, group: .workspace("w1")))
  }

  @Test func groupsAreKeyedPerHostAndWorkspace() {
    var expansion = RemoteKageSidebarExpansion()

    expansion.setGroup(host: hostA, group: .workspace("w1"), expanded: false)
    expansion.setGroup(host: hostB, group: .ungrouped, expanded: false)

    #expect(!expansion.isGroupExpanded(host: hostA, group: .workspace("w1")))
    #expect(expansion.isGroupExpanded(host: hostA, group: .workspace("w2")))
    #expect(expansion.isGroupExpanded(host: hostA, group: .ungrouped))
    #expect(expansion.isGroupExpanded(host: hostB, group: .workspace("w1")))
    #expect(!expansion.isGroupExpanded(host: hostB, group: .ungrouped))
    #expect(expansion.isHostExpanded(hostA))
  }

  @Test func aWorkspaceNamedLikeUngroupedIsNotConfusedWithIt() {
    var expansion = RemoteKageSidebarExpansion()

    expansion.setGroup(host: hostA, group: .workspace("ungrouped"), expanded: false)

    #expect(expansion.isGroupExpanded(host: hostA, group: .ungrouped))
  }

  @Test func expandingAgainForgetsTheCollapse() {
    var expansion = RemoteKageSidebarExpansion()
    expansion.setHost(hostA, expanded: false)
    expansion.setGroup(host: hostA, group: .workspace("w1"), expanded: false)

    expansion.setHost(hostA, expanded: true)
    expansion.setGroup(host: hostA, group: .workspace("w1"), expanded: true)

    #expect(expansion == RemoteKageSidebarExpansion())
  }

  @Test func revealingOpensTheHostAndTheWorkspaceButNothingElse() {
    var expansion = RemoteKageSidebarExpansion()
    expansion.setHost(hostA, expanded: false)
    expansion.setGroup(host: hostA, group: .workspace("w1"), expanded: false)
    expansion.setGroup(host: hostA, group: .workspace("w2"), expanded: false)
    expansion.setHost(hostB, expanded: false)

    let revealed = expansion.revealing(.init(hostID: hostA, groupID: .workspace("w1")))

    #expect(revealed.isHostExpanded(hostA))
    #expect(revealed.isGroupExpanded(host: hostA, group: .workspace("w1")))
    #expect(!revealed.isGroupExpanded(host: hostA, group: .workspace("w2")))
    #expect(!revealed.isHostExpanded(hostB))
  }

  @Test func revealingAHostWithoutKnownGroupOnlyOpensTheHost() {
    var expansion = RemoteKageSidebarExpansion()
    expansion.setHost(hostA, expanded: false)
    expansion.setGroup(host: hostA, group: .ungrouped, expanded: false)

    let revealed = expansion.revealing(.init(hostID: hostA, groupID: nil))

    #expect(revealed.isHostExpanded(hostA))
    #expect(!revealed.isGroupExpanded(host: hostA, group: .ungrouped))
  }

  @Test func revealingSomethingAlreadyVisibleChangesNothing() {
    var expansion = RemoteKageSidebarExpansion()
    expansion.setGroup(host: hostB, group: .workspace("w9"), expanded: false)

    let revealed = expansion.revealing(.init(hostID: hostA, groupID: .workspace("w1")))

    #expect(revealed == expansion)
  }

  @Test func roundTripsThroughItsPersistedRawValue() throws {
    var expansion = RemoteKageSidebarExpansion()
    expansion.setHost(hostA, expanded: false)
    expansion.setGroup(host: hostB, group: .workspace("w1"), expanded: false)
    expansion.setGroup(host: hostB, group: .ungrouped, expanded: false)

    let restored = try #require(RemoteKageSidebarExpansion(rawValue: expansion.rawValue))

    #expect(restored == expansion)
  }

  @Test func rawValueIsStableRegardlessOfInsertionOrder() {
    var first = RemoteKageSidebarExpansion()
    first.setHost(hostA, expanded: false)
    first.setHost(hostB, expanded: false)
    var second = RemoteKageSidebarExpansion()
    second.setHost(hostB, expanded: false)
    second.setHost(hostA, expanded: false)

    #expect(first.rawValue == second.rawValue)
  }

  @Test func garbageRawValueIsRejectedSoStorageFallsBackToDefault() {
    #expect(RemoteKageSidebarExpansion(rawValue: "not json") == nil)
    #expect(RemoteKageSidebarExpansion(rawValue: "") == nil)
  }
}
