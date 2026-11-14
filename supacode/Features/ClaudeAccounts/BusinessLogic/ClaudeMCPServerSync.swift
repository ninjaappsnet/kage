import Foundation
import SupacodeSettingsShared

/// Keeps user-scope MCP servers identical across every Claude account.
///
/// User MCP servers live in each account's `.claude.json` beside its identity, so
/// they can't be shared through a link the way settings are. Instead Kage merges
/// them: a server added, changed or removed in any account propagates to all.
///
/// The merge is three-way against `baseline`, the set as of the last successful
/// sync. Per server name, every account whose value differs from the baseline
/// "changed" it; with no change the baseline value stands, otherwise the first
/// changed account in priority order wins (main first). Absence is a value, so a
/// removal propagates like an edit. With no baseline yet (first sync) the result
/// is the union, again in priority order.
nonisolated enum ClaudeMCPServerSync {
  typealias Servers = [String: JSONValue]

  struct Operation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
      case upsert(JSONValue)
      case remove
    }

    var serverName: String
    var kind: Kind
  }

  struct Plan: Equatable, Sendable {
    /// The agreed set every account ends up with, and the next baseline.
    var merged: Servers
    /// Per account, in the order given, the edits that bring it to `merged`.
    var operations: [ClaudeAccountID: [Operation]]

    var isNoOp: Bool { operations.values.allSatisfy(\.isEmpty) }
  }

  /// - Parameter accounts: each account's current servers, highest priority first.
  static func plan(
    baseline: Servers?,
    accounts: [(id: ClaudeAccountID, servers: Servers)]
  ) -> Plan {
    var names = Set(baseline.map { Array($0.keys) } ?? [])
    for account in accounts { names.formUnion(account.servers.keys) }

    var merged: Servers = [:]
    for name in names {
      let value: JSONValue?
      if let baseline {
        let original = baseline[name]
        let change = accounts.first { $0.servers[name] != original }
        value = change.map { $0.servers[name] } ?? original
      } else {
        value = accounts.lazy.compactMap { $0.servers[name] }.first
      }
      if let value { merged[name] = value }
    }

    var operations: [ClaudeAccountID: [Operation]] = [:]
    for account in accounts {
      var edits: [Operation] = []
      for name in names.sorted() {
        let current = account.servers[name]
        let target = merged[name]
        guard current != target else { continue }
        if let target {
          edits.append(Operation(serverName: name, kind: .upsert(target)))
        } else {
          edits.append(Operation(serverName: name, kind: .remove))
        }
      }
      operations[account.id] = edits
    }
    return Plan(merged: merged, operations: operations)
  }

  /// The `mcpServers` object of a `.claude.json`, or empty when the file or key is
  /// missing. Throws only for a file that exists but isn't JSON, so a sync never
  /// mistakes an unreadable file for "every server was removed".
  static func readServers(globalStateURL: URL) throws -> Servers {
    guard FileManager.default.fileExists(atPath: globalStateURL.path(percentEncoded: false)) else { return [:] }
    let data = try Data(contentsOf: globalStateURL)
    let root = try JSONDecoder().decode(JSONValue.self, from: data)
    return root.objectValue?["mcpServers"]?.objectValue ?? [:]
  }

  /// Compact JSON for `claude mcp add-json`.
  static func encodedConfiguration(_ value: JSONValue) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(bytes: try encoder.encode(value), encoding: .utf8) ?? "{}"
  }
}
