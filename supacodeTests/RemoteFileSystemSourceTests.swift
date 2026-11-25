import Clocks
import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

@Suite(.serialized)
nonisolated struct RemoteFileSystemSourceTests {
  private struct Harness {
    let session: RemoteKageServeSession
    let channel: FakeServeChannel
    let source: RemoteFileSystemSource
  }

  private func harness() async throws -> Harness {
    let launcher = FakeServeLauncher()
    let session = RemoteKageServeSession(launcher: launcher.launcher, clock: TestClock())
    await session.retain()
    let channel = try await launcher.channel(0)
    try await channel.answerHello()
    let hostID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
    let source = RemoteFileSystemSource(hostID: hostID, session: session)
    return Harness(session: session, channel: channel, source: source)
  }

  private static func date(_ milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
  }

  @Test func idNamesTheHostAndIsNotLocal() {
    let hostID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
    #expect(
      RemoteFileSystemSource.sourceID(hostID: hostID).rawValue == "remote-kage:00000000-0000-0000-0000-0000000000AB")
    let source = RemoteFileSystemSource(
      hostID: hostID,
      session: RemoteKageServeSession(launcher: FakeServeLauncher().launcher, clock: TestClock())
    )
    #expect(!source.isLocal)
    #expect(source.id == RemoteFileSystemSource.sourceID(hostID: hostID))
  }

  @Test func pathsAreCarriedVerbatimNotResolvedAgainstThisMac() {
    // `/private/var` exists here, so Foundation's standardizing would drop the
    // `/private` prefix; the path names a file on the host and must not change.
    #expect(
      RemoteFileSystemSource.path(URL(filePath: "/private/var/x/", directoryHint: .isDirectory)) == "/private/var/x")
    #expect(RemoteFileSystemSource.path(URL(filePath: "/")) == "/")
  }

  @Test func listMapsKindsSizesAndMilliseconds() async throws {
    let harness = try await harness()
    async let entries = harness.source.list(
      URL(filePath: "/w/src/", directoryHint: .isDirectory), showsHiddenFiles: true)
    let request = try await harness.channel.request(.list)
    #expect(request.path == "/w/src")
    #expect(request.showHidden == true)
    harness.channel.respond(
      to: request.id,
      with: RemoteFileListResult(entries: [
        .init(name: "a.swift", kind: .file, size: 12, mtime: 1_700_000_000_123),
        .init(name: "lib", kind: .dir, size: 64, mtime: 5),
        .init(name: "link", kind: .symlink, size: 3, mtime: 6, targetKind: .dir),
        .init(name: "dangling", kind: .symlink, size: 3, mtime: 7),
      ])
    )
    let result = try await entries
    #expect(
      result == [
        FileSystemEntry(name: "a.swift", kind: .file, size: 12, modificationDate: Self.date(1_700_000_000_123)),
        FileSystemEntry(name: "lib", kind: .directory, size: 64, modificationDate: Self.date(5)),
        FileSystemEntry(
          name: "link", kind: .symlink, size: 3, modificationDate: Self.date(6), symlinkTargetKind: .directory),
        FileSystemEntry(name: "dangling", kind: .symlink, size: 3, modificationDate: Self.date(7)),
      ])
  }

  @Test func statAndReadCarryBytesAndModificationDates() async throws {
    let harness = try await harness()
    async let info = harness.source.stat(URL(filePath: "/w/a.txt"))
    let stat = try await harness.channel.request(.stat)
    harness.channel.respond(to: stat.id, with: RemoteFileStatResult(kind: .file, size: 5, mtime: 42))
    #expect(try await info == FileSystemItemInfo(kind: .file, size: 5, modificationDate: Self.date(42)))

    async let read = harness.source.read(URL(filePath: "/w/a.txt"), maxBytes: 100)
    let readRequest = try await harness.channel.request(.read)
    #expect(readRequest.maxBytes == 100)
    harness.channel.respond(
      to: readRequest.id, with: RemoteFileReadResult(data: Data("hello".utf8), size: 5, mtime: 43))
    #expect(try await read == FileSystemReadResult(data: Data("hello".utf8), size: 5, modificationDate: Self.date(43)))
  }

  @Test func tooLargeCarriesTheSize() async throws {
    let harness = try await harness()
    async let read = harness.source.read(URL(filePath: "/w/big.bin"), maxBytes: 10)
    let request = try await harness.channel.request(.read)
    harness.channel.fail(request.id, RemoteFileError(code: .tooLarge, message: "File is too large", size: 99))
    do {
      _ = try await read
      Issue.record("expected tooLarge")
    } catch let error as FileSystemSourceError {
      #expect(error.code == .tooLarge)
      #expect(error.size == 99)
    }
  }

  @Test func writeSendsTheOpenedMillisecondsAndReturnsTheNewDate() async throws {
    let harness = try await harness()
    let opened = Self.date(1_700_000_000_123)
    async let written = harness.source.write(
      Data("new".utf8), to: URL(filePath: "/w/a.txt"), expectedModificationDate: opened)
    let request = try await harness.channel.request(.write)
    #expect(request.expectedMtime == 1_700_000_000_123)
    #expect(request.data == Data("new".utf8))
    harness.channel.respond(to: request.id, with: RemoteFileWriteResult(mtime: 1_700_000_000_999))
    #expect(try await written == Self.date(1_700_000_000_999))
  }

  @Test func conflictCarriesTheCurrentDate() async throws {
    let harness = try await harness()
    async let written = harness.source.write(
      Data("x".utf8), to: URL(filePath: "/w/a.txt"), expectedModificationDate: Self.date(1))
    let request = try await harness.channel.request(.write)
    harness.channel.fail(request.id, RemoteFileError(code: .conflict, message: "changed", mtime: 2))
    do {
      _ = try await written
      Issue.record("expected conflict")
    } catch let error as FileSystemSourceError {
      #expect(error == .conflict(currentModificationDate: Self.date(2)))
    }
  }

  @Test(
    arguments: [
      (RemoteFileErrorCode.notFound, FileSystemSourceError.Code.notFound),
      (.permission, .permission),
      (.notGit, .notGit),
      (.badRequest, .badRequest),
      (.inputOutput, .ioFailure),
    ])
  func mapsErrorCodes(remote: RemoteFileErrorCode, local: FileSystemSourceError.Code) async throws {
    let harness = try await harness()
    async let info = harness.source.stat(URL(filePath: "/w/x"))
    let request = try await harness.channel.request(.stat)
    harness.channel.fail(request.id, RemoteFileError(code: remote, message: "host says no"))
    do {
      _ = try await info
      Issue.record("expected \(remote)")
    } catch let error as FileSystemSourceError {
      #expect(error.code == local)
      #expect(error.message == "host says no")
    }
  }

  @Test func aDroppedLinkIsAConnectionError() async throws {
    let harness = try await harness()
    async let info = harness.source.stat(URL(filePath: "/w/x"))
    _ = try await harness.channel.request(.stat)
    harness.channel.exit(255, diagnostics: "ssh: Broken pipe")
    do {
      _ = try await info
      Issue.record("expected a connection error")
    } catch let error as FileSystemSourceError {
      #expect(error.code == .connection)
      #expect(error.message == "Can't reach the host: Broken pipe")
    }
  }

  @Test func anOldHostReadsAsAConnectionErrorThatSaysToUpdate() async throws {
    let launcher = FakeServeLauncher()
    let session = RemoteKageServeSession(launcher: launcher.launcher, clock: TestClock())
    let source = RemoteFileSystemSource(hostID: UUID(), session: session)
    async let listing = source.list(URL(filePath: "/"), showsHiddenFiles: false)
    try await launcher.channel(0).exit(64, diagnostics: "Error: Unexpected argument 'serve'")
    do {
      _ = try await listing
      Issue.record("expected a connection error")
    } catch let error as FileSystemSourceError {
      #expect(error.code == .connection)
      #expect(error.message == RemoteKageServeFailure.needsUpdate.message)
    }
  }

  @Test func gitStatusParsesPorcelainV2() async throws {
    let harness = try await harness()
    async let status = harness.source.gitStatus(root: URL(filePath: "/w/"))
    let request = try await harness.channel.request(.gitStatus)
    #expect(request.root == "/w")
    let porcelain = "1 .M N... 100644 100644 100644 abc abc src/a.swift\0? new.txt\0"
    harness.channel.respond(to: request.id, with: RemoteFileGitStatusResult(porcelain: porcelain))
    #expect(try await status == GitStatusSnapshot.parse(porcelainV2: porcelain))
  }

  @Test func watchPublishesTheWatchSetAndMapsEvents() async throws {
    let harness = try await harness()
    let watch = harness.source.watch(root: URL(filePath: "/w/", directoryHint: .isDirectory))
    let events = EventRecorder(watch.events)
    defer { events.cancel() }
    watch.setWatchedDirectories([
      URL(filePath: "/w/", directoryHint: .isDirectory), URL(filePath: "/w/src/", directoryHint: .isDirectory),
    ])
    let request = try await harness.channel.request(.watch)
    #expect(Set(request.paths ?? []) == ["/w", "/w/src"])

    harness.channel.push(.changed(paths: ["/w/src"]))
    harness.channel.push(.treeChanged(root: "/w"))
    harness.channel.push(.rescan(path: "/w"))
    let expected: [FileSystemChangeEvent] = [
      .changed(directories: [URL(filePath: "/w/src", directoryHint: .isDirectory)]),
      .treeChanged(root: URL(filePath: "/w", directoryHint: .isDirectory)),
      .rescan(URL(filePath: "/w", directoryHint: .isDirectory)),
    ]
    #expect(await serveEventually { events.events.value == expected })
  }

  @Test func endingAWatchReleasesItsDirectories() async throws {
    let harness = try await harness()
    let other = UUID()
    _ = await harness.session.subscribe(other)
    await harness.session.setWatchedPaths(["/keep"], for: other)
    _ = try await harness.channel.request(.watch)

    let watch = harness.source.watch(root: URL(filePath: "/w/"))
    let events = EventRecorder(watch.events)
    watch.setWatchedDirectories([URL(filePath: "/w/")])
    let union = try await harness.channel.request(.watch, index: 1)
    #expect(Set(union.paths ?? []) == ["/keep", "/w"])

    events.cancel()
    let reduced = try await harness.channel.request(.watch, index: 2)
    #expect(reduced.paths == ["/keep"])
  }
}

nonisolated struct RemoteKageServeCommandTests {
  @Test func sshRunsServeOverTheSharedConnectionWithoutATTY() {
    let host = RemoteKageHost(id: UUID(), name: "Mini", username: "ahmet", address: "mini.local")
    let invocation = RemoteKageServeCommand.sshInvocation(
      host: host, cliPath: "/Applications/Kage.app/Contents/Resources/bin/supacode")
    #expect(invocation.executableURL.path(percentEncoded: false) == "/usr/bin/ssh")
    let arguments = invocation.arguments
    #expect(arguments.contains("ControlMaster=auto"))
    #expect(arguments.contains("BatchMode=yes"))
    #expect(arguments.contains("-T"))
    #expect(!arguments.contains("-tt"))
    #expect(arguments.contains("ahmet@mini.local"))
    // Under the host's login shell (PATH, profile), quoted for it.
    let remote = arguments.last ?? ""
    #expect(remote.hasPrefix("exec \"$SHELL\" -l -c "))
    #expect(remote.contains("/Applications/Kage.app/Contents/Resources/bin/supacode"))
    #expect(remote.hasSuffix("'\"'\"'host'\"'\"' '\"'\"'serve'\"'\"''"))
  }

  @Test func cliPathPrefersTheReportedPath() {
    #expect(RemoteKageServeCommand.cliPath(reported: "/opt/kage/supacode", environment: [:]) == "/opt/kage/supacode")
    #expect(RemoteKageServeCommand.cliPath(reported: nil, environment: [:]) == RemoteKageCommand.defaultCLIPath)
    #expect(RemoteKageServeCommand.cliPath(reported: "", environment: [:]) == RemoteKageCommand.defaultCLIPath)
  }

  #if DEBUG
    @Test func debugBuildsHonorTheOverride() {
      let environment = [RemoteKageServeCommand.cliPathOverrideEnvironmentKey: "/Users/me/kage-dev/supacode"]
      #expect(
        RemoteKageServeCommand.cliPath(reported: "/opt/kage/supacode", environment: environment)
          == "/Users/me/kage-dev/supacode")
      let relative = [RemoteKageServeCommand.cliPathOverrideEnvironmentKey: "kage-dev/supacode"]
      #expect(RemoteKageServeCommand.cliPath(reported: nil, environment: relative) == RemoteKageCommand.defaultCLIPath)
    }
  #endif
}
