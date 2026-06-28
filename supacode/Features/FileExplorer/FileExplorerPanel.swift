import AppKit
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// Left-docked file/folder explorer for the selected worktree, modeled on Warp's
/// project panel. Lists the active terminal's working directory as an expandable
/// tree, opens files / reveals in Finder, and stays live via FSEvents. The root
/// follows the terminal's pwd, so `cd`-ing in the terminal re-roots the tree.
/// Width persists across launches; the panel owns its `FileExplorerModel`, so the
/// parent gives it `.id(worktree.id)` to rebuild the tree when the selection
/// changes, while `rootURL` changes within a worktree re-root in place.
struct FileExplorerPanel: View {
  private let rootURL: URL
  private let onClose: () -> Void
  @State private var model: FileExplorerModel
  @State private var width: CGFloat = 260
  @Shared(.appStorage("fileExplorerWidth")) private var storedWidth = 260.0

  private static let minWidth: CGFloat = 180
  private static let maxWidth: CGFloat = 520

  init(rootURL: URL, onClose: @escaping () -> Void) {
    self.rootURL = rootURL
    self.onClose = onClose
    _model = State(initialValue: FileExplorerModel(rootURL: rootURL))
  }

  var body: some View {
    HStack(spacing: 0) {
      panelBody
        .frame(width: width)
      resizeHandle
    }
    .onAppear { width = Self.clamp(CGFloat(storedWidth)) }
    .onChange(of: rootURL) { _, newRoot in
      model.updateRoot(newRoot)
    }
  }

  private var panelBody: some View {
    VStack(spacing: 0) {
      header
      Divider()
      tree
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(.bar)
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: "folder.fill")
        .foregroundStyle(.tint)
        .imageScale(.small)
      Text(model.rootURL.lastPathComponent)
        .font(.headline)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 4)
      Button {
        model.showsHiddenFiles.toggle()
      } label: {
        Image(systemName: model.showsHiddenFiles ? "eye" : "eye.slash")
      }
      .buttonStyle(.borderless)
      .help(model.showsHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files")
      Button {
        model.reload()
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .help("Refresh File Explorer")
      Button(action: onClose) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("Close File Explorer (\(WorktreeDetailView.resolveShortcutDisplay(for: AppShortcuts.toggleFileExplorer)))")
    }
    .imageScale(.medium)
    .padding(.horizontal, 10)
    .frame(height: 38)
  }

  @ViewBuilder
  private var tree: some View {
    if model.rows.isEmpty {
      ContentUnavailableView("Empty Folder", systemImage: "folder")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(model.rows) { row in
            FileExplorerRowView(
              row: row,
              isSelected: model.selectedURL == row.node.url,
              model: model,
            )
          }
        }
        .padding(.vertical, 4)
      }
    }
  }

  private var resizeHandle: some View {
    ZStack {
      Divider()
      Color.clear
        .frame(width: 10)
        .contentShape(Rectangle())
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
              width = Self.clamp(width + value.translation.width)
            }
            .onEnded { _ in
              $storedWidth.withLock { $0 = Double(width) }
            }
        )
    }
    .frame(width: 10)
  }

  private static func clamp(_ value: CGFloat) -> CGFloat {
    min(max(value, minWidth), maxWidth)
  }
}

/// A single tree row: indentation, disclosure chevron for directories, a
/// type-based icon, and the name. Click selects (and toggles directories);
/// double-click opens a file. Tap gestures rather than a `Button` because a tree
/// row needs distinct single/double-click semantics a `Button` can't express.
private struct FileExplorerRowView: View {
  let row: FileExplorerRow
  let isSelected: Bool
  let model: FileExplorerModel

  private var node: FileExplorerNode { row.node }

  var body: some View {
    HStack(spacing: 4) {
      disclosure
      Image(systemName: FileExplorerIcon.systemName(for: node))
        .foregroundStyle(node.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .frame(width: 16)
        .imageScale(.small)
      Text(node.name)
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(node.isHidden ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
      Spacer(minLength: 0)
    }
    .padding(.vertical, 3)
    .padding(.trailing, 8)
    .padding(.leading, CGFloat(row.depth) * 14 + 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background(
      RoundedRectangle(cornerRadius: 5)
        .fill(Color.accentColor.opacity(isSelected ? 0.18 : 0))
        .padding(.horizontal, 4)
    )
    .onTapGesture(count: 2) {
      model.select(node)
      if node.isDirectory {
        model.toggleExpansion(node)
      } else {
        model.openWithDefaultApp(node)
      }
    }
    .onTapGesture {
      model.activate(node)
    }
    .contextMenu {
      if !node.isDirectory {
        Button("Open") { model.openWithDefaultApp(node) }
      }
      Button("Reveal in Finder") { model.revealInFinder(node) }
      Divider()
      Button("Copy Path") { model.copyAbsolutePath(node) }
      Button("Copy Relative Path") { model.copyRelativePath(node) }
    }
    .font(.callout)
  }

  @ViewBuilder
  private var disclosure: some View {
    if node.isDirectory {
      Image(systemName: "chevron.right")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
        .frame(width: 12)
    } else {
      Color.clear.frame(width: 12)
    }
  }
}

/// Maps a node to an SF Symbol. Directories get a folder; files map by extension
/// to a recognizable glyph, defaulting to a plain document.
private enum FileExplorerIcon {
  static func systemName(for node: FileExplorerNode) -> String {
    guard !node.isDirectory else { return "folder" }
    switch node.url.pathExtension.lowercased() {
    case "swift":
      return "swift"
    case "md", "markdown", "txt", "rtf":
      return "doc.text"
    case "json", "yml", "yaml", "toml", "plist", "xml", "lock":
      return "curlybraces"
    case "png", "jpg", "jpeg", "gif", "svg", "heic", "webp", "icns", "tiff":
      return "photo"
    case "sh", "zsh", "bash", "fish", "zig":
      return "apple.terminal"
    case "js", "jsx", "ts", "tsx", "py", "rb", "go", "rs", "c", "h", "cpp", "hpp", "m", "mm", "java", "kt":
      return "chevron.left.forwardslash.chevron.right"
    case "pdf":
      return "doc.richtext"
    case "zip", "gz", "tar", "xcframework":
      return "shippingbox"
    default:
      return node.isHidden ? "gearshape" : "doc"
    }
  }
}
