import SwiftUI

/// One attached remote terminal plus its paste uploads: owns the
/// `RemotePasteController` for the terminal's lifetime and shows its status
/// over the bottom edge.
struct RemoteKageAttachedTerminalContainer: View {
  let host: RemoteKageHost
  let configuration: RemoteKageAttachedSurface.Configuration
  let runtime: GhosttyRuntime
  let onExit: () -> Void

  @State private var pasteController: RemotePasteController

  init(
    host: RemoteKageHost,
    configuration: RemoteKageAttachedSurface.Configuration,
    runtime: GhosttyRuntime,
    onExit: @escaping () -> Void
  ) {
    self.host = host
    self.configuration = configuration
    self.runtime = runtime
    self.onExit = onExit
    _pasteController = State(initialValue: RemotePasteController(uploader: .ssh(host: host)))
  }

  var body: some View {
    RemoteKageSurfaceRepresentable(
      configuration: configuration,
      runtime: runtime,
      pasteController: pasteController,
      onExit: onExit
    )
    .overlay(alignment: .bottomTrailing) {
      RemotePasteStatusView(status: pasteController.status, hostName: host.name) {
        pasteController.dismissFailure()
      }
      .padding(12)
    }
  }
}

/// "Uploading to <host>…" while a paste uploads; the reason, with a dismiss
/// button, when one failed. Nothing when idle.
struct RemotePasteStatusView: View {
  let status: RemotePasteController.Status
  let hostName: String
  let dismiss: () -> Void

  var body: some View {
    switch status {
    case .idle:
      EmptyView()
    case .uploading(let itemCount):
      Label {
        Text(itemCount == 1 ? "Uploading to \(hostName)…" : "Uploading \(itemCount) files to \(hostName)…")
      } icon: {
        ProgressView().controlSize(.small)
      }
      .font(.callout)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(.regularMaterial, in: .capsule)
      .help("The pasted files are being copied to \(hostName); their paths are pasted when they arrive.")
    case .failed(let message):
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).accessibilityHidden(true)
        Text("Couldn't paste: \(message)").lineLimit(2)
        Button("Dismiss", systemImage: "xmark", action: dismiss)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .help("Dismiss this message")
      }
      .font(.callout)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(.regularMaterial, in: .capsule)
    }
  }
}
