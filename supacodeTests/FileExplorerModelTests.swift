import Foundation
import Testing

@testable import supacode

@MainActor
struct FileExplorerModelTests {
  /// Creates a unique temp directory containing the given top-level file names
  /// (and optional `subdir/childFile`), returning its URL. The caller removes it.
  private static func makeTempDir(
    files: [String] = [],
    subdir: (name: String, child: String)? = nil
  ) throws -> URL {
    let fileManager = FileManager.default
    let base = fileManager.temporaryDirectory.appending(
      path: "fexp-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    for file in files {
      try Data().write(to: base.appending(path: file))
    }
    if let subdir {
      let dir = base.appending(path: subdir.name, directoryHint: .isDirectory)
      try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
      try Data().write(to: dir.appending(path: subdir.child))
    }
    return base
  }

  @Test func updateRootSwitchesToNewDirectoryContents() throws {
    let dirA = try Self.makeTempDir(files: ["a1.txt", "a2.txt"])
    let dirB = try Self.makeTempDir(files: ["b1.txt"])
    defer { try? FileManager.default.removeItem(at: dirA); try? FileManager.default.removeItem(at: dirB) }

    let model = FileExplorerModel(rootURL: dirA)
    #expect(model.rows.map(\.node.name) == ["a1.txt", "a2.txt"])

    model.updateRoot(dirB)
    #expect(model.rootURL == dirB.standardizedFileURL)
    #expect(model.rows.map(\.node.name) == ["b1.txt"])
  }

  @Test func updateRootClearsExpansionAndSelection() throws {
    let dirA = try Self.makeTempDir(files: ["root.txt"], subdir: (name: "sub", child: "inner.txt"))
    let dirB = try Self.makeTempDir(files: ["b1.txt"])
    defer { try? FileManager.default.removeItem(at: dirA); try? FileManager.default.removeItem(at: dirB) }

    let model = FileExplorerModel(rootURL: dirA)
    // Expand the directory node the model actually listed (its URL representation
    // is what keys expansion); a hand-built URL would not match.
    let subNode = try #require(model.rows.first { $0.node.name == "sub" }?.node)
    model.toggleExpansion(subNode)
    model.selectedURL = subNode.url
    #expect(model.isExpanded(subNode.url))
    #expect(model.rows.contains { $0.node.name == "inner.txt" })

    model.updateRoot(dirB)
    #expect(!model.isExpanded(subNode.url))
    #expect(model.selectedURL == nil)
    #expect(model.rows.map(\.node.name) == ["b1.txt"])
  }

  @Test func updateRootToSameDirectoryIsNoOp() throws {
    let dirA = try Self.makeTempDir(files: ["a1.txt"])
    defer { try? FileManager.default.removeItem(at: dirA) }

    let model = FileExplorerModel(rootURL: dirA)
    let marker = dirA.standardizedFileURL.appending(path: "a1.txt")
    model.selectedURL = marker

    // Re-rooting at the current directory (un-standardized input) must short-circuit
    // and preserve selection rather than reset the tree.
    model.updateRoot(dirA)
    #expect(model.selectedURL == marker)
  }
}
