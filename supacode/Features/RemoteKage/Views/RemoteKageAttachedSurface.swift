import AppKit
import Foundation
import GhosttyKit
import SupacodeSettingsShared

/// Owns the one Ghostty surface of an attached remote terminal. It is built
/// straight on `GhosttyRuntime`, outside every local worktree structure: no
/// `LayoutFeature`, `ContentRuntime`, `WorktreeContentHost` or
/// `WorktreeTerminalManager` entry, so it gets no agent presence,
/// notifications, task status or layout persistence, and no local zmx session.
///
/// Closing it (`close()`, called when the view goes away) frees the surface;
/// Ghostty then SIGHUPs the child's process group, so the local ssh exits and
/// the host's zmx client detaches while the session keeps running there.
@MainActor
final class RemoteKageAttachedSurface {
  private static let logger = SupaLogger("RemoteKage")

  /// Everything the surface is constructed with.
  nonisolated struct Configuration: Equatable, Sendable {
    var command: String
    var workingDirectory: URL?
    var environment: [String: String]
    var commandWrapper: [String]
    var disableShellIntegration: Bool

    /// The attach command (see `RemoteKageAttachCommand`), run verbatim: no
    /// zmx wrapper (bypass), no shell integration (the child is ssh), no
    /// `SUPACODE_*` identity (it is not a worktree surface), from home.
    static func make(
      host: RemoteKageHost,
      zmxPath: String,
      session: String
    ) -> Result<Configuration, RemoteKageAttachCommand.Problem> {
      RemoteKageAttachCommand.surfaceCommand(host: host, zmxPath: zmxPath, session: session).map { command in
        Configuration(
          command: command,
          workingDirectory: URL.homeDirectory,
          environment: [:],
          commandWrapper: [],
          disableShellIntegration: true
        )
      }
    }
  }

  let configuration: Configuration
  private let runtime: GhosttyRuntime
  /// Uploads file and image pastes to the host; nil pastes as a local terminal does.
  private let pasteController: RemotePasteController?
  /// Called once when the session ends by itself (detach, session ended,
  /// close requested from inside the terminal). Not called for `close()`.
  var onExit: () -> Void
  private(set) var lifecycle = RemoteKageAttachLifecycle()
  private(set) var surfaceView: GhosttySurfaceView?

  init(
    configuration: Configuration,
    runtime: GhosttyRuntime,
    pasteController: RemotePasteController? = nil,
    onExit: @escaping () -> Void
  ) {
    self.configuration = configuration
    self.runtime = runtime
    self.pasteController = pasteController
    self.onExit = onExit
  }

  nonisolated deinit {
    // Safety net: a surface freed by deinit would assert in GhosttySurfaceView.
    MainActor.assumeIsolated {
      close()
    }
  }

  /// Builds the surface the first time; later calls return the same one, and
  /// nil once closed.
  func start(geometry: ContentGeometry) -> GhosttySurfaceView? {
    guard lifecycle.start() else { return surfaceView }
    let view = GhosttySurfaceView(
      id: UUID(),
      runtime: runtime,
      workingDirectory: configuration.workingDirectory,
      command: configuration.command,
      environmentVariables: configuration.environment,
      commandWrapper: configuration.commandWrapper,
      disableShellIntegration: configuration.disableShellIntegration,
      fontSize: TerminalSurfaceRecipe.rememberedZoomFontSize(gatedBy: runtime.windowInheritsFontSize()),
      initialGeometry: geometry,
      context: GHOSTTY_SURFACE_CONTEXT_WINDOW
    )
    Self.wire(view.bridge) { [weak self] in
      self?.sessionEnded()
    }
    if let pasteController {
      view.pasteInterceptor = { [weak pasteController] pasteboard in
        pasteController?.intercept(pasteboard) ?? false
      }
      pasteController.insert = { [weak view] text in
        view?.sendPastedText(text)
      }
    }
    surfaceView = view
    return view
  }

  /// Frees the surface (terminating ssh). Idempotent.
  func close() {
    guard lifecycle.close() else { return }
    surfaceView?.closeSurface()
    surfaceView = nil
  }

  private func sessionEnded() {
    guard lifecycle.finish() else { return }
    Self.logger.info("Remote attach ended.")
    onExit()
  }

  /// Local-tab topology means nothing here: new tab / split / tab navigation
  /// are consumed as no-ops so the keys never reach the remote session, and a
  /// close (tab or surface) closes only this terminal. The child exiting ends
  /// it too. Everything else (title, notifications, agent OSCs) is left
  /// unwired on purpose: the host's own Kage reports those via its snapshot.
  static func wire(_ bridge: GhosttySurfaceBridge, onEnd: @escaping () -> Void) {
    bridge.onNewTab = { true }
    bridge.onSplitAction = { _ in true }
    bridge.onGotoTab = { _ in true }
    bridge.onMoveTab = { _ in true }
    bridge.onCloseTab = { _ in
      onEnd()
      return true
    }
    bridge.onCloseRequest = { _ in onEnd() }
    bridge.onChildExited = { _ in onEnd() }
  }
}
