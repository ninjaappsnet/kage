import ArgumentParser

@main
struct SupacodeCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: CLIInvocationName.current,
    abstract: "Control Kage from the command line.",
    subcommands: [
      OpenCommand.self,
      WorktreeCommand.self,
      PaneCommand.self,
      TabCommand.self,
      SurfaceCommand.self,
      RepoCommand.self,
      SettingsCommand.self,
      SocketCommand.self,
      HostCommand.self,
    ],
    defaultSubcommand: OpenCommand.self
  )
}
