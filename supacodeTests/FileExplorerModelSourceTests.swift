import Foundation
import Testing

@testable import supacode

/// The explorer driven through a `FileSystemSource` it does not own, the way a
/// remote host will drive it: listing is lazy (only expanded directories), change
/// events re-list only what they name, and a dropped link is a message rather
/// than an empty tree.
@MainActor
struct FileExplorerModelSourceTests {
  private static let root = URL(filePath: "/repo", directoryHint: .isDirectory)

  private static func makeSource() -> InMemoryFileSystemSource {
    let source = InMemoryFileSystemSource()
    source.addFile("/repo/a.txt", "a")
    source.addFile("/repo/.env", "SECRET=1")
    source.addFile("/repo/sub/inner.txt", "inner")
    source.addFile("/repo/sub/deeper/leaf.txt", "leaf")
    return source
  }

  private static func names(_ model: FileExplorerModel) -> [String] {
    model.rows.map(\.node.name)
  }

  @Test func listsNothingUntilLoadedThenOnlyTheRoot() async {
    let source = Self.makeSource()
    let model = FileExplorerModel(rootURL: Self.root, source: source)
    // Construction does no I/O: the panel's task starts it.
    #expect(!model.hasLoaded)
    #expect(source.listedPaths.isEmpty)

    await model.reload()

    #expect(model.hasLoaded)
    #expect(Self.names(model) == ["sub", ".env", "a.txt"])
    // Lazy: a collapsed directory is never listed.
    #expect(source.listedPaths == ["/repo"])
  }

  @Test func expandingListsTheDirectoryAndCollapsingDropsIt() async throws {
    let source = Self.makeSource()
    let model = FileExplorerModel(rootURL: Self.root, source: source)
    await model.reload()
    let sub = try #require(model.rows.first { $0.node.name == "sub" }?.node)

    await model.toggleExpansion(sub)
    #expect(model.isExpanded(sub.url))
    #expect(Self.names(model) == ["sub", "deeper", "inner.txt", ".env", "a.txt"])
    #expect(model.rows.first { $0.node.name == "inner.txt" }?.depth == 1)

    await model.toggleExpansion(sub)
    #expect(!model.isExpanded(sub.url))
    #expect(Self.names(model) == ["sub", ".env", "a.txt"])
  }

  @Test func activatingAFileOpensItAndADirectoryExpands() async throws {
    let source = Self.makeSource()
    let model = FileExplorerModel(rootURL: Self.root, source: source)
    var opened: [URL] = []
    model.onOpenFile = { opened.append($0) }
    await model.reload()

    let file = try #require(model.rows.first { $0.node.name == "a.txt" }?.node)
    await model.activate(file)
    #expect(opened == [file.url])
    #expect(model.selectedURL == file.url)

    let sub = try #require(model.rows.first { $0.node.name == "sub" }?.node)
    await model.activate(sub)
    #expect(model.isExpanded(sub.url))
  }

  @Test func hidingHiddenFilesRelists() async {
    let source = Self.makeSource()
    let model = FileExplorerModel(rootURL: Self.root, source: source)
    await model.reload()

    await model.setShowsHiddenFiles(false)

    #expect(!model.showsHiddenFiles)
    #expect(Self.names(model) == ["sub", "a.txt"])
  }

  @Test func aChangedEventRelistsOnlyTheNamedDirectory() async throws {
    let source = Self.makeSource()
    let model = FileExplorerModel(rootURL: Self.root, source: source)
    await model.reload()
    let sub = try #require(model.rows.first { $0.node.name == "sub" }?.node)
    await model.toggleExpansion(sub)
    let listedBefore = source.listedPaths

    source.addFile("/repo/sub/new.txt", "new")
    await model.handle(.changed(directories: [sub.url]))

    #expect(model.rows.contains { $0.node.name == "new.txt" && $0.depth == 1 })
    #expect(Array(source.listedPaths.dropFirst(listedBefore.count)) == ["/repo/sub"])
  }

  @Test func aChangedEventForAnUnwatchedDirectoryIsIgnored() async {
    let source = Self.makeSource()
    let model = FileExplorerModel(rootURL: Self.root, source: source)
    await model.reload()
    let listedBefore = source.listedPaths.count

    await model.handle(.changed(directories: [URL(filePath: "/repo/sub")]))

    #expect(source.listedPaths.count == listedBefore)
  }

  @Test func aRescanPrunesAVanishedExpandedDirectoryAndSelection() async throws {
    let source = Self.makeSource()
    let model = FileExplorerModel(rootURL: Self.root, source: source)
    await model.reload()
    let sub = try #require(model.rows.first { $0.node.name == "sub" }?.node)
    await model.toggleExpansion(sub)
    let inner = try #require(model.rows.first { $0.node.name == "inner.txt" }?.node)
    model.select(inner)

    source.remove("/repo/sub")
    await model.handle(.rescan(Self.root))

    #expect(!model.isExpanded(sub.url))
    #expect(model.selectedURL == nil)
    #expect(Self.names(model) == [".env", "a.txt"])
  }

  @Test func runListsThenFollowsWatchEventsUntilTheStreamEnds() async {
    let source = Self.makeSource()
    source.scriptWatch([
      .init(before: { source.addFile("/repo/b.txt", "b") }, event: .changed(directories: [Self.root]))
    ])
    let model = FileExplorerModel(rootURL: Self.root, source: source)

    await model.run()

    #expect(Self.names(model) == ["sub", ".env", "a.txt", "b.txt"])
    #expect(source.watchedDirectorySets.first == [Self.root.standardizedFileURL])
  }

  @Test func expandingUpdatesTheWatchedSetWhileRunning() async throws {
    let source = Self.makeSource()
    let model = FileExplorerModel(rootURL: Self.root, source: source)
    await model.reload()
    let sub = try #require(model.rows.first { $0.node.name == "sub" }?.node)
    // A step runs only once the previous event was handled, after the initial
    // listing, so expanding from it is what a user expanding mid-watch looks like.
    source.scriptWatch([
      .init(before: { await model.toggleExpansion(sub) }, event: .treeChanged(root: Self.root))
    ])

    await model.run()

    #expect(source.watchedDirectorySets.last == [Self.root.standardizedFileURL, sub.url])
  }

  @Test func aDroppedLinkKeepsTheTreeAndReportsIt() async {
    let source = Self.makeSource()
    let model = FileExplorerModel(rootURL: Self.root, source: source)
    await model.reload()

    source.setFailure(.connection("Host unreachable"))
    await model.reload()

    #expect(Self.names(model) == ["sub", ".env", "a.txt"])
    #expect(model.connectionErrorMessage == "Host unreachable")

    source.setFailure(nil)
    await model.reload()
    #expect(model.connectionErrorMessage == nil)
  }

  @Test func aMissingRootReadsAsAnEmptyFolderLikeBefore() async {
    let source = InMemoryFileSystemSource()
    let model = FileExplorerModel(rootURL: URL(filePath: "/gone"), source: source)

    await model.reload()

    #expect(model.hasLoaded)
    #expect(model.rows.isEmpty)
    #expect(model.connectionErrorMessage == nil)
  }

  @Test func remoteSourcesOfferNoFinderActions() {
    let model = FileExplorerModel(rootURL: Self.root, source: InMemoryFileSystemSource())
    #expect(!model.isLocal)
    #expect(FileExplorerModel(rootURL: Self.root).isLocal)
  }
}
