import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

// MARK: - Validation.

struct RemoteKageHostValidationTests {
  private let existing = [
    RemoteKageHost(name: "Mini 1", username: "ahmet", address: "mini.example.com")
  ]

  @Test func nameIsRequiredAfterTrimming() {
    #expect(RemoteKageHost.validateName("   ", among: []) == .required)
    #expect(RemoteKageHost.validateName(" Mini ", among: []) == nil)
  }

  @Test func nameMustBeUniqueCaseInsensitively() {
    #expect(RemoteKageHost.validateName("mini 1", among: existing) == .duplicate)
    #expect(RemoteKageHost.validateName(" MINI 1 ", among: existing) == .duplicate)
    #expect(RemoteKageHost.validateName("Mini 2", among: existing) == nil)
  }

  @Test func usernameAcceptsOnlySafeCharacters() {
    #expect(RemoteKageHost.validateUsername("") == .required)
    #expect(RemoteKageHost.validateUsername("  ") == .required)
    #expect(RemoteKageHost.validateUsername("ahmet.cetin_1-x") == nil)
    #expect(RemoteKageHost.validateUsername(" ahmet ") == nil)
    #expect(RemoteKageHost.validateUsername("-oProxyCommand=x") == .leadingHyphen)
    #expect(RemoteKageHost.validateUsername("a b") == .invalid)
    #expect(RemoteKageHost.validateUsername("a@b") == .invalid)
    #expect(RemoteKageHost.validateUsername("a;b") == .invalid)
    #expect(RemoteKageHost.validateUsername("ä") == .invalid)
  }

  @Test func addressAcceptsDNSNames() {
    for good in ["mini", "mini.local", "ahmets-mac-mini.tail96d5dd.ts.net", "a1.b-2.example.com"] {
      #expect(RemoteKageHost.validateAddress(good) == nil, "\(good)")
    }
    #expect(RemoteKageHost.validateAddress("") == .required)
    #expect(RemoteKageHost.validateAddress("-oProxyCommand=x") == .leadingHyphen)
    for bad in ["-a.b", "a-.b", "a.-b", "a..b", "a.b.", ".a", "a_b.com", "a b", "a;b", "a$b", "a/b", "a`b", "a|b"] {
      #expect(RemoteKageHost.validateAddress(bad) != nil, "\(bad)")
    }
  }

  @Test func addressRejectsOverlongNamesAndLabels() {
    let label63 = String(repeating: "a", count: 63)
    #expect(RemoteKageHost.validateAddress(label63) == nil)
    #expect(RemoteKageHost.validateAddress(label63 + "a") == .invalid)
    let long = Array(repeating: label63, count: 4).joined(separator: ".")  // 255 chars
    #expect(RemoteKageHost.validateAddress(long) == .invalid)
  }

  @Test func addressAcceptsIPv4() {
    #expect(RemoteKageHost.validateAddress("192.168.1.20") == nil)
    #expect(RemoteKageHost.validateAddress("0.0.0.0") == nil)
    #expect(RemoteKageHost.validateAddress("256.1.1.1") == .invalid)
    #expect(RemoteKageHost.validateAddress("1.2.3") == .invalid)
    #expect(RemoteKageHost.validateAddress("1.2.3.4.5") == .invalid)
  }

  @Test func addressAcceptsIPv6() {
    for good in ["::1", "fe80::1", "2001:db8::8a2e:370:7334", "1:2:3:4:5:6:7:8", "[::1]", "[fe80::1]", "::"] {
      #expect(RemoteKageHost.validateAddress(good) == nil, "\(good)")
    }
    for bad in [":::", "1::2::3", "12345::1", "g::1", "1:2:3:4:5:6:7:8:9", "1:2:3", "[::1", "::1]", "[]", ":1", "1:"] {
      #expect(RemoteKageHost.validateAddress(bad) != nil, "\(bad)")
    }
  }

  @Test func normalizedAddressTrimsAndStripsBrackets() {
    #expect(RemoteKageHost.normalizedAddress("  mini.local \n") == "mini.local")
    #expect(RemoteKageHost.normalizedAddress("[::1]") == "::1")
    #expect(RemoteKageHost.normalizedAddress(" [fe80::1] ") == "fe80::1")
  }
}

// MARK: - Reducer.

@MainActor
struct RemoteKageSettingsFeatureTests {
  private let mini = RemoteKageHost(
    id: UUID(1), name: "Mini 1", username: "ahmet", address: "mini.example.com")

  private func state(hosts: [RemoteKageHost] = []) -> RemoteKageSettingsFeature.State {
    let state = RemoteKageSettingsFeature.State()
    state.$file.withLock { $0 = RemoteKageHostsFile(hosts: hosts) }
    return state
  }

  @Test(.dependencies) func addingPrefillsTheUsernameWithThisMacsUser() async {
    let store = TestStore(initialState: state()) {
      RemoteKageSettingsFeature()
    } withDependencies: {
      $0.remoteKageCurrentUser.name = { "tester" }
    }
    await store.send(.addButtonTapped) {
      $0.draft = .init(id: nil, name: "", username: "tester", address: "")
      $0.isEditorPresented = true
    }
    #expect(!store.state.canSave)
  }

  @Test(.dependencies) func savingANewHostAppendsItTrimmedAndNormalized() async {
    let store = TestStore(initialState: state()) {
      RemoteKageSettingsFeature()
    } withDependencies: {
      $0.remoteKageCurrentUser.name = { "tester" }
      $0.uuid = .constant(UUID(5))
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.addButtonTapped)
    await store.send(.binding(.set(\.draft.name, "  Mini 2 ")))
    await store.send(.binding(.set(\.draft.address, " [::1] ")))
    #expect(store.state.canSave)
    await store.send(.saveEditorTapped)
    #expect(
      store.state.file.hosts == [RemoteKageHost(id: UUID(5), name: "Mini 2", username: "tester", address: "::1")])
    #expect(!store.state.isEditorPresented)
  }

  @Test(.dependencies) func invalidDraftCannotBeSaved() async {
    let store = TestStore(initialState: state(hosts: [mini])) { RemoteKageSettingsFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.addButtonTapped)
    await store.send(.binding(.set(\.draft.name, "mini 1")))
    await store.send(.binding(.set(\.draft.username, "-oFoo")))
    await store.send(.binding(.set(\.draft.address, "a b")))
    #expect(store.state.nameIssue == .duplicate)
    #expect(store.state.usernameIssue == .leadingHyphen)
    #expect(store.state.addressIssue == .invalid)
    #expect(!store.state.canSave)
    await store.send(.saveEditorTapped)
    #expect(store.state.file.hosts == [mini])
    #expect(store.state.isEditorPresented)
  }

  @Test(.dependencies) func editingKeepsTheIdAndMayKeepItsOwnName() async {
    let store = TestStore(initialState: state(hosts: [mini])) { RemoteKageSettingsFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.editButtonTapped(mini.id))
    #expect(store.state.draft == .init(id: mini.id, name: "Mini 1", username: "ahmet", address: "mini.example.com"))
    #expect(store.state.canSave)
    await store.send(.binding(.set(\.draft.address, "10.0.0.2")))
    await store.send(.saveEditorTapped)
    #expect(
      store.state.file.hosts == [RemoteKageHost(id: mini.id, name: "Mini 1", username: "ahmet", address: "10.0.0.2")])
    #expect(!store.state.isEditorPresented)
  }

  @Test(.dependencies) func cancellingLeavesHostsUntouched() async {
    let store = TestStore(initialState: state(hosts: [mini])) { RemoteKageSettingsFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.editButtonTapped(mini.id))
    await store.send(.binding(.set(\.draft.name, "Changed")))
    await store.send(.cancelEditorTapped)
    #expect(!store.state.isEditorPresented)
    #expect(store.state.file.hosts == [mini])
  }

  @Test(.dependencies) func removingAsksForConfirmation() async {
    let store = TestStore(initialState: state(hosts: [mini])) { RemoteKageSettingsFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.removeButtonTapped(mini.id))
    #expect(store.state.alert != nil)
    #expect(store.state.file.hosts == [mini])
    await store.send(.alert(.presented(.confirmRemove(mini.id))))
    #expect(store.state.file.hosts.isEmpty)
  }

  @Test(.dependencies) func removingAnUnknownHostDoesNothing() async {
    let store = TestStore(initialState: state(hosts: [mini])) { RemoteKageSettingsFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.removeButtonTapped(UUID(9)))
    #expect(store.state.alert == nil)
  }
}
