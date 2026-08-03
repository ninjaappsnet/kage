import Foundation
import Testing

@testable import supacode

/// Opening a large document blocks the main thread inside the renderer's first
/// layout — measured at 2.7s for one real file. Nothing paints during that, so
/// the pane draws a spinner in an earlier frame and reports back once the real
/// renderer has mounted. These cover the contract the pane drives; the deferral
/// itself is a SwiftUI mount ordering, checked in the running app.
@MainActor
struct FileViewerLoadingFeedbackTests {
  private static func makeFile(name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("viewer-feedback-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(name)
    try "# Title\n\nbody\n".write(to: file, atomically: true, encoding: .utf8)
    return file
  }

  @Test func openingAnotherFileShowsTheSpinnerAgain() throws {
    let first = try Self.makeFile(name: "one.md")
    let second = try Self.makeFile(name: "two.md")
    defer {
      try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
    }

    let model = FileViewerModel()
    model.open(first)
    model.contentDidRender()
    #expect(!model.isPreparingContent)

    // The pane is reused rather than rebuilt, and the next document may well be
    // the slow one, so the spinner has to come back for it.
    model.open(second)
    #expect(model.isPreparingContent)
  }

  @Test func closingClearsTheSpinnerState() throws {
    let file = try Self.makeFile(name: "one.md")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let model = FileViewerModel()
    model.open(file)
    // Closing mid-load must not strand the busy cursor and the disabled explorer,
    // which both key off this flag.
    model.close()
    #expect(!model.isPreparingContent)
  }

  @Test func reloadFromDiskShowsTheSpinner() throws {
    let file = try Self.makeFile(name: "one.md")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let model = FileViewerModel()
    model.open(file)
    model.contentDidRender()
    model.reloadFromDisk()
    #expect(model.isPreparingContent)
  }
}
