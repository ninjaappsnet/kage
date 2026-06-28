import AppKit
import Sharing
import SwiftUI

/// Right-docked file viewer/editor, modeled on Warp's file pane. Opened when a
/// text file is selected in the explorer. Markdown renders with a Rendered/Raw
/// toggle (Raw is the editable source); other text files open in a
/// syntax-highlighted editor. Saves explicitly with ⌘S. Width persists across
/// launches.
struct FileViewerPanel: View {
  @Bindable var model: FileViewerModel
  let onClose: () -> Void

  @State private var width: CGFloat = 420
  @State private var showCloseConfirm = false
  @Shared(.appStorage("fileViewerWidth")) private var storedWidth = 420.0

  private static let minWidth: CGFloat = 280
  private static let maxWidth: CGFloat = 900

  var body: some View {
    HStack(spacing: 0) {
      resizeHandle
      panelBody
        .frame(width: width)
    }
    .onAppear { width = Self.clamp(CGFloat(storedWidth)) }
  }

  private var panelBody: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if model.externalChangePending {
        conflictBanner
        Divider()
      }
      if let saveError = model.saveErrorMessage {
        saveErrorBanner(saveError)
        Divider()
      }
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(.bar)
    .onKeyPress(.escape) {
      requestClose()
      return .handled
    }
    .confirmationDialog(
      "Close without saving changes to “\(model.displayName)”?",
      isPresented: $showCloseConfirm,
      titleVisibility: .visible
    ) {
      Button("Save & Close") {
        model.save()
        if !model.isDirty { onClose() }
      }
      Button("Discard Changes", role: .destructive) { onClose() }
      Button("Cancel", role: .cancel) {}
    }
  }

  /// Close, but guard unsaved edits behind a confirmation so they aren't lost.
  private func requestClose() {
    if model.isDirty {
      showCloseConfirm = true
    } else {
      onClose()
    }
  }

  private var headerIcon: String {
    switch model.loadState {
    case .media(.image): return "photo"
    case .media(.pdf): return "doc.richtext"
    default: return model.isMarkdown ? "doc.richtext" : "doc.text"
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: headerIcon)
        .foregroundStyle(.tint)
        .imageScale(.small)
        .accessibilityHidden(true)
      Text(model.displayName)
        .font(.headline)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(model.fileURL?.path(percentEncoded: false) ?? "")
      if model.isDirty {
        Circle()
          .fill(.orange)
          .frame(width: 6, height: 6)
          .help("Unsaved changes")
      }
      Spacer(minLength: 4)
      if model.isMarkdown {
        Picker("View mode", selection: $model.mode) {
          Text("Rendered").tag(FileViewerModel.Mode.rendered)
          Text("Raw").tag(FileViewerModel.Mode.raw)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Toggle rendered markdown and editable source")
      }
      if model.isEditable {
        Button {
          model.save()
        } label: {
          Image(systemName: "square.and.arrow.down")
            .accessibilityLabel("Save")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!model.isDirty)
        .help("Save (⌘S)")
      }
      Button {
        model.reloadFromDisk()
      } label: {
        Image(systemName: "arrow.clockwise")
          .accessibilityLabel("Reload from Disk")
      }
      .buttonStyle(.borderless)
      .help("Reload from Disk")
      Button(action: requestClose) {
        Image(systemName: "xmark")
          .accessibilityLabel("Close File Viewer")
      }
      .buttonStyle(.borderless)
      .help("Close File Viewer (Esc)")
    }
    .imageScale(.medium)
    .padding(.horizontal, 10)
    .frame(height: 38)
  }

  private var conflictBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text("This file changed on disk.")
        .font(.callout)
      Spacer(minLength: 4)
      Button("Reload") { model.reloadFromDisk() }
      Button("Overwrite") { model.overwriteSave() }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.orange.opacity(0.12))
  }

  private func saveErrorBanner(_ message: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.octagon.fill")
        .foregroundStyle(.red)
        .accessibilityHidden(true)
      Text("Couldn't save: \(message)")
        .font(.callout)
        .lineLimit(2)
      Spacer(minLength: 4)
      Button("Retry") { model.save() }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.red.opacity(0.12))
  }

  @ViewBuilder
  private var content: some View {
    switch model.loadState {
    case .empty:
      placeholder("No File Selected", systemImage: "doc")
    case .loaded:
      if model.isMarkdown, model.mode == .rendered {
        MarkdownPreview(markdown: model.text)
      } else {
        HighlightedCodeEditor(
          text: $model.text,
          language: model.language,
          highlightSyntax: model.shouldHighlightSyntax
        )
        .id(model.fileURL)
      }
    case .media(let kind):
      if let url = model.fileURL {
        MediaPreview(url: url, kind: kind)
      }
    case .binary:
      unsupported("Can't preview a binary file", systemImage: "doc.questionmark")
    case .tooLarge(let bytes):
      unsupported(
        "File too large to edit (\(Self.byteFormatter.string(fromByteCount: Int64(bytes))))",
        systemImage: "doc.badge.ellipsis"
      )
    case .unreadable(let message):
      placeholder(message, systemImage: "exclamationmark.triangle")
    }
  }

  private func placeholder(_ title: String, systemImage: String) -> some View {
    ContentUnavailableView(title, systemImage: systemImage)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func unsupported(_ title: String, systemImage: String) -> some View {
    VStack(spacing: 12) {
      ContentUnavailableView(title, systemImage: systemImage)
      if let url = model.fileURL {
        Button("Open in Default App") { NSWorkspace.shared.open(url) }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var resizeHandle: some View {
    ZStack {
      Divider()
      Color.clear
        .frame(width: 10)
        .contentShape(Rectangle())
        .onHover { hovering in
          if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
          DragGesture(minimumDistance: 1)
            .onChanged { value in
              // Handle is on the pane's left edge, so dragging left widens it.
              width = Self.clamp(width - value.translation.width)
            }
            .onEnded { _ in
              $storedWidth.withLock { $0 = Double(width) }
            }
        )
    }
    .frame(width: 10)
  }

  private static let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
  }()

  private static func clamp(_ value: CGFloat) -> CGFloat {
    min(max(value, minWidth), maxWidth)
  }
}
