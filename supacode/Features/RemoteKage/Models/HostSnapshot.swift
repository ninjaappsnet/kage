import Foundation

/// What one Mac's Kage reports about itself to another Mac's Kage: the
/// `host-snapshot` socket query / `kage host snapshot` CLI output, read over
/// SSH by the Remote Kage hosts feature.
///
/// Wire contract, versioned by `schemaVersion`. Add fields as optionals so an
/// older viewer still decodes a newer host; bump the version only for a change
/// an older viewer would misread.
nonisolated struct HostSnapshot: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  var schemaVersion: Int
  /// `CFBundleShortVersionString` of the reporting Kage.
  var kageVersion: String
  /// The reporting Mac's own name (`Host.current().localizedName`), for display only.
  var machineName: String
  /// Absolute path of the reporting Kage's bundled zmx, nil when its sessions
  /// do not run under zmx (then nothing can attach).
  var zmxPath: String?
  /// Absolute path of the reporting Kage's bundled CLI (`Contents/Resources/bin/supacode`).
  var cliPath: String?
  /// The host's sidebar workspaces, in its switcher order.
  var workspaces: [Workspace]
  /// The host's local repositories in its sidebar order. Repositories the host
  /// itself reaches over SSH are omitted.
  var repositories: [Repository]
  /// The host's Claude Code accounts, main first. Nil from a host that predates
  /// them, which also can't open or restart tabs under an account.
  var claudeAccounts: [ClaudeAccountInfo]?

  /// One of the host's Claude accounts (`ClaudeAccount` on the host).
  nonisolated struct ClaudeAccountInfo: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    /// The host's menu label, usage included ("Work — 42% weekly · resets in 2d 5h").
    var menuTitle: String
    /// New tabs on the host use it when nothing more specific applies.
    var isDefault: Bool
  }

  nonisolated struct Workspace: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
  }

  nonisolated struct Repository: Codable, Equatable, Sendable, Identifiable {
    /// The host's repository id (raw, not percent-encoded).
    var id: String
    /// Sidebar display name (custom title or folder name).
    var name: String
    var rootPath: String
    /// Owning workspace id, nil when ungrouped.
    var workspaceID: String?
    var isGitRepository: Bool
    /// The host's header tint, if any.
    var color: RepositoryColorValue?
    /// Non-archived worktrees, main first, then the host's sidebar order.
    var worktrees: [Worktree]
  }

  nonisolated struct Worktree: Codable, Equatable, Sendable, Identifiable {
    /// The host's worktree id (raw, not percent-encoded). Pass to the host CLI
    /// percent-encoded, as its `-w` option expects.
    var id: String
    var name: String
    var path: String
    var isMain: Bool
    var isPinned: Bool
    /// Terminal tabs only (file viewer tabs are omitted), in strip order.
    var tabs: [Tab]
    /// The git branch the worktree is on; `name` may be a custom title. Nil from
    /// an older host, whose viewer then nests by `name`.
    var branch: String?
  }

  nonisolated struct Tab: Codable, Equatable, Sendable, Identifiable {
    /// The host's tab UUID string.
    var id: String
    /// What the host's tab strip shows (`TabTitle.resolved`).
    var title: String
    var isFocused: Bool
    /// The tab's terminal content UUID string.
    var surfaceID: String
    /// zmx session name (`supa-<surfaceID lowercased>`); nil when the tab does
    /// not run under zmx.
    var zmxSession: String?
    /// Agents the host's presence tracking sees on this surface, sorted by kind.
    var agents: [Agent]
    /// The surface's current working directory on the host (as its shell
    /// reported it), nil when unknown. Optional on the wire: older hosts omit it.
    var workingDirectory: String?
    /// The Claude account the tab's session started under (a `claudeAccounts`
    /// id), nil when unknown or from an older host.
    var claudeAccountID: String?
  }

  nonisolated struct Agent: Codable, Equatable, Sendable {
    /// `SkillAgent` raw value, e.g. "claude".
    var kind: String
    /// `AgentPresenceFeature.Activity` raw value: awaitingInput, busy, idle, error, compacting.
    var activity: String
  }

  /// A tint as it travels on the wire: a predefined name or `#RRGGBB[AA]`.
  nonisolated struct RepositoryColorValue: Codable, Equatable, Sendable {
    var rawValue: String
  }
}

nonisolated extension HostSnapshot.Tab {
  var isAwaitingInput: Bool { agents.contains { $0.activity == "awaitingInput" } }
  var isBusy: Bool { agents.contains { $0.activity == "busy" || $0.activity == "compacting" } }
}
