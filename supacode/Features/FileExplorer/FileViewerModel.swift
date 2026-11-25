import Foundation
import SupacodeSettingsShared

private nonisolated let fileViewerLogger = SupaLogger("FileViewer")

/// Backs the file viewer/editor pane. Loads a text file into an editable buffer,
/// tracks dirty state against the last saved contents, renders markdown vs
/// source code, and saves explicitly (⌘S). Every read and write goes through a
/// `FileSystemSource` (this Mac's disk by default, a remote Kage host later), so
/// `fileURL` is a path carrier only and the model never touches the disk itself.
/// Non-TCA shared store (`@Observable`, per the terminal-layer convention): the
/// open document is ephemeral, view-local UI state.
@MainActor
@Observable
final class FileViewerModel {
  /// Markdown files can show rendered output or the raw, editable source.
  enum Mode: Hashable { case rendered, raw }

  enum LoadState: Equatable {
    case empty
    /// A read is in flight; the pane keeps its spinner up.
    case loading
    case loaded
    case media(FileViewerFileType.MediaKind)
    case binary
    case tooLarge(Int)
    case unreadable(String)
  }

  private(set) var fileURL: URL?
  private(set) var displayName = ""
  private(set) var loadState: LoadState = .empty
  private(set) var isMarkdown = false
  private(set) var isHTML = false
  private(set) var language: String?

  /// The bytes of an image or PDF, read through the source so the preview never
  /// opens the path itself (it may live on another machine).
  private(set) var mediaData: Data?

  /// Where the open file lives. The HTML preview serves the page's assets
  /// through it too.
  @ObservationIgnored let source: any FileSystemSource

  /// Whether the open HTML document may reach the network. Off for every newly
  /// opened file: the preview runs the page's JavaScript, and these files are
  /// routinely agent-written, so egress is opt-in per document rather than a
  /// setting that silently stays on. See `HTMLPreviewPolicy.contentSecurityPolicy`.
  private(set) var isHTMLTrusted = false

  /// Markdown/HTML view mode. Ignored for other files (always editable).
  var mode: Mode = .rendered

  /// The editable buffer. Diverges from `savedText` once the user types.
  var text = ""

  private var savedText = ""
  private var diskModificationDate: Date?

  /// Set when a save is attempted but the file changed on disk since it was
  /// opened. The UI surfaces a banner so the user resolves it explicitly rather
  /// than silently clobbering an external edit (e.g. an agent rewriting it).
  private(set) var externalChangePending = false

  /// Last save failure (permission denied, disk full…), surfaced as a banner so a
  /// failed write isn't only visible in the log. Cleared on a successful save or
  /// when another file is opened.
  private(set) var saveErrorMessage: String?

  private var fileByteCount = 0

  /// Bumped by every load and by `close()`, so a read that lands after a newer
  /// open (or after the pane closed) is dropped instead of applied.
  @ObservationIgnored private var loadGeneration = 0

  /// The last save started; the next one waits for it (`enqueueWrite`).
  @ObservationIgnored private var pendingWrite: Task<Void, Never>?

  /// True from the moment a file is opened until the pane reports that the real
  /// content has been mounted. Reading the file is fast, but rendering it is not
  /// — a long markdown document blocks the main thread for seconds, and nothing
  /// can paint while it does. The pane draws a spinner for this flag in an
  /// earlier frame, so a click has visible feedback instead of appearing dead.
  private(set) var isPreparingContent = false

  var hasFile: Bool { fileURL != nil }

  /// Only text files are editable; media/binary/oversized previews are not.
  var isEditable: Bool { loadState == .loaded }

  var isDirty: Bool { loadState == .loaded && text != savedText }

  /// Highlighting is skipped for large files to avoid per-keystroke jank; they
  /// stay editable as plain monospaced text.
  var shouldHighlightSyntax: Bool {
    loadState == .loaded && fileByteCount <= FileViewerFileType.maxHighlightBytes
  }

  /// Whether Finder and the default apps can open `fileURL`.
  var isLocal: Bool { source.isLocal }

  nonisolated deinit {}

  init(source: any FileSystemSource = LocalFileSystemSource()) {
    self.source = source
  }

  /// Load `url` into the editor, classifying it as markdown / code / binary and
  /// guarding against oversized files.
  func open(_ url: URL) async {
    // Re-opening the file already on screen would re-read it from disk; with
    // unsaved edits in the buffer that silently discards them. Reload from Disk
    // remains the explicit way to throw the buffer away.
    guard fileURL?.standardizedFileURL != url.standardizedFileURL || !isDirty else { return }
    await load(url)
  }

  /// Marks the pane's real content as mounted, clearing the spinner the pane
  /// shows while the (potentially multi-second) first render runs.
  func contentDidRender() {
    isPreparingContent = false
  }

  private func load(_ url: URL) async {
    isPreparingContent = true
    loadGeneration += 1
    let generation = loadGeneration
    let standardized = url.standardizedFileURL
    fileURL = standardized
    displayName = standardized.lastPathComponent
    externalChangePending = false
    saveErrorMessage = nil
    mode = .rendered
    isHTMLTrusted = false
    // The previous buffer goes now, not when the read lands: until then it is
    // neither editable nor dirty, so nothing can save it over the new path.
    reset(to: .loading)
    diskModificationDate = nil

    // Media (images / PDF) is previewed from its bytes, not loaded as text, so it
    // gets the larger cap. The source refuses an oversized file without reading it.
    let mediaKind = FileViewerFileType.mediaKind(for: standardized)
    let cap = mediaKind == nil ? FileViewerFileType.maxEditableBytes : FileViewerFileType.maxMediaBytes
    let result: FileSystemReadResult
    do {
      result = try await source.read(standardized, maxBytes: cap)
    } catch {
      guard generation == loadGeneration else { return }
      if error.code == .tooLarge {
        diskModificationDate = error.modificationDate
        reset(to: .tooLarge(error.size ?? 0))
      } else {
        fileViewerLogger.error("Failed to open \(standardized.path): \(error.localizedDescription)")
        reset(to: .unreadable(error.localizedDescription))
      }
      return
    }
    guard generation == loadGeneration else { return }
    diskModificationDate = result.modificationDate
    if let mediaKind {
      mediaData = result.data
      loadState = .media(mediaKind)
      return
    }
    let data = result.data
    guard !FileViewerFileType.isProbablyBinary(data), let string = String(data: data, encoding: .utf8) else {
      reset(to: .binary)
      return
    }
    fileByteCount = data.count
    savedText = string
    text = string
    isMarkdown = FileViewerFileType.isMarkdown(url: standardized, sample: string)
    // Classified only once the bytes are known to be text, so a file that
    // merely ends in `.html` but holds binary never reaches the web view.
    isHTML = HTMLPreviewPolicy.isPreviewable(url: standardized)
    language = isMarkdown ? "markdown" : FileViewerFileType.highlightrLanguage(for: standardized)
    mode = isMarkdown || isHTML ? .rendered : .raw
    loadState = .loaded
  }

  /// Save the buffer. Refuses (surfacing `externalChangePending`) when the file
  /// changed externally since it was opened; the user then chooses Reload or
  /// Overwrite.
  func save() async {
    await enqueueWrite(overwrite: false)
  }

  /// Save unconditionally, overwriting any external change. Invoked from the
  /// conflict banner's "Overwrite" action.
  func overwriteSave() async {
    await enqueueWrite(overwrite: true)
  }

  /// The close confirmation's "Save": answers synchronously whether the buffer
  /// is now safe to drop. This Mac's disk writes on the spot (same conflict
  /// check as `save()`). A source that must suspend to write cannot answer in
  /// time, so the save starts in the background and this reports `false`: the
  /// tab stays open with its buffer rather than closing on a write that has not
  /// landed.
  func saveBeforeClose() -> Bool {
    guard loadState == .loaded, let url = fileURL else { return !isDirty }
    guard let immediate = source as? any ImmediateFileSystemWriting else {
      Task { await save() }
      return false
    }
    let written = text
    do {
      let modified = try immediate.writeImmediately(
        Data(written.utf8),
        to: url,
        expectedModificationDate: diskModificationDate
      )
      didSave(written, modificationDate: modified)
    } catch {
      didFailToSave(error, url: url)
    }
    return !isDirty
  }

  /// Discard the buffer and re-read the current file. Goes straight to `load`,
  /// bypassing `open`'s guard against clobbering unsaved edits — that is
  /// exactly what this action is for.
  func reloadFromDisk() async {
    guard let url = fileURL else { return }
    await load(url)
  }

  /// Let the open HTML document reach the network. Scoped to this document —
  /// `open(_:)` clears it — so trust never leaks to the next file.
  func trustHTML() {
    guard isHTML else { return }
    isHTMLTrusted = true
  }

  func close() {
    loadGeneration += 1
    isPreparingContent = false
    fileURL = nil
    displayName = ""
    savedText = ""
    text = ""
    language = nil
    isMarkdown = false
    isHTML = false
    isHTMLTrusted = false
    mode = .rendered
    diskModificationDate = nil
    externalChangePending = false
    saveErrorMessage = nil
    fileByteCount = 0
    mediaData = nil
    loadState = .empty
  }

  /// Runs writes one at a time. A save issued while another is in flight waits
  /// for it, so it compares against the modification date that write produced
  /// rather than the one it replaced — otherwise a quick second ⌘S would read the
  /// user's own first save as an external change.
  private func enqueueWrite(overwrite: Bool) async {
    let previous = pendingWrite
    let next = Task { [weak self] in
      await previous?.value
      guard let self, loadState == .loaded, let url = fileURL else { return }
      await write(to: url, expectedModificationDate: overwrite ? nil : diskModificationDate)
    }
    pendingWrite = next
    await next.value
  }

  /// Writes exactly the text captured here: the user may keep typing while a
  /// write is in flight, and those keystrokes must stay dirty.
  private func write(to url: URL, expectedModificationDate: Date?) async {
    let written = text
    let generation = loadGeneration
    do {
      let modified = try await source.write(
        Data(written.utf8),
        to: url,
        expectedModificationDate: expectedModificationDate
      )
      guard generation == loadGeneration else { return }
      didSave(written, modificationDate: modified)
    } catch {
      guard generation == loadGeneration else { return }
      didFailToSave(error, url: url)
    }
  }

  private func didSave(_ written: String, modificationDate: Date?) {
    savedText = written
    externalChangePending = false
    saveErrorMessage = nil
    diskModificationDate = modificationDate ?? diskModificationDate
  }

  /// A refused write is a conflict: the file changed on disk since it was
  /// opened, OR it was deleted/moved out from under us. Either way the user must
  /// resolve it rather than blindly overwrite. Anything else is a save error.
  private func didFailToSave(_ error: FileSystemSourceError, url: URL) {
    if error.code == .conflict {
      externalChangePending = true
      return
    }
    saveErrorMessage = error.localizedDescription
    fileViewerLogger.error("Failed to save \(url.path): \(error.localizedDescription)")
  }

  private func reset(to state: LoadState) {
    savedText = ""
    text = ""
    language = nil
    isMarkdown = false
    isHTML = false
    fileByteCount = 0
    mediaData = nil
    loadState = state
  }
}
