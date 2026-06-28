import Foundation
import SupacodeSettingsShared

private nonisolated let fileViewerLogger = SupaLogger("FileViewer")

/// Backs the file viewer/editor pane. Loads a text file off disk into an
/// editable buffer, tracks dirty state against the last saved contents, renders
/// markdown vs source code, and saves explicitly (⌘S) via the symlink-preserving
/// writer. Non-TCA shared store (`@Observable`, per the terminal-layer
/// convention): the open document is ephemeral, view-local UI state.
@MainActor
@Observable
final class FileViewerModel {
  /// Markdown files can show rendered output or the raw, editable source.
  enum Mode: Hashable { case rendered, raw }

  enum LoadState: Equatable {
    case empty
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
  private(set) var language: String?

  /// Markdown view mode. Ignored for non-markdown files (always editable).
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

  var hasFile: Bool { fileURL != nil }

  /// Only text files are editable; media/binary/oversized previews are not.
  var isEditable: Bool { loadState == .loaded }

  var isDirty: Bool { loadState == .loaded && text != savedText }

  /// Highlighting is skipped for large files to avoid per-keystroke jank; they
  /// stay editable as plain monospaced text.
  var shouldHighlightSyntax: Bool {
    loadState == .loaded && fileByteCount <= FileViewerFileType.maxHighlightBytes
  }

  /// Load `url` into the editor, classifying it as markdown / code / binary and
  /// guarding against oversized files.
  func open(_ url: URL) {
    let standardized = url.standardizedFileURL
    fileURL = standardized
    displayName = standardized.lastPathComponent
    externalChangePending = false
    saveErrorMessage = nil
    mode = .rendered

    do {
      // FileManager (not URL.resourceValues) for the mtime: URL caches resource
      // values on the instance, which would mask later external changes since we
      // re-read the same stored URL when checking for conflicts on save.
      let attributes = try FileManager.default.attributesOfItem(atPath: standardized.path(percentEncoded: false))
      diskModificationDate = attributes[.modificationDate] as? Date
      let size = (attributes[.size] as? Int) ?? 0
      // Media (images / PDF) is previewed from the URL, not loaded as text.
      if let kind = FileViewerFileType.mediaKind(for: standardized) {
        reset(to: size > FileViewerFileType.maxMediaBytes ? .tooLarge(size) : .media(kind))
        return
      }
      if size > FileViewerFileType.maxEditableBytes {
        reset(to: .tooLarge(size))
        return
      }
      let data = try Data(contentsOf: standardized)
      guard !FileViewerFileType.isProbablyBinary(data), let string = String(data: data, encoding: .utf8) else {
        reset(to: .binary)
        return
      }
      fileByteCount = data.count
      savedText = string
      text = string
      isMarkdown = FileViewerFileType.isMarkdown(url: standardized, sample: string)
      language = isMarkdown ? "markdown" : FileViewerFileType.highlightrLanguage(for: standardized)
      mode = isMarkdown ? .rendered : .raw
      loadState = .loaded
    } catch {
      fileViewerLogger.error("Failed to open \(standardized.path): \(error.localizedDescription)")
      reset(to: .unreadable(error.localizedDescription))
    }
  }

  /// Save the buffer to disk. Refuses (surfacing `externalChangePending`) when
  /// the file changed externally since it was opened; the user then chooses
  /// Reload or Overwrite.
  func save() {
    guard loadState == .loaded, let url = fileURL else { return }
    if diskChangedExternally(url) {
      externalChangePending = true
      return
    }
    write(to: url)
  }

  /// Save unconditionally, overwriting any external change. Invoked from the
  /// conflict banner's "Overwrite" action.
  func overwriteSave() {
    guard loadState == .loaded, let url = fileURL else { return }
    write(to: url)
  }

  /// Discard the buffer and re-read the current file from disk.
  func reloadFromDisk() {
    guard let url = fileURL else { return }
    open(url)
  }

  func close() {
    fileURL = nil
    displayName = ""
    savedText = ""
    text = ""
    language = nil
    isMarkdown = false
    mode = .rendered
    diskModificationDate = nil
    externalChangePending = false
    saveErrorMessage = nil
    fileByteCount = 0
    loadState = .empty
  }

  private func write(to url: URL) {
    do {
      try SymlinkPreservingFileWriter.write(Data(text.utf8), to: url)
      savedText = text
      externalChangePending = false
      saveErrorMessage = nil
      diskModificationDate = Self.modificationDate(of: url) ?? diskModificationDate
    } catch {
      saveErrorMessage = error.localizedDescription
      fileViewerLogger.error("Failed to save \(url.path): \(error.localizedDescription)")
    }
  }

  /// A save conflict: the file changed on disk since it was opened, OR it was
  /// deleted/moved out from under us (`modificationDate` now `nil`). Either way
  /// the user must resolve it rather than blindly overwrite.
  private func diskChangedExternally(_ url: URL) -> Bool {
    guard let known = diskModificationDate else { return false }
    guard let current = Self.modificationDate(of: url) else { return true }
    return current > known
  }

  /// Reads the on-disk modification date via `FileManager`, which fetches fresh
  /// each call — unlike `URL.resourceValues`, which caches on the URL instance.
  private static func modificationDate(of url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
  }

  private func reset(to state: LoadState) {
    savedText = ""
    text = ""
    language = nil
    isMarkdown = false
    fileByteCount = 0
    loadState = state
  }
}
