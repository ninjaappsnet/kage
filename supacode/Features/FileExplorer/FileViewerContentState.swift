import Foundation

/// Persisted payload of a file-viewer tab: the file it points at, and nothing
/// else. The buffer is deliberately not stored — a relaunch re-reads from disk,
/// so a stale layout can never resurrect an edit the user did not save.
///
/// Fork-owned, referenced from upstream's `ContentState.fileViewer`.
nonisolated struct FileViewerContentState: Equatable, Codable, Sendable {
  /// Standardized absolute path. Normalizing on the way in is what lets the
  /// dedup lookup treat `docs/../README.md` and `README.md` as one file.
  let filePath: String

  var fileURL: URL { URL(filePath: filePath) }

  init(filePath: String) {
    self.filePath = URL(filePath: filePath).standardizedFileURL.path(percentEncoded: false)
  }

  init(fileURL: URL) {
    self.init(filePath: fileURL.path(percentEncoded: false))
  }

  init(from decoder: any Decoder) throws {
    try self.init(filePath: decoder.singleValueContainer().decode(String.self))
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(filePath)
  }
}
