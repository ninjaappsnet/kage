import ArgumentParser
import Foundation

struct HostCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "host",
    abstract: "Describe this Kage to another Kage.",
    subcommands: [Snapshot.self, Serve.self, ClaudeTab.self]
  )
}

extension HostCommand {
  struct Snapshot: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Print this Kage's host snapshot (repositories, worktrees, tabs, agents) as one line of JSON."
    )

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      // A viewer polls this command; unlike other commands it must never launch Kage.
      // Exit 69 (EX_UNAVAILABLE) tells the viewer that Kage is not running.
      let hasEnvironmentSocket = SocketDiscovery.fromEnvironment().map(SocketDiscovery.isAlive) ?? false
      if !hasEnvironmentSocket, try SocketDiscovery.listAll().isEmpty {
        FileHandle.standardError.write(Data("Error: Kage isn't running.\n".utf8))
        throw ExitCode(69)
      }
      let rows = try QueryDispatcher.query(resource: "host-snapshot", timeoutSeconds: timeoutOption.timeout)
      guard let json = rows.first?["json"] else {
        throw ValidationError("Kage returned no host snapshot.")
      }
      print(json)
    }
  }
}

extension HostCommand {
  /// A viewing Kage opens or restarts this Kage's tabs under one of its Claude
  /// accounts (ids from `host snapshot`). The app answers the `host-claude-tab`
  /// query (`HostClaudeTabRequest`); keep the parameter names in step.
  struct ClaudeTab: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "claude-tab",
      abstract: "Open or restart a tab whose Claude Code runs as one of this Kage's Claude accounts.",
      subcommands: [New.self, Restart.self]
    )

    static let resource = "host-claude-tab"
  }
}

extension HostCommand.ClaudeTab {
  struct New: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Create a tab in the background whose Claude Code runs as an account. Prints the tab id."
    )

    @Option(name: [.short, .long], help: "Worktree ID, as `worktree list` prints it.")
    var worktree: String

    @Option(name: [.short, .customLong("id")], help: "UUID for the new tab.")
    var newID: String?

    @Option(name: .long, help: "Claude account id, as `host snapshot` reports it.")
    var account: String

    @Option(name: [.short, .long], help: "Command to run in the new tab.")
    var input: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func validate() throws {
      try IDResolvers.validateNewID(newID)
    }

    func run() throws {
      let tabID = newID ?? UUID().uuidString
      // The assignment lands first, so the tab's surface starts under it.
      _ = try QueryDispatcher.query(
        resource: HostCommand.ClaudeTab.resource,
        params: ["action": "assign", "tabID": tabID, "accountID": account],
        timeoutSeconds: timeoutOption.timeout
      )
      var arguments = ["-w", worktree, "--id", tabID, "--background", "--timeout", String(timeoutOption.timeout)]
      if let input { arguments.append("--input=\(input)") }
      try TabCommand.New.parse(arguments).run()
    }
  }

  struct Restart: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Restart a tab under an account. Claude Code running in it comes back as it was started."
    )

    @Option(name: [.short, .long], help: "Worktree ID, as `worktree list` prints it.")
    var worktree: String

    @Option(name: [.short, .long], help: "Tab UUID.")
    var tab: String

    @Option(name: .long, help: "Claude account id, as `host snapshot` reports it.")
    var account: String

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      _ = try QueryDispatcher.query(
        resource: HostCommand.ClaudeTab.resource,
        params: ["action": "restart", "worktreeID": worktree, "tabID": tab, "accountID": account],
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }
}
