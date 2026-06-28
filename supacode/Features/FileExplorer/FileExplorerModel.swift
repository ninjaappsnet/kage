import AppKit
import Foundation

/// Drives the worktree file explorer panel: lazily lists directories, tracks
/// which folders are expanded and which row is selected, and keeps the flattened
/// `rows` in sync with the disk via FSEvents.
///
/// Non-TCA shared store (`@Observable`, per the project's terminal-layer
/// convention) because the tree is ephemeral, view-local UI state — expansion
/// and selection don't belong in app state and don't need time-travel/tests at
/// the reducer level. The pure ordering/flattening lives in `FileExplorerTree`,
/// which is unit-tested directly.
@MainActor
@Observable
final class FileExplorerModel {
  /// The directory this tree is rooted at. Follows the terminal's pwd, so it
  /// changes as the user `cd`s; see `updateRoot(_:)`.
  private(set) var rootURL: URL

  /// Flattened, depth-tagged visible rows. Only expanded branches contribute.
  private(set) var rows: [FileExplorerRow] = []

  /// The currently highlighted row, if any.
  var selectedURL: URL?

  /// Whether dotfiles are listed. On by default — devs want `.gitignore`,
  /// `.env`, and friends in a coding tool.
  var showsHiddenFiles = true {
    didSet {
      guard showsHiddenFiles != oldValue else { return }
      reload()
    }
  }

  private var rootChildren: [FileExplorerNode] = []
  private var childrenByDirectory: [URL: [FileExplorerNode]] = [:]
  private var expanded: Set<URL> = []
  private var watcher: FileSystemEventWatcher?

  init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
    reload()
    startWatching()
  }

  /// Re-root the tree at a new directory (the terminal `cd`'d into it). Expansion,
  /// selection, and cached listings belong to the previous root, so they reset;
  /// the FSEvents watcher restarts on the new directory.
  func updateRoot(_ url: URL) {
    let standardized = url.standardizedFileURL
    guard standardized != rootURL else { return }
    rootURL = standardized
    expanded.removeAll()
    childrenByDirectory.removeAll()
    selectedURL = nil
    reload()
    startWatching()
  }

  // MARK: - Tree state.

  func isExpanded(_ url: URL) -> Bool { expanded.contains(url) }

  /// Toggle a directory open/closed. Re-lists on open so a freshly expanded
  /// folder always shows current contents.
  func toggleExpansion(_ node: FileExplorerNode) {
    guard node.isDirectory else { return }
    if expanded.contains(node.url) {
      collapse(node.url)
    } else {
      expanded.insert(node.url)
      childrenByDirectory[node.url] = Self.listChildren(of: node.url, showsHiddenFiles: showsHiddenFiles)
    }
    rebuildRows()
  }

  /// Primary action for a row: directories expand/collapse, files just select.
  func activate(_ node: FileExplorerNode) {
    selectedURL = node.url
    if node.isDirectory {
      toggleExpansion(node)
    }
  }

  func select(_ node: FileExplorerNode) {
    selectedURL = node.url
  }

  private func collapse(_ url: URL) {
    expanded.remove(url)
    // Drop the cached listing and any descendant expansion so re-opening starts
    // fresh and memory doesn't grow with deep one-off browsing.
    childrenByDirectory[url] = nil
    let prefix = url.path(percentEncoded: false) + "/"
    expanded = expanded.filter { !$0.path(percentEncoded: false).hasPrefix(prefix) }
    childrenByDirectory = childrenByDirectory.filter { !$0.key.path(percentEncoded: false).hasPrefix(prefix) }
  }

  // MARK: - Refresh.

  /// Re-list the root and every still-valid expanded directory, prune expansion
  /// for folders that vanished, and rebuild the visible rows.
  func reload() {
    rootChildren = Self.listChildren(of: rootURL, showsHiddenFiles: showsHiddenFiles)
    let fileManager = FileManager.default
    for url in expanded {
      var isDirectory: ObjCBool = false
      let exists = fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
      if exists, isDirectory.boolValue {
        childrenByDirectory[url] = Self.listChildren(of: url, showsHiddenFiles: showsHiddenFiles)
      } else {
        expanded.remove(url)
        childrenByDirectory[url] = nil
      }
    }
    if let selectedURL, !fileManager.fileExists(atPath: selectedURL.path(percentEncoded: false)) {
      self.selectedURL = nil
    }
    rebuildRows()
  }

  private func rebuildRows() {
    rows = FileExplorerTree.flatten(
      rootChildren: rootChildren,
      expanded: expanded,
      childrenProvider: { [childrenByDirectory] url in childrenByDirectory[url] ?? [] }
    )
  }

  private func startWatching() {
    watcher = FileSystemEventWatcher(url: rootURL) { [weak self] in
      Task { @MainActor in
        self?.reload()
      }
    }
  }

  // MARK: - Row actions.

  func revealInFinder(_ node: FileExplorerNode) {
    NSWorkspace.shared.activateFileViewerSelecting([node.url])
  }

  func openWithDefaultApp(_ node: FileExplorerNode) {
    NSWorkspace.shared.open(node.url)
  }

  func copyAbsolutePath(_ node: FileExplorerNode) {
    Self.copyToPasteboard(node.url.path(percentEncoded: false))
  }

  func copyRelativePath(_ node: FileExplorerNode) {
    Self.copyToPasteboard(relativePath(for: node))
  }

  /// Path of `node` relative to the worktree root (falls back to the file name).
  func relativePath(for node: FileExplorerNode) -> String {
    let root = rootURL.path(percentEncoded: false)
    let full = node.url.path(percentEncoded: false)
    guard full.hasPrefix(root) else { return node.name }
    let trimmed = full.dropFirst(root.count)
    return String(trimmed.drop(while: { $0 == "/" }))
  }

  // MARK: - File system.

  private static func listChildren(of url: URL, showsHiddenFiles: Bool) -> [FileExplorerNode] {
    let options: FileManager.DirectoryEnumerationOptions = showsHiddenFiles ? [] : [.skipsHiddenFiles]
    guard
      let childURLs = try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: options,
      )
    else {
      return []
    }
    return childURLs.map { childURL in
      let isDirectory = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      return FileExplorerNode(url: childURL, name: childURL.lastPathComponent, isDirectory: isDirectory)
    }
  }

  private static func copyToPasteboard(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
  }
}
