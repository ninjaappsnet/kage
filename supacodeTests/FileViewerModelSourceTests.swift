import Foundation
import Testing

@testable import supacode

/// The viewer driven through a `FileSystemSource`, the way a remote host will
/// drive it: every read, size check and save goes through the source, and the
/// conflict banner comes from the source refusing a stale write.
@MainActor
struct FileViewerModelSourceTests {
  private static let file = URL(filePath: "/repo/notes.txt")

  @Test func opensTextThroughTheSource() async {
    let source = InMemoryFileSystemSource()
    source.addFile("/repo/notes.txt", "hello")
    let model = FileViewerModel(source: source)

    await model.open(Self.file)

    #expect(model.loadState == .loaded)
    #expect(model.text == "hello")
    #expect(model.displayName == "notes.txt")
    #expect(!model.isDirty)
    #expect(source.readPaths == ["/repo/notes.txt"])
  }

  @Test func aFileAboveTheEditableCapIsTooLargeAndNeverRead() async {
    let source = InMemoryFileSystemSource()
    let size = FileViewerFileType.maxEditableBytes + 1
    source.addFile("/repo/big.log", data: Data(repeating: 0x61, count: size))
    let model = FileViewerModel(source: source)

    await model.open(URL(filePath: "/repo/big.log"))

    #expect(model.loadState == .tooLarge(size))
    #expect(!model.isEditable)
    #expect(source.readPaths.isEmpty)
  }

  @Test func binaryContentIsNotLoadedAsText() async {
    let source = InMemoryFileSystemSource()
    source.addFile("/repo/blob.bin", data: Data([0x50, 0x00, 0x01]))
    let model = FileViewerModel(source: source)

    await model.open(URL(filePath: "/repo/blob.bin"))

    #expect(model.loadState == .binary)
    #expect(model.hasFile)
  }

  @Test func mediaIsPreviewedFromTheSourcesBytes() async {
    let bytes = Data([0x89, 0x50, 0x4E, 0x47])
    let source = InMemoryFileSystemSource()
    source.addFile("/repo/pic.png", data: bytes)
    let model = FileViewerModel(source: source)

    await model.open(URL(filePath: "/repo/pic.png"))

    #expect(model.loadState == .media(.image))
    #expect(model.mediaData == bytes)
    #expect(!model.isEditable)
  }

  @Test func savingWritesThroughTheSource() async {
    let source = InMemoryFileSystemSource()
    source.addFile("/repo/notes.txt", "before")
    let model = FileViewerModel(source: source)
    await model.open(Self.file)

    model.text = "after"
    await model.save()

    #expect(!model.isDirty)
    #expect(source.contents(of: "/repo/notes.txt") == "after")
    #expect(model.saveErrorMessage == nil)
  }

  @Test func aSecondSaveAfterOursIsNotAConflict() async {
    let source = InMemoryFileSystemSource()
    source.addFile("/repo/notes.txt", "one")
    let model = FileViewerModel(source: source)
    await model.open(Self.file)

    model.text = "two"
    await model.save()
    model.text = "three"
    await model.save()

    // Our own write moved the modification date; the next save must compare
    // against it, not against the date the file was opened with.
    #expect(!model.externalChangePending)
    #expect(source.contents(of: "/repo/notes.txt") == "three")
  }

  /// Saves are async, so a second ⌘S can land while the first write is in
  /// flight. It must not compare against the modification date the first write
  /// is about to replace, or the user's own save reads as an external change.
  @Test func anOverlappingSaveWaitsForTheOneInFlight() async {
    let source = InMemoryFileSystemSource()
    source.addFile("/repo/notes.txt", "before")
    let model = FileViewerModel(source: source)
    await model.open(Self.file)
    source.holdWrites()

    model.text = "first"
    let first = Task { await model.save() }
    while source.heldWriteCount < 1 { await Task.yield() }
    model.text = "second"
    let second = Task { await model.save() }
    // Let the second save run as far as it will before the first lands.
    for _ in 0..<20 { await Task.yield() }
    source.releaseWrites()
    await first.value
    await second.value

    #expect(!model.externalChangePending)
    #expect(!model.isDirty)
    #expect(source.contents(of: "/repo/notes.txt") == "second")
  }

  @Test func anExternalChangeBlocksTheSaveUntilOverwrite() async {
    let source = InMemoryFileSystemSource()
    source.addFile("/repo/notes.txt", "original")
    let model = FileViewerModel(source: source)
    await model.open(Self.file)

    source.modifyExternally("/repo/notes.txt", "external")
    model.text = "mine"
    await model.save()

    #expect(model.externalChangePending)
    #expect(source.contents(of: "/repo/notes.txt") == "external")
    #expect(model.isDirty)

    await model.overwriteSave()
    #expect(!model.externalChangePending)
    #expect(source.contents(of: "/repo/notes.txt") == "mine")
  }

  @Test func aDeletedFileIsAConflictNotASilentRecreate() async {
    let source = InMemoryFileSystemSource()
    source.addFile("/repo/notes.txt", "original")
    let model = FileViewerModel(source: source)
    await model.open(Self.file)

    source.remove("/repo/notes.txt")
    model.text = "mine"
    await model.save()

    #expect(model.externalChangePending)
    #expect(source.contents(of: "/repo/notes.txt") == nil)
  }

  @Test func aFailedWriteSurfacesItsMessage() async {
    let source = InMemoryFileSystemSource()
    source.addFile("/repo/notes.txt", "original")
    let model = FileViewerModel(source: source)
    await model.open(Self.file)

    source.setWriteFailure(.permission("Permission denied"))
    model.text = "mine"
    await model.save()

    #expect(model.saveErrorMessage == "Permission denied")
    #expect(model.isDirty)
  }

  @Test func aDroppedLinkOnOpenReadsAsUnreadableWithTheMessage() async {
    let source = InMemoryFileSystemSource()
    source.addFile("/repo/notes.txt", "hello")
    source.setFailure(.connection("Host unreachable"))
    let model = FileViewerModel(source: source)

    await model.open(Self.file)

    #expect(model.loadState == .unreadable("Host unreachable"))
  }

  @Test func aSlowEarlierOpenNeverOverwritesALaterOne() async {
    let source = InMemoryFileSystemSource()
    source.addFile("/repo/first.txt", "first")
    source.addFile("/repo/second.txt", "second")
    source.holdReads()
    let model = FileViewerModel(source: source)

    let first = Task { await model.open(URL(filePath: "/repo/first.txt")) }
    let second = Task { await model.open(URL(filePath: "/repo/second.txt")) }
    while source.heldReadCount < 2 { await Task.yield() }
    source.releaseReads()
    await first.value
    await second.value

    #expect(model.displayName == "second.txt")
    #expect(model.text == "second")
  }

  @Test func whileLoadingTheBufferIsNotEditableOrDirty() async {
    let source = InMemoryFileSystemSource()
    source.addFile("/repo/notes.txt", "hello")
    source.holdReads()
    let model = FileViewerModel(source: source)

    let opening = Task { await model.open(Self.file) }
    while source.heldReadCount < 1 { await Task.yield() }

    #expect(model.loadState == .loading)
    #expect(!model.isEditable)
    #expect(!model.isDirty)
    #expect(model.isPreparingContent)

    source.releaseReads()
    await opening.value
    #expect(model.loadState == .loaded)
  }

  @Test func closingMidLoadDiscardsTheLateResult() async {
    let source = InMemoryFileSystemSource()
    source.addFile("/repo/notes.txt", "hello")
    source.holdReads()
    let model = FileViewerModel(source: source)

    let opening = Task { await model.open(Self.file) }
    while source.heldReadCount < 1 { await Task.yield() }
    model.close()
    source.releaseReads()
    await opening.value

    #expect(model.loadState == .empty)
    #expect(!model.hasFile)
  }

  /// A source that cannot write without suspending cannot satisfy the close
  /// path's synchronous answer; it starts the save and keeps the tab open, so
  /// nothing is lost.
  @Test func savingBeforeCloseOnARemoteSourceKeepsTheTabOpen() async {
    let source = InMemoryFileSystemSource()
    source.addFile("/repo/notes.txt", "before")
    let model = FileViewerModel(source: source)
    await model.open(Self.file)
    model.text = "after"

    #expect(model.saveBeforeClose() == false)
  }

  @Test func exposesItsSourceForThePreview() {
    let source = InMemoryFileSystemSource()
    let model = FileViewerModel(source: source)
    #expect(model.source.id == source.id)
    #expect(!model.isLocal)
    #expect(FileViewerModel().isLocal)
  }
}
