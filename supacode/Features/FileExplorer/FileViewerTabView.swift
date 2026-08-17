import AppKit
import SwiftUI

/// The body of a file-viewer tab. Markdown and HTML render with a Rendered/Raw
/// toggle (Raw is the editable source); other text files open in a
/// syntax-highlighted editor. Saves explicitly with ⌘S.
///
/// Owns no closing or sizing chrome: the tab strip provides both, and the tab's
/// close confirmation comes from `FileViewerContent.isBusy` rather than a
/// dialog this view raises.
struct FileViewerTabView: View {
  @Bindable var model: FileViewerModel

  /// Gates the real renderer behind one runloop turn so the spinner paints first.
  @State private var isContentMounted = false

  var body: some View {
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
    .background(.background)
    // Every new file goes back through the spinner: the next document may be the
    // slow one, and the view is reused rather than rebuilt.
    .onChange(of: model.fileURL) { _, _ in isContentMounted = false }
    .busyCursor(model.isPreparingContent)
  }

  private var headerIcon: String {
    switch model.loadState {
    case .media(.image): return "photo"
    case .media(.pdf): return "doc.richtext"
    default: return model.isMarkdown ? "doc.richtext" : "doc.text"
    }
  }

  /// The tab already shows the file name, so this row leads with the full path
  /// instead of repeating it — a viewer tab and a terminal tab in the same strip
  /// look alike, and the path is what tells them apart.
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
      if model.isMarkdown || model.isHTML {
        Picker("View mode", selection: $model.mode) {
          Text("Rendered").tag(FileViewerModel.Mode.rendered)
          Text("Raw").tag(FileViewerModel.Mode.raw)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Toggle the rendered page and editable source")
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
    if isContentMounted {
      loadedContent
        // Fires after the (potentially multi-second) first layout of the real
        // renderer, which is the moment the tab is genuinely usable.
        .onAppear { model.contentDidRender() }
    } else {
      preparingPlaceholder
    }
  }

  /// Drawn in the frame right after a file is opened, before the real renderer is
  /// mounted. Rendering a long document blocks the main thread for seconds, so
  /// without this the tab itself can't paint and the click looks ignored.
  private var preparingPlaceholder: some View {
    VStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text("Opening \(model.displayName)…")
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Opening \(model.displayName)")
    // Hand the mount of the real content to the next runloop turn, so this frame
    // reaches the screen first. `.task` alone wouldn't: it can run inside the
    // same transaction, before anything is drawn.
    .onAppear {
      DispatchQueue.main.async {
        isContentMounted = true
      }
    }
  }

  @ViewBuilder
  private var loadedContent: some View {
    switch model.loadState {
    case .empty:
      placeholder("No File Selected", systemImage: "doc")
    case .loaded:
      if model.isMarkdown, model.mode == .rendered {
        MarkdownPreview(markdown: model.text)
      } else if model.isHTML, model.mode == .rendered, let url = model.fileURL {
        // Rendered from disk, not from `model.text`: the page pulls its own
        // stylesheets and scripts, which only resolve relative to the real file.
        HTMLPreview(fileURL: url, isTrusted: model.isHTMLTrusted) { model.trustHTML() }
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

  private static let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
  }()
}
