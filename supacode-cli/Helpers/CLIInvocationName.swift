import Foundation

/// The name the CLI was invoked as. `Resources/bin/kage` is a symlink to
/// `supacode`, so help text follows argv[0] instead of always saying
/// `supacode`.
nonisolated enum CLIInvocationName {
  static let current = resolve(argv0: CommandLine.arguments.first)

  static func resolve(argv0: String?) -> String {
    argv0.map { URL(filePath: $0).lastPathComponent } == "kage" ? "kage" : "supacode"
  }
}
