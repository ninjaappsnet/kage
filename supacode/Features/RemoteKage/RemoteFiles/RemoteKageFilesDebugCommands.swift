import AppKit
import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

private nonisolated let debugCommandsLogger = SupaLogger("RemoteFiles")

/// One command for the remote files debug driver: `verb` or `verb:argument`.
nonisolated struct RemoteKageFilesDebugCommand: Equatable, Sendable {
  var verb: String
  var argument: String

  static func parse(_ text: String) -> Self {
    guard let colon = text.firstIndex(of: ":") else { return Self(verb: text, argument: "") }
    return Self(verb: String(text[..<colon]), argument: String(text[text.index(after: colon)...]))
  }
}

/// Debug builds only, and only with `KAGE_DEBUG_SNAPSHOT_DIR` set (the dev
/// sandbox): lets an agent without Accessibility permission drive the remote
/// files UI through the distributed notification
/// `net.ninjaapps.kage.debug.remote-files`, whose object is a command
/// (`scripts/dev-sandbox-app.sh remote <command>` sends it):
/// - `select:<host name>|<remote worktree path>`: select that remote worktree in the sidebar
/// - `mark:<text>`: only logged, to bracket a measurement in the app log
/// - `explorer:on` / `explorer:off`, `explorer-root:<path>`: show the explorer, re-root it
/// - `open:<path>`, `append:<text>`, `save`, `reload`, `close`: drive the viewer pane
@MainActor
@Observable
final class RemoteKageFilesDebugCommands {
  static let shared = RemoteKageFilesDebugCommands()
  static let notificationName = Notification.Name("net.ninjaapps.kage.debug.remote-files")

  /// The latest command, numbered so a repeat of the same text still fires.
  private(set) var latest: (sequence: Int, command: RemoteKageFilesDebugCommand)?

  @ObservationIgnored private var observer: (any NSObjectProtocol)?
  @ObservationIgnored private var sequence = 0

  nonisolated deinit {}

  func installIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
    #if DEBUG
      guard observer == nil, DebugWindowSnapshot.directory(environment: environment) != nil else { return }
      observer = DistributedNotificationCenter.default().addObserver(
        forName: Self.notificationName,
        object: nil,
        queue: .main
      ) { notification in
        let text = notification.object as? String ?? ""
        debugCommandsLogger.info("Debug command: \(text)")
        MainActor.assumeIsolated {
          let commands = RemoteKageFilesDebugCommands.shared
          commands.sequence += 1
          commands.latest = (commands.sequence, RemoteKageFilesDebugCommand.parse(text))
        }
      }
    #endif
  }
}

/// Applies `select:` commands. Appended to the sidebar list, the one place that
/// sees both the remote hosts' snapshots and the sidebar selection.
struct RemoteKageFilesDebugSelection: ViewModifier {
  let repositoriesStore: StoreOf<RepositoriesFeature>
  @Environment(\.remoteKageStore) private var remoteKageStore

  func body(content: Content) -> some View {
    #if DEBUG
      content
        .onAppear { RemoteKageFilesDebugCommands.shared.installIfRequested() }
        .onChange(of: RemoteKageFilesDebugCommands.shared.latest?.sequence) { _, _ in
          guard let command = RemoteKageFilesDebugCommands.shared.latest?.command,
            command.verb == "select",
            let remoteKageStore
          else { return }
          // `select:<host name>|<worktree path>`
          let parts = command.argument.split(separator: "|", maxSplits: 1).map(String.init)
          guard parts.count == 2,
            let host = remoteKageStore.hosts.first(where: { $0.name == parts[0] }),
            let worktree = remoteKageStore.hostStates[host.id]?.lastSnapshot?.repositories
              .flatMap(\.worktrees).first(where: { $0.path == parts[1] })
          else { return }
          let selection = RemoteKageSelection(hostID: host.id, worktreeID: worktree.id)
          repositoriesStore.send(.selectionChanged([.remoteKage(selection)]))
        }
    #else
      content
    #endif
  }
}
