import Foundation
import Testing

@testable import supacode

/// The explorer's highlighted row exists to show which file the viewer has open.
/// It therefore mirrors the viewer rather than tracking clicks on its own — closing
/// the viewer has to clear it, or a row stays highlighted with nothing behind it.
@MainActor
struct FileExplorerSelectionSyncTests {
  private static func makeTempDir(files: [String]) throws -> URL {
    let fileManager = FileManager.default
    let base = fileManager.temporaryDirectory.appending(
      path: "fexp-sync-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    for file in files {
      try Data().write(to: base.appending(path: file))
    }
    return base
  }

  @Test func closingTheViewerClearsTheSelection() throws {
    let root = try Self.makeTempDir(files: ["a.md"])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = FileExplorerModel(rootURL: root)
    let file = root.appending(path: "a.md")

    model.syncSelection(toOpenFile: file)
    #expect(model.selectedURL == file)

    model.syncSelection(toOpenFile: nil)
    #expect(model.selectedURL == nil)
  }

  @Test func openingADifferentFileMovesTheSelection() throws {
    let root = try Self.makeTempDir(files: ["a.md", "b.swift"])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = FileExplorerModel(rootURL: root)

    model.syncSelection(toOpenFile: root.appending(path: "a.md"))
    model.syncSelection(toOpenFile: root.appending(path: "b.swift"))
    #expect(model.selectedURL == root.appending(path: "b.swift"))
  }

  @Test func syncingTheSameFileTwiceIsStable() throws {
    let root = try Self.makeTempDir(files: ["a.md"])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = FileExplorerModel(rootURL: root)
    let file = root.appending(path: "a.md")

    model.syncSelection(toOpenFile: file)
    model.syncSelection(toOpenFile: file)
    #expect(model.selectedURL == file)
  }
}
