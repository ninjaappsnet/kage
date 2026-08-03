import Foundation
import Testing

@testable import supacode

@MainActor
struct FileViewerModelTests {
  private static func makeTempFile(name: String, contents: Data) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(
      path: "fview-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: name)
    try contents.write(to: url)
    return url
  }

  @Test func openLoadsTextAndIsNotDirty() throws {
    let url = try Self.makeTempFile(name: "a.txt", contents: Data("hello world".utf8))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let model = FileViewerModel()
    model.open(url)
    #expect(model.loadState == .loaded)
    #expect(model.text == "hello world")
    #expect(!model.isDirty)
    #expect(model.hasFile)
  }

  @Test func openMarksContentPreparingUntilTheViewReportsItRendered() throws {
    let url = try Self.makeTempFile(name: "a.txt", contents: Data("hello".utf8))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let model = FileViewerModel()
    model.open(url)
    // Rendering a large document blocks the main thread for seconds, and the
    // pane can't paint until it finishes. The flag lets the pane show a spinner
    // in an earlier frame instead of the click appearing to do nothing.
    #expect(model.isPreparingContent)
    model.contentDidRender()
    #expect(!model.isPreparingContent)
  }

  @Test func reopeningTheSameFileKeepsUnsavedEdits() throws {
    let url = try Self.makeTempFile(name: "a.txt", contents: Data("hello".utf8))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let model = FileViewerModel()
    model.open(url)
    model.contentDidRender()
    model.text = "edited, not saved"
    // Clicks queued up behind a slow render all land at once, so re-opening the
    // file already on screen must not discard the buffer; Reload from Disk is
    // the explicit way to throw it away.
    model.open(url)
    #expect(model.text == "edited, not saved")
    #expect(model.isDirty)

    model.reloadFromDisk()
    #expect(model.text == "hello")
  }

  @Test func editingMarksDirty() throws {
    let url = try Self.makeTempFile(name: "a.txt", contents: Data("hello".utf8))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let model = FileViewerModel()
    model.open(url)
    model.text = "hello, edited"
    #expect(model.isDirty)
  }

  @Test func saveWritesToDiskAndClearsDirty() throws {
    let url = try Self.makeTempFile(name: "a.txt", contents: Data("before".utf8))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let model = FileViewerModel()
    model.open(url)
    model.text = "after"
    model.save()
    #expect(!model.isDirty)
    #expect(try String(contentsOf: url, encoding: .utf8) == "after")
  }

  @Test func markdownFileOpensInRenderedMode() throws {
    let url = try Self.makeTempFile(name: "doc.md", contents: Data("# Heading\n\ntext".utf8))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let model = FileViewerModel()
    model.open(url)
    #expect(model.isMarkdown)
    #expect(model.mode == .rendered)
  }

  @Test func binaryFileIsRejected() throws {
    var bytes = Data("PNG".utf8)
    bytes.append(0)
    let url = try Self.makeTempFile(name: "image.bin", contents: bytes)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let model = FileViewerModel()
    model.open(url)
    #expect(model.loadState == .binary)
    // fileURL stays set so the pane shows the "can't preview" state, not nothing.
    #expect(model.hasFile)
  }

  @Test func externalChangeBlocksSaveUntilOverwrite() throws {
    let url = try Self.makeTempFile(name: "a.txt", contents: Data("original".utf8))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let model = FileViewerModel()
    model.open(url)

    // Simulate an external writer (e.g. an agent) changing the file after open.
    try "external".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(120)],
      ofItemAtPath: url.path
    )

    model.text = "mine"
    model.save()
    #expect(model.externalChangePending)
    // The external content must NOT be clobbered by a plain save.
    #expect(try String(contentsOf: url, encoding: .utf8) == "external")

    model.overwriteSave()
    #expect(!model.externalChangePending)
    #expect(try String(contentsOf: url, encoding: .utf8) == "mine")
  }

  @Test func deletedFileBlocksSave() throws {
    let url = try Self.makeTempFile(name: "a.txt", contents: Data("original".utf8))
    let dir = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: dir) }

    let model = FileViewerModel()
    model.open(url)
    try FileManager.default.removeItem(at: url)

    model.text = "mine"
    model.save()
    // A vanished file is a conflict, not a silent recreate.
    #expect(model.externalChangePending)
  }

  @Test func largeFileLoadsButDisablesHighlighting() throws {
    let big = Data(String(repeating: "x", count: 300_000).utf8)  // > 256KB highlight cap
    let url = try Self.makeTempFile(name: "big.txt", contents: big)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let model = FileViewerModel()
    model.open(url)
    #expect(model.loadState == .loaded)
    #expect(!model.shouldHighlightSyntax)
  }

  @Test func imageFileOpensAsMediaAndIsNotEditable() throws {
    // Classification is by extension; the bytes need not be a real image here.
    let url = try Self.makeTempFile(name: "pic.png", contents: Data([0x89, 0x50, 0x4E, 0x47]))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let model = FileViewerModel()
    model.open(url)
    #expect(model.loadState == .media(.image))
    #expect(!model.isEditable)
    #expect(!model.isDirty)
    #expect(model.hasFile)
  }

  @Test func pdfFileOpensAsMedia() throws {
    let url = try Self.makeTempFile(name: "doc.pdf", contents: Data("%PDF-1.4".utf8))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let model = FileViewerModel()
    model.open(url)
    #expect(model.loadState == .media(.pdf))
    #expect(!model.isEditable)
  }

  @Test func smallFileEnablesHighlighting() throws {
    let url = try Self.makeTempFile(name: "small.swift", contents: Data("let x = 1".utf8))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let model = FileViewerModel()
    model.open(url)
    #expect(model.shouldHighlightSyntax)
  }

  @Test func htmlFileOpensRenderedAndStaysEditable() throws {
    let url = try Self.makeTempFile(name: "report.html", contents: Data("<h1>Hi</h1>".utf8))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let model = FileViewerModel()
    model.open(url)
    #expect(model.isHTML)
    #expect(!model.isMarkdown)
    #expect(model.mode == .rendered)
    // Unlike media, HTML is still a text file: the raw tab must remain editable.
    #expect(model.loadState == .loaded)
    #expect(model.isEditable)
    #expect(model.language == "xml")
  }

  @Test func htmlOpensUntrustedEveryTime() throws {
    let trusted = try Self.makeTempFile(name: "a.html", contents: Data("<p>a</p>".utf8))
    let other = try Self.makeTempFile(name: "b.html", contents: Data("<p>b</p>".utf8))
    defer {
      try? FileManager.default.removeItem(at: trusted.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: other.deletingLastPathComponent())
    }

    let model = FileViewerModel()
    model.open(trusted)
    #expect(!model.isHTMLTrusted)
    model.trustHTML()
    #expect(model.isHTMLTrusted)

    // Trust is per-document: opening another file must not inherit it.
    model.open(other)
    #expect(!model.isHTMLTrusted)
  }

  @Test func nonHTMLFileClearsHTMLFlag() throws {
    let html = try Self.makeTempFile(name: "page.html", contents: Data("<p>x</p>".utf8))
    let swift = try Self.makeTempFile(name: "main.swift", contents: Data("let x = 1".utf8))
    defer {
      try? FileManager.default.removeItem(at: html.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: swift.deletingLastPathComponent())
    }

    let model = FileViewerModel()
    model.open(html)
    #expect(model.isHTML)
    model.open(swift)
    #expect(!model.isHTML)
    #expect(model.mode == .raw)
  }

  @Test func closeClearsHTMLState() throws {
    let url = try Self.makeTempFile(name: "report.html", contents: Data("<h1>Hi</h1>".utf8))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let model = FileViewerModel()
    model.open(url)
    model.trustHTML()
    model.close()
    #expect(!model.isHTML)
    #expect(!model.isHTMLTrusted)
  }

  @Test func binaryFileWithHTMLExtensionIsNotPreviewed() throws {
    let url = try Self.makeTempFile(name: "corrupt.html", contents: Data([0x00, 0x01, 0x02]))
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let model = FileViewerModel()
    model.open(url)
    #expect(model.loadState == .binary)
    #expect(!model.isHTML)
  }
}
