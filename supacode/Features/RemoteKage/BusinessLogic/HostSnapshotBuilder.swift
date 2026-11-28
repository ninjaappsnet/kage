import Foundation
import IdentifiedCollections
import OrderedCollections
import SupacodeSettingsShared

/// Builds the `HostSnapshot` this Kage reports to a viewing Kage. Pure: every
/// input is plain data, so ordering, filtering and zmx rules are unit-tested
/// without a running app. The runtime gathering lives in
/// `HostSnapshotRuntime`.
nonisolated enum HostSnapshotBuilder {
  /// One tab of a worktree as the host's layout reports it.
  struct TabInput: Equatable, Sendable {
    var id: UUID
    /// `TabTitle.resolved`: what the host's tab strip shows.
    var title: String
    var isFocused: Bool
    /// The tab's content UUID.
    var surfaceID: UUID
    /// False for file viewer tabs; they are not part of the snapshot.
    var isTerminal: Bool
    /// False for blocking-script runners, which launch outside zmx.
    var usesZmx: Bool
    /// The surface's current working directory, nil when unknown.
    var workingDirectory: String?
    /// The Claude account the surface started under, nil when unknown.
    var claudeAccountID: String?
  }

  /// One tracked agent on a surface (`AgentPresenceFeature` record).
  struct AgentInput: Equatable, Sendable {
    var surfaceID: UUID
    /// `SkillAgent` raw value.
    var kind: String
    /// `AgentPresenceFeature.Activity` raw value.
    var activity: String
  }

  struct Inputs: Sendable {
    var repositories: [Repository]
    var sidebar: SidebarState
    var tabsByWorktree: [Worktree.ID: [TabInput]]
    var agents: [AgentInput]
    var zmxPath: String?
    var cliPath: String?
    var kageVersion: String
    var machineName: String
    var claudeAccounts: [HostSnapshot.ClaudeAccountInfo]?
  }

  static func build(_ inputs: Inputs) -> HostSnapshot {
    let agentsBySurface = Dictionary(grouping: inputs.agents, by: \.surfaceID)
    let zmxAvailable = inputs.zmxPath != nil
    let locals = inputs.repositories.filter { $0.host == nil }
    let repositories = orderedRepositories(locals, sidebar: inputs.sidebar).map { repository in
      let section = inputs.sidebar.sections[repository.id]
      return HostSnapshot.Repository(
        id: repository.id.rawValue,
        name: Repository.sidebarDisplayName(custom: section?.title, fallback: repository.name),
        rootPath: repository.rootURL.path(percentEncoded: false),
        workspaceID: section?.workspaceID,
        isGitRepository: repository.isGitRepository,
        color: section?.color.map { HostSnapshot.RepositoryColorValue(rawValue: $0.rawValue) },
        worktrees: worktrees(of: repository, section: section).map { entry in
          HostSnapshot.Worktree(
            id: entry.worktree.id.rawValue,
            name: entry.name,
            path: entry.worktree.workingDirectory.path(percentEncoded: false),
            isMain: entry.worktree.isMainWorktree,
            isPinned: entry.isPinned,
            tabs: (inputs.tabsByWorktree[entry.worktree.id] ?? []).filter(\.isTerminal).map { tab in
              HostSnapshot.Tab(
                id: tab.id.uuidString,
                title: tab.title,
                isFocused: tab.isFocused,
                surfaceID: tab.surfaceID.uuidString,
                zmxSession: zmxAvailable && tab.usesZmx ? ZmxSessionID.make(surfaceID: tab.surfaceID) : nil,
                agents: (agentsBySurface[tab.surfaceID] ?? [])
                  .sorted { ($0.kind, $0.activity) < ($1.kind, $1.activity) }
                  .map { HostSnapshot.Agent(kind: $0.kind, activity: $0.activity) },
                workingDirectory: tab.workingDirectory,
                claudeAccountID: tab.claudeAccountID
              )
            },
            branch: entry.worktree.name
          )
        }
      )
    }
    return HostSnapshot(
      schemaVersion: HostSnapshot.currentSchemaVersion,
      kageVersion: inputs.kageVersion,
      machineName: inputs.machineName,
      zmxPath: inputs.zmxPath,
      cliPath: inputs.cliPath,
      workspaces: inputs.sidebar.workspaces.values.map { .init(id: $0.id, name: $0.name) },
      repositories: repositories,
      claudeAccounts: inputs.claudeAccounts
    )
  }

  /// Every account on this Mac, main first, as the snapshot reports them.
  @MainActor
  static func claudeAccounts(
    file: ClaudeAccountsFile,
    usages: [ClaudeAccountID: ClaudeAccountsFeature.UsageSnapshot],
    now: Date = .now
  ) -> [HostSnapshot.ClaudeAccountInfo] {
    let defaultID = file.resolvedAccount(tabID: nil, repositoryRootPath: nil).id
    return file.allAccounts.map { account in
      HostSnapshot.ClaudeAccountInfo(
        id: account.id,
        name: account.name,
        menuTitle: ClaudeAccountsFeature.State.menuTitle(for: account, usage: usages[account.id], now: now),
        isDefault: account.id == defaultID
      )
    }
  }

  /// The compact one-line JSON the CLI prints verbatim.
  static func encodeJSON(_ snapshot: HostSnapshot) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(bytes: try encoder.encode(snapshot), encoding: .utf8) ?? ""
  }

  /// The socket response: the wire is flat `[[String: String]]`, so the whole
  /// snapshot rides in one row.
  static func queryRows(_ snapshot: HostSnapshot) throws -> [[String: String]] {
    [["json": try encodeJSON(snapshot)]]
  }

  // MARK: - Ordering

  private static func orderedRepositories(_ repositories: [Repository], sidebar: SidebarState) -> [Repository] {
    let byID = Dictionary(repositories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var seen = Set<Repository.ID>()
    var result: [Repository] = []
    for id in sidebar.sections.keys {
      if let repository = byID[id], seen.insert(id).inserted { result.append(repository) }
    }
    for repository in repositories where seen.insert(repository.id).inserted {
      result.append(repository)
    }
    return result
  }

  private struct WorktreeEntry {
    var worktree: Worktree
    var name: String
    var isPinned: Bool
  }

  /// Main first, then pinned, then unpinned in the sidebar's order, then any
  /// worktree the sidebar has not seeded yet. Archived worktrees are dropped.
  private static func worktrees(of repository: Repository, section: SidebarState.Section?) -> [WorktreeEntry] {
    let archived = Set(section?.buckets[.archived]?.items.keys.map { $0 } ?? [])
    var seen = Set<Worktree.ID>()
    var result: [WorktreeEntry] = []

    func append(_ worktree: Worktree, pinned: Bool, customTitle: String?) {
      guard !archived.contains(worktree.id), seen.insert(worktree.id).inserted else { return }
      result.append(
        WorktreeEntry(
          worktree: worktree,
          name: Repository.sidebarDisplayName(custom: customTitle, fallback: worktree.name),
          isPinned: pinned
        )
      )
    }

    func customTitle(of worktree: Worktree) -> String? {
      section?.buckets[.pinned]?.items[worktree.id]?.title ?? section?.buckets[.unpinned]?.items[worktree.id]?.title
    }

    for worktree in repository.worktrees where worktree.isMainWorktree {
      let pinned = section?.buckets[.pinned]?.items[worktree.id] != nil
      append(worktree, pinned: pinned, customTitle: customTitle(of: worktree))
    }
    for (bucket, pinned) in [(SidebarState.BucketID.pinned, true), (.unpinned, false)] {
      for id in section?.buckets[bucket]?.items.keys.map({ $0 }) ?? [] {
        guard let worktree = repository.worktrees[id: id] else { continue }
        append(worktree, pinned: pinned, customTitle: section?.buckets[bucket]?.items[id]?.title)
      }
    }
    for worktree in repository.worktrees {
      append(worktree, pinned: false, customTitle: nil)
    }
    return result
  }
}
