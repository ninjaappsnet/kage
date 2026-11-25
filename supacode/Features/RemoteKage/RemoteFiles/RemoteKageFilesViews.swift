import Sharing
import SupacodeSettingsShared
import SwiftUI

/// The explorer column of a remote worktree: the same docked `FileExplorerPanel`
/// as a local worktree, reading through the host's `RemoteFileSystemSource`,
/// or a message when the host's Kage can't serve files.
struct RemoteKageExplorerColumn: View {
  let hostName: String
  let source: RemoteFileSystemSource
  let rootURL: URL
  let openFileURL: URL?
  let status: RemoteKageServeSession.Status?
  let onOpenFile: (URL) -> Void
  let onClose: () -> Void

  var body: some View {
    switch RemoteKageFilesPresentation.resolve(status: status, hostName: hostName) {
    case .explorer(let isConnecting):
      FileExplorerPanel(
        rootURL: rootURL,
        source: source,
        openFileURL: openFileURL,
        onOpenFile: onOpenFile,
        onClose: onClose
      )
      .overlay {
        if isConnecting {
          ProgressView("Connecting to \(hostName)…")
            .controlSize(.small)
            .padding(12)
            .background(.regularMaterial, in: .rect(cornerRadius: 8))
        }
      }
    case .unavailable(let title, let message, let systemImage):
      RemoteKageExplorerUnavailable(title: title, message: message, systemImage: systemImage, onClose: onClose)
    }
  }
}

private struct RemoteKageExplorerUnavailable: View {
  let title: String
  let message: String
  let systemImage: String
  let onClose: () -> Void
  @Shared(.appStorage("fileExplorerWidth")) private var storedWidth = 260.0
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        HStack {
          Spacer(minLength: 0)
          Button(action: onClose) {
            Image(systemName: "xmark")
              .accessibilityLabel("Close File Explorer")
          }
          .buttonStyle(.borderless)
          .help(
            AppShortcut.helpText(
              "Close File Explorer",
              shortcut: AppShortcuts.toggleFileExplorer.effective(from: settingsFile.global.shortcutOverrides)
            )
          )
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        Divider()
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(width: CGFloat(storedWidth))
      .background(.bar)
      Divider()
    }
  }
}

/// The right-hand viewer / editor for a remote file: the local viewer's views
/// in a resizable pane beside the attached terminal or screen preview. Closes
/// with its button or Esc, asking first when the buffer has unsaved edits.
struct RemoteKageFileViewerPane: View {
  let model: FileViewerModel
  let onClose: () -> Void
  @Shared(.appStorage("remoteKageFileViewerWidth")) private var storedWidth = Double(
    RemoteKageFileViewerOpening.defaultWidth)
  @State private var width = RemoteKageFileViewerOpening.defaultWidth
  @State private var dragStartWidth: CGFloat?
  @State private var isConfirmingClose = false

  var body: some View {
    HStack(spacing: 0) {
      resizeHandle
      FileViewerTabView(model: model, onClose: requestClose)
        .frame(minWidth: 0, idealWidth: width, maxWidth: width)
    }
    .onAppear { width = RemoteKageFileViewerOpening.clampedWidth(CGFloat(storedWidth)) }
    .onExitCommand(perform: requestClose)
    .confirmationDialog(
      "Close \(model.displayName) without saving?",
      isPresented: $isConfirmingClose
    ) {
      Button("Discard Changes", role: .destructive, action: onClose)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Your edits haven't been saved to the host.")
    }
  }

  private func requestClose() {
    if model.isDirty {
      isConfirmingClose = true
    } else {
      onClose()
    }
  }

  private var resizeHandle: some View {
    ZStack {
      Divider()
      Color.clear
        .frame(width: 8)
        .contentShape(.rect)
        .onHover { hovering in
          if hovering {
            NSCursor.resizeLeftRight.push()
          } else {
            NSCursor.pop()
          }
        }
        .gesture(
          DragGesture(minimumDistance: 1)
            .onChanged { value in
              let start = dragStartWidth ?? width
              dragStartWidth = start
              width = RemoteKageFileViewerOpening.clampedWidth(start - value.translation.width)
            }
            .onEnded { _ in
              dragStartWidth = nil
              $storedWidth.withLock { $0 = Double(width) }
            }
        )
    }
    .frame(width: 8)
  }
}
