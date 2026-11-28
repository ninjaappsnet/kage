import Foundation

/// Where a drop or paste lands in the explorer, and what of it can be copied.
nonisolated enum FileExplorerImportTarget {
  /// A folder row takes the items itself, a file row hands them to its folder,
  /// and empty space (`nil`) means the explorer's root.
  static func directory(onto node: FileExplorerNode?, root: URL) -> URL {
    guard let node else { return root }
    if node.isDirectory { return node.url }
    return node.url.deletingLastPathComponent()
  }

  /// Only files on this Mac can be copied; a web link dropped from a browser is ignored.
  static func importable(_ urls: [URL]) -> [URL] {
    urls.filter(\.isFileURL)
  }
}

/// Why a copy into the explorer failed, worded for the panel.
nonisolated struct FileExplorerImportError: LocalizedError, Equatable {
  var message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? { message }
}

/// Copies files from this Mac into a directory the explorer shows: this Mac's
/// disk (`local`) or a remote Kage host's (`remote(host:)`). Always a copy,
/// never a move, and never an overwrite: a taken name lands Finder-style as
/// "name copy". Returns the names the items landed under.
nonisolated struct FileExplorerImporter: Sendable {
  let importItems: @Sendable (_ sources: [URL], _ directory: URL) async throws -> [String]

  init(importItems: @escaping @Sendable (_ sources: [URL], _ directory: URL) async throws -> [String]) {
    self.importItems = importItems
  }

  static let local = Self { sources, directory in
    try await Task.detached(priority: .userInitiated) {
      try copyLocally(sources, into: directory)
    }.value
  }

  /// One item at a time, so a failure names the item and leaves the earlier
  /// copies in place.
  static func copyLocally(_ sources: [URL], into directory: URL) throws -> [String] {
    let manager = FileManager.default
    let target = comparablePath(directory)
    var landed: [String] = []
    for source in sources {
      let name = source.lastPathComponent
      let sourcePath = comparablePath(source)
      if target == sourcePath || target.hasPrefix(sourcePath + "/") {
        throw FileExplorerImportError("“\(name)” can’t be copied into itself.")
      }
      let free = FileExplorerClient.uniqueName(for: name) { candidate in
        manager.fileExists(atPath: directory.appending(path: candidate).path(percentEncoded: false))
      }
      do {
        try FileExplorerClient.performTransfer(
          source: source, directory: directory, name: free, operation: .copy, policy: .abort)
      } catch {
        throw FileExplorerImportError("“\(name)” couldn’t be copied: \(error.localizedDescription)")
      }
      landed.append(free)
    }
    return landed
  }

  private static func comparablePath(_ url: URL) -> String {
    var path = url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }
}

/// The explorer panel's copy state: what is copying, and why a copy failed.
/// One copy runs at a time; a drop while one runs is ignored.
@MainActor
@Observable
final class FileExplorerImportModel {
  enum Status: Equatable {
    case copying(count: Int)
    case failed(String)
  }

  private(set) var status: Status?
  @ObservationIgnored let importer: FileExplorerImporter

  nonisolated deinit {}

  init(importer: FileExplorerImporter) {
    self.importer = importer
  }

  var isImporting: Bool {
    if case .copying = status { return true }
    return false
  }

  /// Copies the file URLs among `urls` into `directory`, then `refresh`es
  /// the tree (a remote host's change events may lag the copy).
  func importItems(_ urls: [URL], into directory: URL, refresh: () async -> Void) async {
    let sources = FileExplorerImportTarget.importable(urls)
    guard !sources.isEmpty, !isImporting else { return }
    status = .copying(count: sources.count)
    do {
      _ = try await importer.importItems(sources, directory)
      status = nil
    } catch {
      status = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }
    await refresh()
  }

  func dismissStatus() {
    status = nil
  }
}
