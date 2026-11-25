import ArgumentParser
import Foundation

struct HostCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "host",
    abstract: "Describe this Kage to another Kage.",
    subcommands: [Snapshot.self, Serve.self]
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
