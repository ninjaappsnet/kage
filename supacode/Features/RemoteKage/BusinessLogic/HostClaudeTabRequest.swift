import Foundation

/// What a viewing Mac asks of this Kage's Claude accounts through
/// `kage host claude-tab` (socket query `host-claude-tab`). The parameter names
/// are the CLI's (`HostCommand.ClaudeTab`); `HostClaudeTabCLITests` pins both sides.
nonisolated enum HostClaudeTabRequest: Equatable, Sendable {
  /// The tab about to be created with this id runs Claude Code as the account.
  case assign(tabID: UUID, accountID: String)
  /// Restart the tab under the account, without asking here: the viewer asked.
  case restart(worktreeID: String, tabID: UUID, accountID: String)

  static let resource = "host-claude-tab"

  enum Failure: Error, Equatable, Sendable {
    case unknownAction(String)
    case missing(String)
    case invalidTabID(String)

    var message: String {
      switch self {
      case .unknownAction(let action): "Unknown claude-tab action \"\(action)\"."
      case .missing(let field): "Missing \(field)."
      case .invalidTabID(let value): "\(value) is not a tab UUID."
      }
    }
  }

  var accountID: String {
    switch self {
    case .assign(_, let accountID), .restart(_, _, let accountID): accountID
    }
  }

  static func parse(_ params: [String: String]) -> Result<Self, Failure> {
    func field(_ name: String) -> Result<String, Failure> {
      guard let value = params[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return .failure(.missing(name))
      }
      return .success(value)
    }
    func tabID() -> Result<UUID, Failure> {
      field("tabID").flatMap { UUID(uuidString: $0).map(Result.success) ?? .failure(.invalidTabID($0)) }
    }
    let action = params["action"] ?? ""
    switch action {
    case "assign":
      return tabID().flatMap { tabID in field("accountID").map { .assign(tabID: tabID, accountID: $0) } }
    case "restart":
      return field("worktreeID").flatMap { encoded in
        tabID().flatMap { tabID in
          field("accountID").map {
            .restart(worktreeID: encoded.removingPercentEncoding ?? encoded, tabID: tabID, accountID: $0)
          }
        }
      }
    default:
      return .failure(.unknownAction(action))
    }
  }
}
