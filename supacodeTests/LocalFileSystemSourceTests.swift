import Foundation
import Testing

@testable import supacode

/// This Mac's disk behind the `FileSystemSource` seam. Behavior must match what
/// the explorer and viewer did against `FileManager` directly: hidden files on
/// request, a symlinked directory listed as a link, the size cap checked before
/// reading, the conflict rule and the symlink-preserving save.
struct LocalFileSystemSourceTests {
  private static func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "local-source-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Waits through `terminationHandler`, never `waitUntilExit`, which would spin
  /// the run loop and let the test host re-enter.
  private static func touchFromAnotherProcess(_ url: URL) async throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/touch")
    process.arguments = [url.path(percentEncoded: false)]
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      process.terminationHandler = { _ in continuation.resume() }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume()
      }
    }
  }

  @Test func listsEntriesWithKindsAndHonorsHiddenFiles() async throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("a".utf8).write(to: directory.appending(path: "a.txt"))
    try Data().write(to: directory.appending(path: ".env"))
    try FileManager.default.createDirectory(at: directory.appending(path: "sub"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: directory.appending(path: "link"),
      withDestinationURL: directory.appending(path: "sub")
    )
    let source = LocalFileSystemSource()

    let all = try await source.list(directory, showsHiddenFiles: true)
    let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    #expect(Set(byName.keys) == ["a.txt", ".env", "sub", "link"])
    #expect(byName["a.txt"]?.kind == .file)
    #expect(byName["a.txt"]?.size == 1)
    #expect(byName["sub"]?.kind == .directory)
    #expect(byName["link"]?.kind == .symlink)
    #expect(byName["link"]?.symlinkTargetKind == .directory)

    let visible = try await source.list(directory, showsHiddenFiles: false)
    #expect(!visible.contains { $0.name == ".env" })
  }

  @Test func listingAMissingDirectoryIsNotFound() async throws {
    let source = LocalFileSystemSource()
    do {
      _ = try await source.list(URL(filePath: "/nonexistent-\(UUID().uuidString)"), showsHiddenFiles: true)
      Issue.record("expected notFound")
    } catch {
      #expect(error.code == .notFound)
    }
  }

  @Test func readRefusesAboveTheCapWithTheSize() async throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "big.txt")
    try Data(repeating: 0x61, count: 64).write(to: file)
    let source = LocalFileSystemSource()

    do {
      _ = try await source.read(file, maxBytes: 10)
      Issue.record("expected tooLarge")
    } catch {
      #expect(error.code == .tooLarge)
      #expect(error.size == 64)
    }

    let result = try await source.read(file, maxBytes: 64)
    #expect(result.size == 64)
    #expect(result.modificationDate != nil)
  }

  @Test func writeRefusesAStaleExpectationAndAMissingFile() async throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "a.txt")
    try Data("original".utf8).write(to: file)
    let source = LocalFileSystemSource()
    let opened = try await source.stat(file).modificationDate

    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(120)],
      ofItemAtPath: file.path(percentEncoded: false)
    )
    do {
      try await source.write(Data("mine".utf8), to: file, expectedModificationDate: opened)
      Issue.record("expected conflict")
    } catch {
      #expect(error.code == .conflict)
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == "original")

    let written = try await source.write(Data("mine".utf8), to: file, expectedModificationDate: nil)
    #expect(written != nil)
    #expect(try String(contentsOf: file, encoding: .utf8) == "mine")

    try FileManager.default.removeItem(at: file)
    do {
      try await source.write(Data("again".utf8), to: file, expectedModificationDate: written)
      Issue.record("expected conflict for a deleted file")
    } catch {
      #expect(error.code == .conflict)
    }
  }

  @Test func writeKeepsASymlinkedFileALink() async throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appending(path: "real.txt")
    let link = directory.appending(path: "link.txt")
    try Data("before".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    try await LocalFileSystemSource().write(Data("after".utf8), to: link, expectedModificationDate: nil)

    let isLink = try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink
    #expect(isLink == true)
    #expect(try String(contentsOf: target, encoding: .utf8) == "after")
  }

  @Test func writeImmediatelyAppliesTheSameConflictRule() throws {
    let directory = try Self.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "a.txt")
    try Data("original".utf8).write(to: file)
    let source = LocalFileSystemSource()

    do {
      try source.writeImmediately(Data("x".utf8), to: file, expectedModificationDate: .distantPast)
      Issue.record("expected conflict")
    } catch {
      #expect(error.code == .conflict)
    }
    try source.writeImmediately(Data("x".utf8), to: file, expectedModificationDate: .distantFuture)
    #expect(try String(contentsOf: file, encoding: .utf8) == "x")
  }

  @Test(.timeLimit(.minutes(1)))
  func watchReportsAChangeUnderTheRoot() async throws {
    // Watch the real path, as the explorer does with a terminal's reported pwd;
    // the temporary directory sits behind the `/var` symlink.
    let directory = try Self.makeDirectory().resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = LocalFileSystemSource()
    let watch = source.watch(root: directory)
    var iterator = watch.events.makeAsyncIterator()

    // Another process writes: the stream ignores this process's own writes
    // (`kFSEventStreamCreateFlagIgnoreSelf`), so the viewer's saves never echo back.
    // It keeps writing until the event arrives: under full-suite load fseventsd can
    // drop a change made in the stream's first moments, and one write then waits
    // out the test's time limit.
    let writer = Task {
      for index in 0..<500 where !Task.isCancelled {
        try? await Self.touchFromAnotherProcess(directory.appending(path: "new-\(index).txt"))
      }
    }
    let event = await iterator.next()
    writer.cancel()

    #expect(event == .rescan(directory.standardizedFileURL))
  }

  @Test func gitStatusOfANonRepositoryIsNotGit() async {
    let source = LocalFileSystemSource(gitStatus: { _ in nil })
    do {
      _ = try await source.gitStatus(root: URL(filePath: "/tmp"))
      Issue.record("expected notGit")
    } catch {
      #expect(error.code == .notGit)
    }
  }

  @Test func gitStatusPassesTheSnapshotThrough() async throws {
    let snapshot = GitStatusSnapshot(statuses: ["a.txt": GitFileStatus(isUntracked: true)])
    let source = LocalFileSystemSource(gitStatus: { _ in snapshot })
    #expect(try await source.gitStatus(root: URL(filePath: "/tmp")) == snapshot)
  }

  @Test func isTheLocalSource() {
    let source = LocalFileSystemSource()
    #expect(source.isLocal)
    #expect(source.id == .local)
  }
}
