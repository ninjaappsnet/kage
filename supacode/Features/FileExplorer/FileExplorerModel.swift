import AppKit
import Foundation

/// Drives the worktree file explorer panel: lazily lists directories, tracks
/// which folders are expanded and which row is selected, and keeps the flattened
/// `rows` in sync with the files through the source's change events.
///
/// Every read goes through a `FileSystemSource` (this Mac's disk by default, a
/// remote Kage host later), so the model never touches the disk itself and its
/// URLs are path carriers only (see `FileSystemSource`). Listing is lazy (only
/// the root and expanded directories) and cached per directory; change events
/// invalidate the cached listings they name.
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
  /// `.env`, and friends in a coding tool. Change it with
  /// `setShowsHiddenFiles(_:)`, which re-lists.
  private(set) var showsHiddenFiles = true

  /// False until the first listing of the current root has landed, so the panel
  /// can tell "not listed yet" from "empty folder".
  private(set) var hasLoaded = false

  /// Set while the source's link is down (a remote host gone away). The tree
  /// keeps its last listing; the panel shows this message. Any other failure
  /// reads as before: an unreadable directory lists as empty.
  private(set) var connectionErrorMessage: String?

  /// Invoked when a (non-directory) file is selected, so the parent can open it
  /// in the file viewer pane. `@ObservationIgnored` — it's a wiring callback, not
  /// rendered state.
  @ObservationIgnored var onOpenFile: ((URL) -> Void)?

  @ObservationIgnored let source: any FileSystemSource

  private var rootChildren: [FileExplorerNode] = []
  private var childrenByDirectory: [URL: [FileExplorerNode]] = [:]
  private var expanded: Set<URL> = []

  /// Bumped by every re-root and reload, so a listing that lands after a newer
  /// one started (or after the root moved) is dropped instead of applied.
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var activeWatch: FileSystemWatch?

  nonisolated deinit {}

  init(rootURL: URL, source: any FileSystemSource = LocalFileSystemSource()) {
    self.rootURL = rootURL.standardizedFileURL
    self.source = source
  }

  /// Whether Finder and the default apps can open these paths.
  var isLocal: Bool { source.isLocal }

  /// Lists the root, then follows the source's change events until the calling
  /// task is cancelled or the stream ends. The panel runs this in
  /// `.task(id: rootURL)`, so re-rooting restarts it on the new directory and
  /// closing the panel stops the watch.
  func run() async {
    let watch = source.watch(root: rootURL)
    activeWatch = watch
    publishWatchedDirectories()
    await reload()
    for await event in watch.events {
      await handle(event)
    }
  }

  /// Mirror the viewer's open file in the highlighted row. The highlight means
  /// "this is what the viewer is showing", so it follows the viewer rather than the
  /// last click: closing the viewer passes `nil` and clears it, instead of leaving a
  /// row highlighted with nothing behind it.
  func syncSelection(toOpenFile url: URL?) {
    let standardized = url?.standardizedFileURL
    guard selectedURL != standardized else { return }
    selectedURL = standardized
  }

  /// Re-root the tree at a new directory (the terminal `cd`'d into it). Expansion,
  /// selection, and cached listings belong to the previous root, so they reset.
  /// The previous rows stay on screen until the new root's listing lands (the
  /// panel's task re-runs `run()` for the new root), so a re-root never flashes
  /// an empty panel.
  func updateRoot(_ url: URL) {
    let standardized = url.standardizedFileURL
    guard standardized != rootURL else { return }
    rootURL = standardized
    generation += 1
    expanded.removeAll()
    childrenByDirectory.removeAll()
    selectedURL = nil
    activeWatch = nil
  }

  func setShowsHiddenFiles(_ value: Bool) async {
    guard showsHiddenFiles != value else { return }
    showsHiddenFiles = value
    await reload()
  }

  // MARK: - Tree state.

  func isExpanded(_ url: URL) -> Bool { expanded.contains(url) }

  /// Toggle a directory open/closed. Re-lists on open so a freshly expanded
  /// folder always shows current contents.
  func toggleExpansion(_ node: FileExplorerNode) async {
    guard node.isDirectory else { return }
    if expanded.contains(node.url) {
      collapse(node.url)
      rebuildRows()
      publishWatchedDirectories()
      return
    }
    expanded.insert(node.url)
    publishWatchedDirectories()
    let generation = generation
    let listing = await list(node.url)
    guard generation == self.generation, expanded.contains(node.url) else { return }
    apply(listing, to: node.url)
    rebuildRows()
  }

  /// Primary action for a row: directories expand/collapse, files open in the
  /// viewer pane.
  func activate(_ node: FileExplorerNode) async {
    selectedURL = node.url
    if node.isDirectory {
      await toggleExpansion(node)
    } else {
      onOpenFile?(node.url)
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
  func reload() async {
    generation += 1
    let generation = generation
    let directories = [rootURL] + expanded
    let listings = await listAll(directories)
    guard generation == self.generation else { return }
    for (directory, listing) in listings {
      apply(listing, to: directory)
    }
    await pruneSelection(generation: generation)
    guard generation == self.generation else { return }
    hasLoaded = true
    rebuildRows()
  }

  /// Applies one change event: `changed` re-lists only the named directories the
  /// tree holds, `rescan` re-lists everything. `treeChanged` feeds git status,
  /// which this panel does not show.
  func handle(_ event: FileSystemChangeEvent) async {
    switch event {
    case .changed(let directories):
      // Matched by path, not URL identity: an event's URL is built from a path
      // string and need not carry the trailing slash a listed directory's does.
      let named = Set(directories.map(Self.pathKey))
      let held = ([rootURL] + expanded).filter { named.contains(Self.pathKey($0)) }
      guard !held.isEmpty else { return }
      let generation = generation
      let listings = await listAll(held)
      guard generation == self.generation else { return }
      for (directory, listing) in listings {
        apply(listing, to: directory)
        dropSelectionIfGone(after: listing, of: directory)
      }
      rebuildRows()
    case .rescan:
      await reload()
    case .treeChanged:
      break
    }
  }

  /// One directory's listing outcome. A connection failure keeps what the tree
  /// already shows; a vanished directory is pruned; any other failure lists as
  /// empty, which is what an unreadable directory always showed.
  private enum Listing {
    case entries([FileExplorerNode])
    case vanished
    case unreadable
    case disconnected(String)
  }

  private func list(_ directory: URL) async -> Listing {
    do {
      let entries = try await source.list(directory, showsHiddenFiles: showsHiddenFiles)
      return .entries(entries.map { Self.node(for: $0, in: directory) })
    } catch {
      switch error.code {
      case .connection: return .disconnected(error.message)
      case .notFound: return .vanished
      default: return .unreadable
      }
    }
  }

  /// Lists several directories at once: a remote source pipelines the requests
  /// over one channel, so a reload costs one round trip, not one per folder.
  private func listAll(_ directories: [URL]) async -> [(URL, Listing)] {
    await withTaskGroup(of: (URL, Listing).self) { group in
      for directory in directories {
        group.addTask { await (directory, self.list(directory)) }
      }
      var listings: [(URL, Listing)] = []
      for await listing in group {
        listings.append(listing)
      }
      return listings
    }
  }

  private func apply(_ listing: Listing, to directory: URL) {
    let isRoot = directory == rootURL
    switch listing {
    case .entries(let nodes):
      if isRoot {
        rootChildren = nodes
        connectionErrorMessage = nil
      } else if expanded.contains(directory) {
        childrenByDirectory[directory] = nodes
      }
    case .disconnected(let message):
      if isRoot { connectionErrorMessage = message }
    case .vanished:
      if isRoot {
        rootChildren = []
      } else {
        expanded.remove(directory)
        childrenByDirectory[directory] = nil
        publishWatchedDirectories()
      }
    case .unreadable:
      if isRoot {
        rootChildren = []
      } else if expanded.contains(directory) {
        childrenByDirectory[directory] = []
      }
    }
  }

  /// Clears the highlight when its file is gone. Only a definite "not found"
  /// clears it; a dropped link says nothing about the file.
  private func pruneSelection(generation: Int) async {
    guard let selectedURL else { return }
    do {
      _ = try await source.stat(selectedURL)
    } catch let error where error.code == .notFound {
      guard generation == self.generation, self.selectedURL == selectedURL else { return }
      self.selectedURL = nil
    } catch {}
  }

  /// A re-listed directory that no longer holds the highlighted file clears the
  /// highlight without another round trip.
  private func dropSelectionIfGone(after listing: Listing, of directory: URL) {
    guard let selectedURL,
      Self.pathKey(selectedURL.deletingLastPathComponent()) == Self.pathKey(directory)
    else { return }
    switch listing {
    case .entries(let nodes):
      if !nodes.contains(where: { Self.pathKey($0.url) == Self.pathKey(selectedURL) }) { self.selectedURL = nil }
    case .vanished:
      self.selectedURL = nil
    case .unreadable, .disconnected:
      break
    }
  }

  /// A directory's path without a trailing slash, for comparing URLs that were
  /// built from different sources (a listing vs a path string).
  private static func pathKey(_ url: URL) -> String {
    var path = url.standardizedFileURL.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }

  private func rebuildRows() {
    rows = FileExplorerTree.flatten(
      rootChildren: rootChildren,
      expanded: expanded,
      childrenProvider: { [childrenByDirectory] url in childrenByDirectory[url] ?? [] }
    )
  }

  /// Tells the source which directories the tree holds listings for (protocol
  /// v1's `watch`), so a remote host only reports changes worth re-listing.
  private func publishWatchedDirectories() {
    activeWatch?.setWatchedDirectories(Set([rootURL]).union(expanded))
  }

  /// Only a real directory expands. A symlink to one does not, which is what the
  /// explorer always did (`URLResourceKey.isDirectoryKey` is false for a link).
  private static func node(for entry: FileSystemEntry, in directory: URL) -> FileExplorerNode {
    let isDirectory = entry.kind == .directory
    let url = directory.appending(path: entry.name, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    return FileExplorerNode(url: url, name: entry.name, isDirectory: isDirectory)
  }

  // MARK: - Row actions.

  func revealInFinder(_ node: FileExplorerNode) {
    guard isLocal else { return }
    NSWorkspace.shared.activateFileViewerSelecting([node.url])
  }

  func openWithDefaultApp(_ node: FileExplorerNode) {
    guard isLocal else { return }
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

  private static func copyToPasteboard(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
  }
}
