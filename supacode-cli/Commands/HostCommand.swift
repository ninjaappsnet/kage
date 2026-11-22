import ArgumentParser

struct HostCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "host",
    abstract: "Describe this Kage to another Kage.",
    subcommands: [Snapshot.self]
  )
}

extension HostCommand {
  struct Snapshot: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Print this Kage's host snapshot (repositories, worktrees, tabs, agents) as one line of JSON."
    )

    @OptionGroup var timeoutOption: TimeoutOption

    func run() throws {
      let rows = try QueryDispatcher.query(resource: "host-snapshot", timeoutSeconds: timeoutOption.timeout)
      guard let json = rows.first?["json"] else {
        throw ValidationError("Kage returned no host snapshot.")
      }
      print(json)
    }
  }
}
