import ComposableArchitecture
import Foundation

/// Answers the `host-claude-tab` socket query (`kage host claude-tab`, run by a
/// viewing Mac over SSH): validates against this Kage's state, replies, and
/// hands the work to `ClaudeAccountsFeature`. Thin; `HostClaudeTabRequest` and
/// the reducer carry the tests.
enum HostClaudeTabRuntime {
  @MainActor
  static func respond(
    params: [String: String],
    clientFD: Int32,
    terminalManager: WorktreeTerminalManager,
    store: StoreOf<AppFeature>
  ) {
    func refuse(_ message: String) {
      AgentHookSocketServer.sendCommandResponse(clientFD: clientFD, ok: false, error: message)
    }
    let request: HostClaudeTabRequest
    switch HostClaudeTabRequest.parse(params) {
    case .failure(let failure): return refuse(failure.message)
    case .success(let parsed): request = parsed
    }
    guard store.claudeAccounts.file.account(id: request.accountID) != nil else {
      return refuse("This Mac has no Claude account \(request.accountID).")
    }
    switch request {
    case .assign(let tabID, let accountID):
      store.send(.claudeAccounts(.tabAssignmentRequested(tabID: tabID, accountID)))
    case .restart(let worktreeID, let tabID, let accountID):
      let worktree = store.repositories.repositories.lazy
        .flatMap(\.worktrees)
        .first { $0.id.rawValue == worktreeID }
      guard let worktree, !worktree.isMissing, worktree.localWorkingDirectory != nil else {
        return refuse("Worktree not found: \(worktreeID)")
      }
      guard terminalManager.tabCanRename(worktreeID: worktree.id, tabID: TabID(rawValue: tabID)) else {
        return refuse("That tab can't be restarted: it is gone or runs a script.")
      }
      store.send(
        .claudeAccounts(.restartTabConfirmed(accountID, worktree, tabID: TabID(rawValue: tabID), focus: false)))
    }
    AgentHookSocketServer.sendQueryResponse(clientFD: clientFD, data: [])
  }
}

/// The `host-*` socket queries a viewing Mac sends over SSH, in one arm of
/// `SupacodeApp.handleQuery`.
@MainActor
enum HostQueryRuntime {
  static func respond(
    resource: String,
    params: [String: String],
    clientFD: Int32,
    terminalManager: WorktreeTerminalManager,
    store: StoreOf<AppFeature>
  ) {
    if resource == HostClaudeTabRequest.resource {
      HostClaudeTabRuntime.respond(params: params, clientFD: clientFD, terminalManager: terminalManager, store: store)
    } else {
      HostSnapshotRuntime.respond(clientFD: clientFD, store: store)
    }
  }
}
