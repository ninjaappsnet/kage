import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

/// The viewer side against the real host side: `RemoteKageServeSession` runs the
/// bundled CLI's `host serve` through the injectable launcher (locally, instead
/// of over ssh) and `RemoteFileSystemSource` lists, reads, writes and watches
/// through it.
@Suite(.serialized)
nonisolated struct RemoteKageServeEndToEndTests {
  @Test(.timeLimit(.minutes(2)))
  func browsesEditsConflictsAndFollowsChangesThroughTheRealCLI() async throws {
    let executableURL = try #require(Bundle.main.resourceURL?.appending(path: "bin/supacode"))
    try #require(FileManager.default.fileExists(atPath: executableURL.path(percentEncoded: false)))
    let scratch = try RemoteFileScratchDirectory()
    defer { scratch.remove() }
    try scratch.makeFile("notes.md", contents: "# Notes")
    let watched = try scratch.makeDirectory("watched")

    let session = RemoteKageServeSession(
      launcher: .process(executableURL: executableURL, arguments: RemoteKageServeCommand.arguments),
      clock: ContinuousClock()
    )
    let source = RemoteFileSystemSource(hostID: UUID(), session: session)
    await session.retain()
    defer { Task { await session.shutdown() } }

    let root = URL(filePath: scratch.path, directoryHint: .isDirectory)
    let entries = try await source.list(root, showsHiddenFiles: false)
    #expect(Set(entries.map(\.name)) == ["notes.md", "watched"])
    #expect(entries.first { $0.name == "watched" }?.kind == .directory)
    #expect(await session.status == .connected)

    let notes = root.appending(path: "notes.md")
    let read = try await source.read(notes, maxBytes: 1024)
    #expect(read.data == Data("# Notes".utf8))

    // Save over the version that was opened: accepted.
    let saved = try await source.write(
      Data("# Edited".utf8), to: notes, expectedModificationDate: read.modificationDate)
    #expect(try Data(contentsOf: notes) == Data("# Edited".utf8))
    #expect(saved != nil)

    // Someone else edits it: the next save from the stale buffer is refused.
    try Data("# Theirs".utf8).write(to: notes)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: notes.path(percentEncoded: false))
    do {
      try await source.write(Data("# Mine".utf8), to: notes, expectedModificationDate: saved)
      Issue.record("expected a conflict")
    } catch {
      #expect(error.code == .conflict)
    }
    #expect(try Data(contentsOf: notes) == Data("# Theirs".utf8))

    // A watched directory reports a new entry.
    let watch = source.watch(root: root)
    let events = EventRecorder(watch.events)
    defer { events.cancel() }
    let watchedURL = URL(filePath: watched, directoryHint: .isDirectory)
    watch.setWatchedDirectories([watchedURL])
    // Give the host's watch request time to land before touching the directory.
    _ = try await source.stat(watchedURL)
    var created = false
    let changed = await serveEventually(timeout: .seconds(30)) {
      if !created {
        created = true
        _ = try? scratch.makeFile("watched/new.txt", contents: "x")
      }
      return events.events.value.contains { event in
        if case .changed(let directories) = event {
          return directories.contains { $0.path(percentEncoded: false).hasPrefix(watched) }
        }
        return false
      }
    }
    #expect(changed)
  }
}
