import Foundation
import Testing

@testable import supacode

/// Pure classification of FSEvents directory events against a watch set.
nonisolated struct RemoteFileWatchSetTests {
  private static func entry(_ path: String, canonical: String? = nil, gitDirectory: String? = nil)
    -> RemoteFileWatchEntry
  {
    RemoteFileWatchEntry(
      requested: path,
      canonical: canonical ?? path,
      isDirectory: !path.hasSuffix(".txt"),
      gitDirectory: gitDirectory
    )
  }

  @Test func streamsOnlyTheTopMostDirectoriesAndLinkedGitDirectories() {
    let set = RemoteFileWatchSet(entries: [
      Self.entry("/repo", gitDirectory: "/repo/.git"),
      Self.entry("/repo/src"),
      Self.entry("/repo/src/deep"),
      Self.entry("/wt", gitDirectory: "/repo/.git/worktrees/wt"),
      Self.entry("/other/notes.txt"),
    ])
    #expect(set.streamPaths == ["/other", "/repo", "/wt"])
    #expect(set.roots == ["/other/notes.txt", "/repo", "/wt"])
    #expect(set.gitDirectories == ["/repo/.git", "/repo/.git/worktrees/wt"])
  }

  @Test func aDirectoryEventReportsWatchedDirectoriesAndWatchedFilesInIt() {
    let set = RemoteFileWatchSet(entries: [
      Self.entry("/repo"),
      Self.entry("/repo/src"),
      Self.entry("/repo/src/main.txt"),
    ])
    #expect(
      set.classify([RemoteFileFSEvent(path: "/repo/src/", flags: [], id: 1)])
        == RemoteFileEventClassification(changed: ["/repo/src", "/repo/src/main.txt"], treeRoots: ["/repo"])
    )
    // An unexpanded directory still dirties the tree, but no listing.
    #expect(
      set.classify([RemoteFileFSEvent(path: "/repo/build/", flags: [], id: 2)])
        == RemoteFileEventClassification(treeRoots: ["/repo"])
    )
    #expect(set.classify([RemoteFileFSEvent(path: "/elsewhere", flags: [], id: 3)]) == RemoteFileEventClassification())
  }

  @Test func eventsAreReportedInTheRequestedSpelling() {
    let set = RemoteFileWatchSet(entries: [
      Self.entry("/tmp/repo", canonical: "/private/tmp/repo"),
      Self.entry("/tmp/repo/src", canonical: "/private/tmp/repo/src"),
    ])
    #expect(set.streamPaths == ["/private/tmp/repo"])
    #expect(
      set.classify([
        RemoteFileFSEvent(path: "/private/tmp/repo/src", flags: [], id: 1),
        RemoteFileFSEvent(path: "/private/tmp/repo/src/x", flags: .mustScanSubDirs, id: 2),
      ])
        == RemoteFileEventClassification(
          changed: ["/tmp/repo/src"],
          treeRoots: ["/tmp/repo"],
          rescans: ["/tmp/repo/src/x"]
        )
    )
  }

  @Test func gitInternalsAreIgnoredExceptTheGitDirectoryItself() {
    let set = RemoteFileWatchSet(entries: [
      Self.entry("/repo", gitDirectory: "/repo/.git"),
      Self.entry("/wt", gitDirectory: "/repo/.git/worktrees/wt"),
    ])
    #expect(set.classify([RemoteFileFSEvent(path: "/repo/.git/objects/ab", flags: [], id: 1)]).isEmpty)
    #expect(set.classify([RemoteFileFSEvent(path: "/repo/.git/refs/heads", flags: [], id: 2)]).isEmpty)
    // The git directory itself holds HEAD and index: the watcher checks those.
    #expect(
      set.classify([RemoteFileFSEvent(path: "/repo/.git/", flags: [], id: 3)])
        == RemoteFileEventClassification(gitDirectories: ["/repo/.git"])
    )
    #expect(
      set.classify([RemoteFileFSEvent(path: "/repo/.git/worktrees/wt", flags: [], id: 4)])
        == RemoteFileEventClassification(gitDirectories: ["/repo/.git/worktrees/wt"])
    )
    #expect(set.roots(forGitDirectory: "/repo/.git/worktrees/wt") == ["/wt"])
  }

  @Test func droppedEventsAndRootChangesAskForARescan() {
    let set = RemoteFileWatchSet(entries: [Self.entry("/a"), Self.entry("/b")])
    #expect(
      set.classify([RemoteFileFSEvent(path: "/", flags: .kernelDropped, id: 1)])
        == RemoteFileEventClassification(rescans: ["/a", "/b"])
    )
    #expect(
      set.classify([RemoteFileFSEvent(path: "/a", flags: .rootChanged, id: 2)])
        == RemoteFileEventClassification(rescans: ["/a"])
    )
    #expect(set.classify([RemoteFileFSEvent(path: "/a", flags: .historyDone, id: 3)]).isEmpty)
  }

  @Test func liveResolutionCanonicalizesAndFindsLinkedWorktreeGitDirectories() throws {
    let scratch = try RemoteFileScratchDirectory()
    defer { scratch.remove() }
    let main = try scratch.makeDirectory("main")
    try scratch.makeDirectory("main/.git/worktrees/wt")
    let linked = try scratch.makeDirectory("wt")
    try scratch.makeFile("wt/.git", contents: "gitdir: \(main)/.git/worktrees/wt\n")
    let file = try scratch.makeFile("main/a.txt")
    let symlinked = scratch.appending("alias")
    try FileManager.default.createSymbolicLink(atPath: symlinked, withDestinationPath: "main")

    #expect(
      RemoteFileWatchEntry.resolve(main)
        == RemoteFileWatchEntry(requested: main, canonical: main, isDirectory: true, gitDirectory: main + "/.git")
    )
    #expect(RemoteFileWatchEntry.resolve(linked)?.gitDirectory == main + "/.git/worktrees/wt")
    #expect(RemoteFileWatchEntry.resolve(file)?.isDirectory == false)
    #expect(RemoteFileWatchEntry.resolve(symlinked)?.canonical == main)
    #expect(RemoteFileWatchEntry.resolve(symlinked)?.requested == symlinked)
    #expect(RemoteFileWatchEntry.resolve(scratch.appending("missing")) == nil)
    #expect(RemoteFileWatchEntry.resolve(scratch.path + "/main/")?.requested == main)
  }
}
