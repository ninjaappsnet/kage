import ComposableArchitecture
import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import SupacodeSettingsShared
import Testing

@testable import supacode

// MARK: - MCP server merge.

struct ClaudeMCPServerSyncTests {
  private let server: JSONValue = ["type": "stdio", "command": "/usr/bin/true"]
  private let edited: JSONValue = ["type": "stdio", "command": "/usr/bin/false"]

  @Test func firstSyncUnitesEveryAccountWithMainWinningConflicts() {
    let plan = ClaudeMCPServerSync.plan(
      baseline: nil,
      accounts: [
        ("main", ["shared": server, "mainOnly": server]),
        ("work", ["shared": edited, "workOnly": edited]),
      ]
    )
    #expect(plan.merged == ["shared": server, "mainOnly": server, "workOnly": edited])
    #expect(plan.operations["main"] == [.init(serverName: "workOnly", kind: .upsert(edited))])
    #expect(
      plan.operations["work"] == [
        .init(serverName: "mainOnly", kind: .upsert(server)),
        .init(serverName: "shared", kind: .upsert(server)),
      ])
  }

  @Test func additionInAnyAccountPropagates() {
    let plan = ClaudeMCPServerSync.plan(
      baseline: [:],
      accounts: [("main", [:]), ("work", ["new": server])]
    )
    #expect(plan.merged == ["new": server])
    #expect(plan.operations["main"] == [.init(serverName: "new", kind: .upsert(server))])
    #expect(plan.operations["work"] == [])
  }

  @Test func removalInAnyAccountPropagates() {
    let plan = ClaudeMCPServerSync.plan(
      baseline: ["gone": server],
      accounts: [("main", ["gone": server]), ("work", [:])]
    )
    #expect(plan.merged.isEmpty)
    #expect(plan.operations["main"] == [.init(serverName: "gone", kind: .remove)])
    #expect(plan.operations["work"] == [])
  }

  @Test func editInSecondaryAccountPropagatesWhenMainIsUnchanged() {
    let plan = ClaudeMCPServerSync.plan(
      baseline: ["srv": server],
      accounts: [("main", ["srv": server]), ("work", ["srv": edited])]
    )
    #expect(plan.merged == ["srv": edited])
    #expect(plan.operations["main"] == [.init(serverName: "srv", kind: .upsert(edited))])
  }

  @Test func concurrentEditsResolveToMain() {
    let third: JSONValue = ["type": "http", "url": "https://example.invalid"]
    let plan = ClaudeMCPServerSync.plan(
      baseline: ["srv": server],
      accounts: [("main", ["srv": third]), ("work", ["srv": edited])]
    )
    #expect(plan.merged == ["srv": third])
    #expect(plan.operations["work"] == [.init(serverName: "srv", kind: .upsert(third))])
  }

  @Test func agreementIsANoOp() {
    let plan = ClaudeMCPServerSync.plan(
      baseline: ["srv": server],
      accounts: [("main", ["srv": server]), ("work", ["srv": server])]
    )
    #expect(plan.isNoOp)
  }

  @Test func readsUserServersAndToleratesAMissingFile() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: ".claude.json")
    #expect(try ClaudeMCPServerSync.readServers(globalStateURL: url).isEmpty)
    try Data(#"{"userID":"x","mcpServers":{"a":{"type":"http","url":"https://e.invalid"}}}"#.utf8).write(to: url)
    #expect(
      try ClaudeMCPServerSync.readServers(globalStateURL: url) == ["a": ["type": "http", "url": "https://e.invalid"]])
    try Data("not json".utf8).write(to: url)
    #expect(throws: (any Error).self) { try ClaudeMCPServerSync.readServers(globalStateURL: url) }
  }
}

// MARK: - Persisted choices.

struct ClaudeAccountsFileTests {
  private func file() -> ClaudeAccountsFile {
    var file = ClaudeAccountsFile()
    file.accounts = [
      ClaudeAccount(id: "work", name: "Work", configDirectoryPath: "/tmp/kage-claude/work"),
      ClaudeAccount(id: "home", name: "Home", configDirectoryPath: "/tmp/kage-claude/home"),
    ]
    return file
  }

  @Test func resolutionPrefersTabThenRepositoryThenDefault() {
    var file = file()
    let tab = UUID()
    #expect(file.resolvedAccount(tabID: tab, repositoryRootPath: "/repo").isMain)
    file.defaultAccountID = "home"
    #expect(file.resolvedAccount(tabID: tab, repositoryRootPath: "/repo").id == "home")
    file.repositoryAccountIDs["/repo"] = "work"
    #expect(file.resolvedAccount(tabID: tab, repositoryRootPath: "/repo").id == "work")
    file.tabAccountIDs[tab.uuidString] = ClaudeAccount.mainID
    #expect(file.resolvedAccount(tabID: tab, repositoryRootPath: "/repo").isMain)
  }

  @Test func removingAnAccountClearsEveryReference() {
    var file = file()
    file.defaultAccountID = "work"
    file.repositoryAccountIDs = ["/a": "work", "/b": "home"]
    file.tabAccountIDs = [UUID().uuidString: "work"]
    file.loggedInAccountIDs = ["work", "home"]
    file.removeAccount("work")
    #expect(file.accounts.map(\.id) == ["home"])
    #expect(file.defaultAccountID == ClaudeAccount.mainID)
    #expect(file.repositoryAccountIDs == ["/b": "home"])
    #expect(file.tabAccountIDs.isEmpty)
    #expect(file.loggedInAccountIDs == ["home"])
  }

  @Test func staleAssignmentFallsThrough() {
    var file = file()
    file.repositoryAccountIDs["/repo"] = "deleted"
    file.defaultAccountID = "home"
    #expect(file.resolvedAccount(tabID: nil, repositoryRootPath: "/repo").id == "home")
  }

  @Test func decodesAnOlderFileMissingNewerKeys() throws {
    let file = try JSONDecoder().decode(ClaudeAccountsFile.self, from: Data(#"{"accounts":[]}"#.utf8))
    #expect(file == ClaudeAccountsFile())
  }

  @Test func environmentSetsTheConfigDirectoryOnlyForNonMainLocalSessions() {
    var file = file()
    let root = URL(filePath: "/repo/")
    #expect(
      ClaudeAccountEnvironment.variables(tabID: nil, repositoryRootURL: root, isRemote: false, file: file).isEmpty)
    file.repositoryAccountIDs[ClaudeAccountEnvironment.normalizedPath("/repo/")] = "work"
    #expect(
      ClaudeAccountEnvironment.variables(tabID: nil, repositoryRootURL: root, isRemote: false, file: file)
        == ["CLAUDE_CONFIG_DIR": "/tmp/kage-claude/work"])
    #expect(ClaudeAccountEnvironment.variables(tabID: nil, repositoryRootURL: root, isRemote: true, file: file).isEmpty)
  }

  @Test func slugsAndUniqueDirectories() {
    #expect(ClaudeAccountsFeature.slug("Work Account!") == "work-account")
    #expect(ClaudeAccountsFeature.slug("  ") == "account")
    let root = URL(filePath: "/tmp/kage-claude-\(UUID().uuidString)")
    let first = ClaudeAccountsFeature.uniqueDirectory(for: "Work", existing: [], root: root)
    #expect(first.lastPathComponent == "work")
    let second = ClaudeAccountsFeature.uniqueDirectory(
      for: "Work", existing: [first.path(percentEncoded: false)], root: root)
    #expect(second.lastPathComponent == "work-2")
    // A stored path never carries the directory URL's trailing slash.
    #expect(ClaudeAccountEnvironment.normalizedPath("/a/b/") == "/a/b")
  }
}

// MARK: - Auth status.

struct ClaudeAuthStatusTests {
  @Test func decodesTheCLIOutput() throws {
    let status = try ClaudeAuthStatus.decode(
      """
      {"loggedIn": true, "authMethod": "claude.ai", "email": "a@example.com",
       "subscriptionType": "max", "loginExpiresAt": "2026-12-14T05:59:24.426Z", "planTier": "max_20x"}
      """)
    #expect(status.loggedIn)
    #expect(status.email == "a@example.com")
    let expected = ISO8601DateFormatter().date(from: "2026-12-14T05:59:24Z")!.addingTimeInterval(0.426)
    #expect(abs((status.loginExpiresAt ?? .distantPast).timeIntervalSince(expected)) < 0.001)
  }

  @Test func decodesALoggedOutDirectoryWithNullExpiry() throws {
    let status = try ClaudeAuthStatus.decode(#"{"loggedIn": false, "authMethod": "none", "loginExpiresAt": null}"#)
    #expect(status == ClaudeAuthStatus(loggedIn: false, authMethod: "none"))
  }

  @Test func healthTracksTheExpiry() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let day: TimeInterval = 24 * 60 * 60
    #expect(ClaudeAuthStatus(loggedIn: false).health(now: now) == .loggedOut)
    #expect(ClaudeAuthStatus(loggedIn: true).health(now: now) == .loggedIn)
    #expect(
      ClaudeAuthStatus(loggedIn: true, loginExpiresAt: now.addingTimeInterval(10 * day)).health(now: now) == .loggedIn)
    let soon = now.addingTimeInterval(2 * day)
    #expect(ClaudeAuthStatus(loggedIn: true, loginExpiresAt: soon).health(now: now) == .expiringSoon(soon))
    #expect(ClaudeAuthStatus(loggedIn: true, loginExpiresAt: now).health(now: now) == .expired)
  }
}

// MARK: - Directory layout.

struct ClaudeAccountLayoutTests {
  private struct Sandbox {
    let root = FileManager.default.temporaryDirectory.appending(path: "claude-layout-\(UUID().uuidString)")
    var hub: URL { root.appending(path: "hub") }
    var account: URL { root.appending(path: "account") }
    var layout: ClaudeAccountLayout {
      ClaudeAccountLayout(hubDirectory: hub, now: { Date(timeIntervalSince1970: 0) })
    }

    func write(_ text: String, to url: URL) throws {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) -> String? {
      (try? Data(contentsOf: url)).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
  }

  @Test func freshAccountLinksEverySharedEntry() throws {
    let box = Sandbox()
    defer { box.cleanUp() }
    let report = try box.layout.prepare(accountDirectory: box.account)
    #expect(report.linked.count == ClaudeAccountLayout.sharedEntries.count)
    #expect(box.layout.isPrepared(accountDirectory: box.account))
    // Directories exist in the hub so writing through the link works.
    try box.write("t", to: box.account.appending(path: "projects/p/session.jsonl"))
    #expect(box.read(box.hub.appending(path: "projects/p/session.jsonl")) == "t")
    // A file link may dangle until the first write creates the hub copy.
    try box.write("{}", to: box.account.appending(path: "settings.json"))
    #expect(box.read(box.hub.appending(path: "settings.json")) == "{}")
  }

  @Test func preparingTwiceChangesNothing() throws {
    let box = Sandbox()
    defer { box.cleanUp() }
    try box.layout.prepare(accountDirectory: box.account)
    #expect(try !box.layout.prepare(accountDirectory: box.account).changedAnything)
  }

  @Test func realFileIsAdoptedWhenTheHubHasNone() throws {
    let box = Sandbox()
    defer { box.cleanUp() }
    try box.write("history", to: box.account.appending(path: "history.jsonl"))
    let report = try box.layout.prepare(accountDirectory: box.account)
    #expect(report.movedAside.isEmpty)
    #expect(box.read(box.hub.appending(path: "history.jsonl")) == "history")
    #expect(box.read(box.account.appending(path: "history.jsonl")) == "history")
  }

  @Test func realFileIsMovedAsideWhenTheHubAlreadyHasOne() throws {
    let box = Sandbox()
    defer { box.cleanUp() }
    try box.write("hub", to: box.hub.appending(path: "settings.json"))
    try box.write("account", to: box.account.appending(path: "settings.json"))
    let report = try box.layout.prepare(accountDirectory: box.account)
    #expect(report.movedAside == ["settings.json"])
    #expect(box.read(box.account.appending(path: "settings.json")) == "hub")
    let aside = try FileManager.default.contentsOfDirectory(
      at: box.account.appending(path: ClaudeAccountLayout.unlinkedDirectoryName), includingPropertiesForKeys: nil)
    #expect(aside.count == 1)
    #expect(box.read(aside[0].appending(path: "settings.json")) == "account")
  }

  @Test func realDirectoryIsMergedChildByChild() throws {
    let box = Sandbox()
    defer { box.cleanUp() }
    try box.write("old", to: box.hub.appending(path: "projects/a/1.jsonl"))
    try box.write("new", to: box.account.appending(path: "projects/b/2.jsonl"))
    let report = try box.layout.prepare(accountDirectory: box.account)
    #expect(report.movedAside.isEmpty)
    #expect(box.read(box.hub.appending(path: "projects/a/1.jsonl")) == "old")
    #expect(box.read(box.hub.appending(path: "projects/b/2.jsonl")) == "new")
    #expect(ClaudeAccountLayout.symlinkDestination(of: box.account.appending(path: "projects")) != nil)
  }

  @Test func linkPointingElsewhereIsRepointed() throws {
    let box = Sandbox()
    defer { box.cleanUp() }
    try FileManager.default.createDirectory(at: box.account, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: box.account.appending(path: "skills"), withDestinationURL: box.root.appending(path: "elsewhere"))
    try box.layout.prepare(accountDirectory: box.account)
    #expect(box.layout.isPrepared(accountDirectory: box.account))
  }
}

// MARK: - Reducer.

@MainActor
struct ClaudeAccountsFeatureTests {
  private let work = ClaudeAccount(id: "work", name: "Work", configDirectoryPath: "/tmp/kage-claude/work")

  private func state(_ configure: (inout ClaudeAccountsFile) -> Void = { _ in }) -> ClaudeAccountsFeature.State {
    let state = ClaudeAccountsFeature.State()
    state.$file.withLock { file in
      file = ClaudeAccountsFile()
      configure(&file)
    }
    return state
  }

  @Test(.dependencies) func addingAnAccountPreparesItsFolderAndStartsLogin() async {
    let prepared = LockIsolated<[URL]>([])
    let store = TestStore(initialState: state()) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
      $0.uuid = .constant(UUID(0))
      $0[ClaudeAccountsClient.self].prepareDirectory = { url in
        prepared.withValue { $0.append(url) }
        return ClaudeAccountLayout.Report()
      }
      $0[ClaudeAccountsClient.self].startLogin = { _ in AsyncStream { $0.finish() } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.addAccountButtonTapped)
    await store.send(.binding(.set(\.newAccountName, "Work")))
    await store.send(.addAccountConfirmed)
    await store.receive(\.accountPrepared)
    await store.receive(\.loginButtonTapped)
    let account = store.state.file.accounts.first
    #expect(account?.name == "Work")
    #expect(
      account?.configDirectoryPath?.hasSuffix("/claude-accounts/work") == true,
      "\(account?.configDirectoryPath ?? "nil")")
    #expect(prepared.value.map(\.lastPathComponent) == ["work"])
    #expect(store.state.login?.accountID == UUID(0).uuidString)
    #expect(!store.state.isAddAccountPresented)
  }

  @Test(.dependencies) func duplicateNamesAreRejected() async {
    let store = TestStore(initialState: state { $0.accounts = [work] }) { ClaudeAccountsFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.binding(.set(\.newAccountName, "work")))
    #expect(!store.state.isNewAccountNameValid)
    await store.send(.binding(.set(\.newAccountName, "Main")))
    #expect(!store.state.isNewAccountNameValid)
  }

  @Test(.dependencies) func newTabWithAccountAssignsTheTabBeforeCreatingIt() async {
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let worktree = Worktree(
      location: .local(
        workingDirectory: URL(filePath: "/tmp/repo/feature"), repositoryRoot: URL(filePath: "/tmp/repo")),
      kind: .git, name: "feature", detail: "", isAttached: false)
    let store = TestStore(initialState: state { $0.accounts = [work] }) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.uuid = .constant(UUID(7))
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.newTabRequested("work", worktree))
    await store.finish()
    #expect(store.state.file.tabAccountIDs == [UUID(7).uuidString: "work"])
    #expect(sent.value == [.createTab(worktree, runSetupScriptIfNew: false, id: UUID(7))])
  }

  @Test(.dependencies) func repositoryOverrideIsStoredNormalized() async {
    let store = TestStore(initialState: state { $0.accounts = [work] }) { ClaudeAccountsFeature() }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.setRepositoryAccount(repositoryRootPath: "/tmp/repo/", "work"))
    #expect(store.state.file.repositoryAccountIDs == ["/tmp/repo": "work"])
    await store.send(.setRepositoryAccount(repositoryRootPath: "/tmp/repo", nil))
    #expect(store.state.file.repositoryAccountIDs.isEmpty)
  }

  @Test(.dependencies) func expiredLoginRemindsOnceADay() async {
    let notifications = LockIsolated<[String]>([])
    let now = LockIsolated(Date(timeIntervalSince1970: 1_000_000))
    let store = TestStore(initialState: state { $0.accounts = [work] }) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.date = DateGenerator { now.value }
      $0[SystemNotificationClient.self].send = { _, body, _ in notifications.withValue { $0.append(body) } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Logged in once, so a later logout is worth a reminder.
    await store.send(.statusLoaded("work", .success(ClaudeAuthStatus(loggedIn: true))))
    #expect(store.state.file.loggedInAccountIDs.contains("work"))
    await store.send(.statusLoaded("work", .success(ClaudeAuthStatus(loggedIn: false))))
    await store.send(.statusLoaded("work", .success(ClaudeAuthStatus(loggedIn: false))))
    await store.finish()
    #expect(notifications.value.count == 1)
    #expect(notifications.value.first?.contains("Work") == true)

    now.withValue { $0.addTimeInterval(ClaudeAccountsFeature.reminderInterval + 1) }
    await store.send(.statusLoaded("work", .success(ClaudeAuthStatus(loggedIn: false))))
    await store.finish()
    #expect(notifications.value.count == 2)
  }

  @Test(.dependencies) func neverLoggedInAccountStaysQuiet() async {
    let notifications = LockIsolated(0)
    let store = TestStore(initialState: state { $0.accounts = [work] }) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
      $0[SystemNotificationClient.self].send = { _, _, _ in notifications.withValue { $0 += 1 } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.statusLoaded("work", .success(ClaudeAuthStatus(loggedIn: false))))
    await store.finish()
    #expect(notifications.value == 0)
  }

  @Test(.dependencies) func expiringLoginRemindsEvenWithoutPriorLogout() async {
    let notifications = LockIsolated(0)
    let now = Date(timeIntervalSince1970: 1_000_000)
    let store = TestStore(initialState: state { $0.accounts = [work] }) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.date = .constant(now)
      $0[SystemNotificationClient.self].send = { _, _, _ in notifications.withValue { $0 += 1 } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    let expiry = now.addingTimeInterval(60 * 60)
    await store.send(.statusLoaded("work", .success(ClaudeAuthStatus(loggedIn: true, loginExpiresAt: expiry))))
    await store.finish()
    #expect(notifications.value == 1)
  }

  @Test(.dependencies) func userLogoutSuppressesTheReminder() async {
    let notifications = LockIsolated(0)
    let store = TestStore(
      initialState: state {
        $0.accounts = [work]
        $0.loggedInAccountIDs = ["work"]
      }
    ) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
      $0[SystemNotificationClient.self].send = { _, _, _ in notifications.withValue { $0 += 1 } }
      $0[ClaudeAccountsClient.self].authStatus = { _ in ClaudeAuthStatus(loggedIn: false) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.logoutButtonTapped("work"))
    await store.receive(\.logoutCompleted)
    await store.receive(\.refreshStatuses)
    await store.finish()
    #expect(notifications.value == 0)
    #expect(!store.state.file.loggedInAccountIDs.contains("work"))
  }

  @Test(.dependencies) func mcpSyncAppliesThePlanAndStoresTheBaseline() async {
    let server: JSONValue = ["type": "http", "url": "https://e.invalid"]
    let applied = LockIsolated<[String: [ClaudeMCPServerSync.Operation]]>([:])
    let store = TestStore(initialState: state { $0.accounts = [work] }) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
      $0[ClaudeAccountsClient.self].readMCPServers = { account in account.isMain ? ["srv": server] : [:] }
      $0[ClaudeAccountsClient.self].applyMCPOperations = { account, operations in
        applied.withValue { $0[account.id] = operations }
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.syncMCPServersButtonTapped)
    await store.receive(\.mcpSyncCompleted)
    #expect(applied.value == ["work": [.init(serverName: "srv", kind: .upsert(server))]])
    #expect(store.state.file.mcpServersBaseline == ["srv": server])
    #expect(store.state.mcpSync != .syncing)
  }

  @Test(.dependencies) func mcpReadFailureWritesNothing() async {
    let applied = LockIsolated(0)
    let store = TestStore(initialState: state { $0.accounts = [work] }) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0[ClaudeAccountsClient.self].readMCPServers = { account in
        if account.isMain { return [:] }
        throw ClaudeAccountsError.commandFailed("unreadable")
      }
      $0[ClaudeAccountsClient.self].applyMCPOperations = { _, _ in applied.withValue { $0 += 1 } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.syncMCPServersButtonTapped)
    await store.receive(\.mcpSyncCompleted)
    #expect(applied.value == 0)
    #expect(store.state.mcpSync == .failed("unreadable"))
    #expect(store.state.file.mcpServersBaseline == nil)
  }

  @Test(.dependencies) func loginStreamsOutputForwardsTheCodeAndRefreshesOnSuccess() async {
    let (events, continuation) = AsyncStream.makeStream(of: ClaudeLoginSession.Event.self)
    let inputs = LockIsolated<[String]>([])
    let store = TestStore(initialState: state { $0.accounts = [work] }) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
      $0[ClaudeAccountsClient.self].startLogin = { _ in events }
      $0[ClaudeAccountsClient.self].sendLoginInput = { line in inputs.withValue { $0.append(line) } }
      $0[ClaudeAccountsClient.self].authStatus = { _ in ClaudeAuthStatus(loggedIn: true) }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.loginButtonTapped("work"))
    continuation.yield(
      .output("If the browser didn't open, visit: https://claude.com/x?a=1\nPaste code here if prompted >"))
    await store.receive(\.loginEvent)
    #expect(store.state.login?.isWaitingForCode == true)
    #expect(store.state.login?.authorizationURL?.absoluteString == "https://claude.com/x?a=1")
    await store.send(.loginCodeChanged(" abc#123 "))
    await store.send(.loginCodeSubmitted)
    continuation.yield(.exited(0))
    continuation.finish()
    await store.receive(\.loginEvent)
    await store.receive(\.refreshStatuses)
    await store.receive(\.statusLoaded)
    await store.receive(\.statusLoaded)
    await store.finish()
    #expect(inputs.value == ["abc#123"])
    #expect(store.state.login?.phase == .succeeded)
    #expect(store.state.statuses["work"] == .loaded(ClaudeAuthStatus(loggedIn: true)))
  }

  @Test(.dependencies) func removingAnAccountLogsItOut() async {
    let loggedOut = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: state {
        $0.accounts = [work]
        $0.defaultAccountID = "work"
      }
    ) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0[ClaudeAccountsClient.self].logout = { account in loggedOut.withValue { $0.append(account.id) } }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.removeAccountButtonTapped("work"))
    #expect(store.state.alert != nil)
    await store.send(.alert(.presented(.confirmRemove("work"))))
    await store.finish()
    #expect(store.state.file.accounts.isEmpty)
    #expect(store.state.file.defaultAccountID == ClaudeAccount.mainID)
    #expect(loggedOut.value == ["work"])
  }

  @Test(.dependencies) func periodicTickRefreshesStatusesAndSyncs() async {
    let clock = TestClock()
    let checks = LockIsolated(0)
    let store = TestStore(initialState: state()) {
      ClaudeAccountsFeature()
    } withDependencies: {
      $0.date = .constant(Date(timeIntervalSince1970: 1_000_000))
      $0.continuousClock = clock
      $0[ClaudeAccountsClient.self].authStatus = { _ in
        checks.withValue { $0 += 1 }
        return ClaudeAuthStatus(loggedIn: true)
      }
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(.task)
    await store.receive(\.refreshStatuses)
    await store.receive(\.statusLoaded)
    #expect(checks.value == 1)
    await clock.advance(by: ClaudeAccountsFeature.refreshInterval)
    await store.receive(\.tick)
    await store.receive(\.refreshStatuses)
    await store.receive(\.statusLoaded)
    #expect(checks.value == 2)
    await store.skipInFlightEffects()
  }
}
