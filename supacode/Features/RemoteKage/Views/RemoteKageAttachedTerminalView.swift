import AppKit
import SwiftUI

extension EnvironmentValues {
  /// The app's Ghostty runtime, for terminals hosted outside a worktree
  /// layout (Remote Kage attached tabs). Injected at the app root; nil in
  /// previews, where the view shows a placeholder instead.
  @Entry var remoteKageGhosttyRuntime: GhosttyRuntime?
}

/// A live terminal attached to one remote zmx session over SSH. Closing it
/// (removing the view) detaches; the session keeps running on the host.
///
/// `onExit` fires once when the session ends from inside the terminal: the
/// user detached (ctrl+\\), the remote session ended, the session was already
/// gone, or a close was requested from the terminal (close tab / surface
/// keybinding). It does not fire when the view is simply removed. The owner
/// usually responds by dropping the tab from its attached set.
struct RemoteKageAttachedTerminalView: View {
  let host: RemoteKageHost
  let zmxPath: String
  let session: String
  var onExit: () -> Void = {}

  @Environment(\.remoteKageGhosttyRuntime) private var runtime

  init(host: RemoteKageHost, zmxPath: String, session: String, onExit: @escaping () -> Void = {}) {
    self.host = host
    self.zmxPath = zmxPath
    self.session = session
    self.onExit = onExit
  }

  var body: some View {
    let configuration = RemoteKageAttachedSurface.Configuration.make(host: host, zmxPath: zmxPath, session: session)
    switch (runtime, configuration) {
    case (_, .failure(let problem)):
      ContentUnavailableView(
        "Can't Attach",
        systemImage: "exclamationmark.triangle",
        description: Text(problem.message)
      )
    case (nil, .success):
      ContentUnavailableView("Terminal Unavailable", systemImage: "terminal")
    case (let runtime?, .success(let configuration)):
      RemoteKageAttachedTerminalContainer(host: host, configuration: configuration, runtime: runtime, onExit: onExit)
        // A different session (or host) is a different terminal: rebuild, which
        // detaches the old one, instead of reusing its surface.
        .id(configuration.command)
    }
  }
}

/// Bridges the attached surface into SwiftUI. The coordinator owns it for the
/// view's lifetime; `dismantleNSView` frees it, which ends the local ssh.
struct RemoteKageSurfaceRepresentable: NSViewRepresentable {
  let configuration: RemoteKageAttachedSurface.Configuration
  let runtime: GhosttyRuntime
  var pasteController: RemotePasteController?
  let onExit: () -> Void

  final class Coordinator {
    let attached: RemoteKageAttachedSurface

    init(attached: RemoteKageAttachedSurface) {
      self.attached = attached
    }

    nonisolated deinit {}
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      attached: RemoteKageAttachedSurface(
        configuration: configuration,
        runtime: runtime,
        pasteController: pasteController,
        onExit: onExit
      )
    )
  }

  func makeNSView(context: Context) -> RemoteKageSurfaceHostView {
    RemoteKageSurfaceHostView(attached: context.coordinator.attached)
  }

  func updateNSView(_ view: RemoteKageSurfaceHostView, context: Context) {
    context.coordinator.attached.onExit = onExit
  }

  static func dismantleNSView(_ view: RemoteKageSurfaceHostView, coordinator: Coordinator) {
    coordinator.attached.close()
  }
}

/// Builds the surface when it first lands in a window (so the PTY starts near
/// its real size), pins the surface's scroll wrapper to its bounds (resizes
/// follow layout), marks it visible, and gives it keyboard focus.
final class RemoteKageSurfaceHostView: NSView {
  private let attached: RemoteKageAttachedSurface
  private var hasShown = false
  private var pendingFocus: Task<Void, Never>?

  init(attached: RemoteKageAttachedSurface) {
    self.attached = attached
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  nonisolated deinit {
    MainActor.assumeIsolated {
      pendingFocus?.cancel()
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else {
      pendingFocus?.cancel()
      pendingFocus = nil
      attached.surfaceView?.setOcclusion(false)
      return
    }
    guard let surface = attached.start(geometry: ContentGeometry.resolve(anchors: [self])) else { return }
    mount(surface)
    surface.setOcclusion(true)
    claimFocus(surface, firstShow: !hasShown)
    hasShown = true
  }

  private func mount(_ surface: GhosttySurfaceView) {
    let hosted = surface.hostedView()
    guard hosted.superview !== self else { return }
    hosted.removeFromSuperview()
    hosted.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hosted)
    NSLayoutConstraint.activate([
      hosted.leadingAnchor.constraint(equalTo: leadingAnchor),
      hosted.trailingAnchor.constraint(equalTo: trailingAnchor),
      hosted.topAnchor.constraint(equalTo: topAnchor),
      hosted.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  /// Next runloop turn: SwiftUI may still be mid-mount, with `window` about
  /// to flip, when the view first attaches.
  private func claimFocus(_ surface: GhosttySurfaceView, firstShow: Bool) {
    let attachedWindow = window
    pendingFocus?.cancel()
    pendingFocus = Task { @MainActor [weak self, weak surface] in
      guard let self, let surface, !Task.isCancelled, let window = self.window, window === attachedWindow,
        surface.window === window
      else { return }
      let owner = RemoteKageSurfaceFocus.owner(of: window.firstResponder, in: window)
      guard window.firstResponder !== surface,
        RemoteKageSurfaceFocus.shouldClaim(firstShow: firstShow, currentOwner: owner)
      else { return }
      window.makeFirstResponder(surface)
    }
  }
}
