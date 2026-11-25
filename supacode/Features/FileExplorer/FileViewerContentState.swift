import Foundation

/// Persisted payload of a file-viewer tab: the file it points at and the source
/// it lives on, and nothing else. The buffer is deliberately not stored — a
/// relaunch re-reads the file, so a stale layout can never resurrect an edit the
/// user did not save.
///
/// Fork-owned, referenced from upstream's `ContentState.fileViewer`.
nonisolated struct FileViewerContentState: Equatable, Codable, Sendable {
  /// Standardized absolute path. Normalizing on the way in is what lets the
  /// dedup lookup treat `docs/../README.md` and `README.md` as one file.
  let filePath: String

  /// The machine the path belongs to (`FileSystemSources` turns it back into a
  /// live source). `.local` for this Mac, which is every tab written before
  /// sources existed.
  let sourceID: FileSystemSourceID

  /// A path carrier: it may name a file on another machine (see
  /// `FileSystemSource`).
  var fileURL: URL { URL(filePath: filePath) }

  init(filePath: String, sourceID: FileSystemSourceID = .local) {
    self.filePath = URL(filePath: filePath).standardizedFileURL.path(percentEncoded: false)
    self.sourceID = sourceID
  }

  init(fileURL: URL, sourceID: FileSystemSourceID = .local) {
    self.init(filePath: fileURL.path(percentEncoded: false), sourceID: sourceID)
  }

  private enum CodingKeys: String, CodingKey {
    case path
    case source
  }

  /// A local tab is a bare path string, the shape every earlier build wrote and
  /// reads; only a tab on another source uses the keyed form.
  init(from decoder: any Decoder) throws {
    if let path = try? decoder.singleValueContainer().decode(String.self) {
      self.init(filePath: path)
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      filePath: container.decode(String.self, forKey: .path),
      sourceID: container.decode(FileSystemSourceID.self, forKey: .source)
    )
  }

  func encode(to encoder: any Encoder) throws {
    guard sourceID != .local else {
      var container = encoder.singleValueContainer()
      try container.encode(filePath)
      return
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(filePath, forKey: .path)
    try container.encode(sourceID, forKey: .source)
  }
}
