import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The general pasteboard's files, for the explorer's Copy and Paste.
enum FileExplorerImportPasteboard {
  static func fileURLs(_ pasteboard: NSPasteboard = .general) -> [URL] {
    pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
  }

  static var hasFiles: Bool {
    NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
  }

  /// Puts the file itself on the pasteboard, as Cmd+C in Finder does.
  static func copy(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([url as NSURL])
  }
}

/// Makes the explorer's tree a place to drop files (copied into the root) and,
/// once a row was clicked, the target of Edit → Paste / Cmd+V (into the
/// selected folder, or the root) and Cmd+C (the selected file).
struct FileExplorerImportTargetModifier: ViewModifier {
  let isEnabled: Bool
  @Binding var isTargeted: Bool
  var isFocused: FocusState<Bool>.Binding
  let onImport: ([URL]) -> Void
  let onCopySelection: (() -> [NSItemProvider])?

  func body(content: Content) -> some View {
    if isEnabled {
      content
        .overlay {
          if isTargeted {
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(.tint, lineWidth: 2)
              .padding(2)
              .allowsHitTesting(false)
          }
        }
        .dropDestination(for: URL.self) { urls, _ in
          guard !FileExplorerImportTarget.importable(urls).isEmpty else { return false }
          onImport(urls)
          return true
        } isTargeted: {
          isTargeted = $0
        }
        .contextMenu {
          Button("Paste") { onImport(FileExplorerImportPasteboard.fileURLs()) }
            .disabled(!FileExplorerImportPasteboard.hasFiles)
        }
        .focusable()
        .focusEffectDisabled()
        .focused(isFocused)
        .onPasteCommand(of: [.fileURL]) { _ in
          onImport(FileExplorerImportPasteboard.fileURLs())
        }
        .onCopyCommand { onCopySelection?() ?? [] }
    } else {
      content
    }
  }
}

/// A copy in progress, or why one failed, under the explorer's header.
struct FileExplorerImportStatusView: View {
  let status: FileExplorerImportModel.Status
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      switch status {
      case .copying(let count):
        ProgressView()
          .controlSize(.small)
        Text(count == 1 ? "Copying 1 item…" : "Copying \(count) items…")
          .font(.callout)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      case .failed(let message):
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
        Text(message)
          .font(.callout)
          .lineLimit(3)
        Spacer(minLength: 0)
        Button(action: onDismiss) {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .buttonStyle(.borderless)
        .help("Dismiss")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
  }
}
