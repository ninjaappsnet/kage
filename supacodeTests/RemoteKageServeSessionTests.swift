import Clocks
import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

// MARK: - Framing.

nonisolated struct RemoteKageServeLineSplitterTests {
  @Test func joinsALineSplitAcrossChunks() {
    var splitter = RemoteKageServeLineSplitter()
    #expect(splitter.append(Data("{\"id\":1,".utf8)).isEmpty)
    #expect(splitter.append(Data("\"ok\":true}\n".utf8)) == [Data("{\"id\":1,\"ok\":true}".utf8)])
  }

  @Test func splitsSeveralLinesInOneChunkAndKeepsTheTail() {
    var splitter = RemoteKageServeLineSplitter()
    let lines = splitter.append(Data("a\nb\nc".utf8))
    #expect(lines == [Data("a".utf8), Data("b".utf8)])
    #expect(splitter.append(Data("\n".utf8)) == [Data("c".utf8)])
  }

  @Test func dropsBlankLinesAndCarriageReturns() {
    var splitter = RemoteKageServeLineSplitter()
    #expect(splitter.append(Data("\n\r\nx\r\n\n".utf8)) == [Data("x".utf8)])
  }
}

// MARK: - Exit classification.

nonisolated struct RemoteKageServeFailureTests {
  @Test func oldHostWithoutServeNeedsUpdate() {
    // Real output of `supacode host serve` on Kage 1.3.2 (exit 64).
    let failure = RemoteKageServeFailure.classify(
      exitStatus: 64,
      diagnostics: """
        Error: Unexpected argument 'serve'
        Usage: supacode host <subcommand>
          See 'supacode host --help' for more information.
        """,
      helloAnswered: false
    )
    #expect(failure == .needsUpdate)
    #expect(!failure.isRetryable)
  }

  @Test func hostCLIWithoutHostCommandNeedsUpdate() {
    let failure = RemoteKageServeFailure.classify(
      exitStatus: 64,
      diagnostics: "Error: 2 unexpected arguments: 'host', 'serve'",
      helloAnswered: false
    )
    #expect(failure == .needsUpdate)
  }

  @Test func sshFailureIsOfflineAndRetried() {
    let failure = RemoteKageServeFailure.classify(
      exitStatus: 255,
      diagnostics: "ssh: connect to host mini port 22: Connection refused",
      helloAnswered: false
    )
    #expect(failure == .offline("Can't reach the host: connect to host mini port 22: Connection refused"))
    #expect(failure.isRetryable)
  }

  @Test func missingCLIIsOffline() {
    let failure = RemoteKageServeFailure.classify(
      exitStatus: 127, diagnostics: "zsh: no such file or directory: /Applications/Kage.app/…", helloAnswered: false)
    #expect(failure == .offline(RemoteKageCommandResult.notInstalledMessage))
  }

  @Test func exitAfterHelloIsAConnectionLoss() {
    let failure = RemoteKageServeFailure.classify(exitStatus: 0, diagnostics: "", helloAnswered: true)
    #expect(failure.isRetryable)
    #expect(failure == .offline(RemoteKageServeFailure.connectionClosedMessage))
  }

  @Test func exit64AfterHelloIsNotAnUpdateProblem() {
    let failure = RemoteKageServeFailure.classify(exitStatus: 64, diagnostics: "", helloAnswered: true)
    #expect(failure.isRetryable)
  }
}

// MARK: - Session.

@Suite(.serialized)
nonisolated struct RemoteKageServeSessionTests {
  private func makeSession(
    _ launcher: FakeServeLauncher,
    clock: TestClock<Duration> = TestClock()
  ) -> RemoteKageServeSession {
    RemoteKageServeSession(launcher: launcher.launcher, clock: clock)
  }

  private struct Connected {
    let session: RemoteKageServeSession
    let launcher: FakeServeLauncher
    let channel: FakeServeChannel
  }

  /// A session held by one consumer, past its hello.
  private func connected(clock: TestClock<Duration> = TestClock()) async throws -> Connected {
    let launcher = FakeServeLauncher()
    let session = makeSession(launcher, clock: clock)
    await session.retain()
    let channel = try await launcher.channel(0)
    try await channel.answerHello()
    #expect(await serveEventually { await session.status == .connected })
    return Connected(session: session, launcher: launcher, channel: channel)
  }

  @Test func opensOnFirstUseAndSaysHelloFirst() async throws {
    let launcher = FakeServeLauncher()
    let session = makeSession(launcher)
    #expect(launcher.launchCount == 0)
    #expect(await session.status == .idle)

    await session.retain()
    let channel = try await launcher.channel(0)
    #expect(channel.requests.value.first?.operation == .hello)
    #expect(await session.status == .connecting)
    try await channel.answerHello()
    #expect(await serveEventually { await session.status == .connected })
  }

  @Test func matchesResponsesToRequestsByID() async throws {
    let connection = try await connected()
    let session = connection.session
    let channel = connection.channel
    async let first = session.call({ .stat(id: $0, path: "/a") }, as: RemoteFileStatResult.self)
    async let second = session.call({ .stat(id: $0, path: "/b") }, as: RemoteFileStatResult.self)
    let requestA = try #require(await waitForPath("/a", in: channel))
    let requestB = try #require(await waitForPath("/b", in: channel))
    #expect(requestA.id != requestB.id)
    // Answered out of order.
    channel.respond(to: requestB.id, with: RemoteFileStatResult(kind: .dir, size: 2, mtime: 20))
    channel.respond(to: requestA.id, with: RemoteFileStatResult(kind: .file, size: 1, mtime: 10))
    let (statA, statB) = try await (first, second)
    #expect(statA == RemoteFileStatResult(kind: .file, size: 1, mtime: 10))
    #expect(statB == RemoteFileStatResult(kind: .dir, size: 2, mtime: 20))
  }

  @Test func remoteErrorsComeBackTyped() async throws {
    let connection = try await connected()
    let session = connection.session
    let channel = connection.channel
    let result = Task { try await session.call({ .stat(id: $0, path: "/gone") }, as: RemoteFileStatResult.self) }
    let request = try await channel.request(.stat)
    channel.fail(request.id, RemoteFileError(code: .notFound, message: "No such file: /gone"))
    await #expect(throws: RemoteKageServeError.remote(RemoteFileError(code: .notFound, message: "No such file: /gone")))
    {
      try await result.value
    }
  }

  @Test func eventsReachEverySubscriberEvenWhenSplitAcrossReads() async throws {
    let connection = try await connected()
    let session = connection.session
    let channel = connection.channel
    let first = EventRecorder(await session.subscribe(UUID()))
    let second = EventRecorder(await session.subscribe(UUID()))
    defer {
      first.cancel()
      second.cancel()
    }
    channel.sendRaw("{\"event\":\"changed\",\"pa")
    channel.sendRaw("ths\":[\"/w\"]}\n{\"event\":\"treeChanged\",\"root\":\"/w\"}\n")
    let expected: [RemoteFileEvent] = [.changed(paths: ["/w"]), .treeChanged(root: "/w")]
    #expect(await serveEventually { first.events.value == expected && second.events.value == expected })
  }

  @Test func ignoresLoginShellNoiseOnStdout() async throws {
    let launcher = FakeServeLauncher()
    let session = makeSession(launcher)
    await session.retain()
    let channel = try await launcher.channel(0)
    channel.sendRaw("Last login: Tue Nov 25 on ttys001\nnot json either {\n")
    try await channel.answerHello()
    #expect(await serveEventually { await session.status == .connected })
  }

  @Test func newerHostProtocolIsIncompatibleAndNeverRetried() async throws {
    let clock = TestClock()
    let launcher = FakeServeLauncher()
    let session = makeSession(launcher, clock: clock)
    await session.retain()
    let channel = try await launcher.channel(0)
    try await channel.answerHello(protocolVersion: 2)
    #expect(await serveEventually { await session.status == .unavailable(.hostIsNewer(protocolVersion: 2)) })
    #expect(channel.inputClosed.value)
    await #expect(throws: RemoteKageServeError.unavailable(.hostIsNewer(protocolVersion: 2))) {
      try await session.call({ .stat(id: $0, path: "/") }, as: RemoteFileStatResult.self)
    }
    await clock.advance(by: .seconds(300))
    #expect(launcher.launchCount == 1)
  }

  @Test func oldHostNeedsUpdateWithoutARetryStorm() async throws {
    let clock = TestClock()
    let launcher = FakeServeLauncher()
    let session = makeSession(launcher, clock: clock)
    await session.retain()
    let channel = try await launcher.channel(0)
    let call = Task {
      try await session.call({ .list(id: $0, path: "/", showHidden: false) }, as: RemoteFileListResult.self)
    }
    channel.exit(64, diagnostics: "Error: Unexpected argument 'serve'\nUsage: supacode host <subcommand>")
    await #expect(throws: RemoteKageServeError.unavailable(.needsUpdate)) { try await call.value }
    #expect(await session.status == .unavailable(.needsUpdate))
    // Visible for minutes: still one launch.
    for _ in 0..<10 {
      await clock.advance(by: .seconds(60))
    }
    #expect(launcher.launchCount == 1)
    await #expect(throws: RemoteKageServeError.unavailable(.needsUpdate)) {
      try await session.call({ .stat(id: $0, path: "/") }, as: RemoteFileStatResult.self)
    }
    #expect(launcher.launchCount == 1)

    // Gone from screen long enough to close: the next open tries once more.
    await session.release()
    await clock.advance(by: RemoteKageServeSession.idleTimeout)
    #expect(await serveEventually { await session.status == .idle })
    await session.retain()
    #expect(launcher.launchCount == 2)
  }

  @Test func closesThirtySecondsAfterTheLastConsumerLeaves() async throws {
    let clock = TestClock()
    let connection = try await connected(clock: clock)
    let session = connection.session
    let launcher = connection.launcher
    let channel = connection.channel
    await session.retain()
    await session.release()
    await clock.advance(by: .seconds(60))
    #expect(!channel.inputClosed.value, "one consumer is still visible")

    await session.release()
    await clock.advance(by: .seconds(29))
    #expect(!channel.inputClosed.value)
    await clock.advance(by: .seconds(1))
    #expect(await serveEventually { channel.inputClosed.value })
    #expect(await session.status == .idle)
    // The host exits on EOF: no kill needed.
    channel.exit(0)
    await clock.advance(by: .seconds(10))
    #expect(!channel.terminated.value)
    #expect(launcher.launchCount == 1)
  }

  @Test func comingBackWithinTheGraceKeepsTheChannel() async throws {
    let clock = TestClock()
    let connection = try await connected(clock: clock)
    let session = connection.session
    let launcher = connection.launcher
    let channel = connection.channel
    await session.release()
    await clock.advance(by: .seconds(20))
    await session.retain()
    await clock.advance(by: .seconds(60))
    #expect(!channel.inputClosed.value)
    #expect(launcher.launchCount == 1)
  }

  @Test func closeKillsAHostThatIgnoresEOF() async throws {
    let clock = TestClock()
    let connection = try await connected(clock: clock)
    let session = connection.session
    let channel = connection.channel
    await session.release()
    await clock.advance(by: RemoteKageServeSession.idleTimeout)
    #expect(await serveEventually { channel.inputClosed.value })
    #expect(!channel.terminated.value)
    await clock.advance(by: RemoteKageServeSession.closeGrace)
    #expect(await serveEventually { channel.terminated.value })
  }

  @Test func reconnectsWithBackoffThenRewatchesAndRescans() async throws {
    let clock = TestClock()
    let connection = try await connected(clock: clock)
    let session = connection.session
    let launcher = connection.launcher
    let first = connection.channel
    let token = UUID()
    let events = EventRecorder(await session.subscribe(token))
    defer { events.cancel() }
    await session.setWatchedPaths(["/w", "/w/src"], for: token)
    _ = try await first.request(.watch)

    first.exit(255, diagnostics: "Connection to mini closed by remote host.")
    #expect(
      await serveEventually {
        await session.status
          == .unavailable(.offline("Can't reach the host: Connection to mini closed by remote host."))
      })
    await clock.advance(by: .seconds(4))
    #expect(launcher.launchCount == 1)
    await clock.advance(by: .seconds(1))
    let second = try await launcher.channel(1)
    try await second.answerHello()
    let rewatch = try await second.request(.watch)
    #expect(Set(rewatch.paths ?? []) == ["/w", "/w/src"])
    #expect(await serveEventually { events.events.value.contains(.rescan(path: "/")) })
    #expect(await session.status == .connected)
  }

  @Test func retriesBackOffFiveTenTwentySeconds() async throws {
    let clock = TestClock()
    let launcher = FakeServeLauncher()
    let session = makeSession(launcher, clock: clock)
    await session.retain()
    try await launcher.channel(0).exit(255, diagnostics: "ssh: connect to host mini port 22: Operation timed out")
    #expect(await serveEventually { await session.status != .connecting })

    await clock.advance(by: .seconds(5))
    try await launcher.channel(1).exit(255, diagnostics: "ssh: timeout")
    #expect(await serveEventually { await session.status != .connecting })

    await clock.advance(by: .seconds(9))
    #expect(launcher.launchCount == 2)
    await clock.advance(by: .seconds(1))
    try await launcher.channel(2).exit(255, diagnostics: "ssh: timeout")
    #expect(await serveEventually { await session.status != .connecting })

    await clock.advance(by: .seconds(19))
    #expect(launcher.launchCount == 3)
    await clock.advance(by: .seconds(1))
    _ = try await launcher.channel(3)
  }

  @Test func doesNotReconnectWhenNobodyIsLooking() async throws {
    let clock = TestClock()
    let connection = try await connected(clock: clock)
    let session = connection.session
    let launcher = connection.launcher
    let channel = connection.channel
    await session.release()
    channel.exit(255, diagnostics: "ssh: broken pipe")
    #expect(await serveEventually { await session.status == .idle })
    await clock.advance(by: .seconds(120))
    #expect(launcher.launchCount == 1)
  }

  @Test func pendingRequestsFailWhenTheConnectionDrops() async throws {
    let connection = try await connected()
    let session = connection.session
    let channel = connection.channel
    let call = Task {
      try await session.call({ .read(id: $0, path: "/big", maxBytes: 10) }, as: RemoteFileReadResult.self)
    }
    _ = try await channel.request(.read)
    channel.exit(255, diagnostics: "ssh: Broken pipe")
    await #expect(throws: RemoteKageServeError.unavailable(.offline("Can't reach the host: Broken pipe"))) {
      try await call.value
    }
  }

  @Test func watchSetIsTheUnionAndIsOnlySentWhenItChanges() async throws {
    let connection = try await connected()
    let session = connection.session
    let channel = connection.channel
    let first = UUID()
    let second = UUID()
    _ = await session.subscribe(first)
    _ = await session.subscribe(second)
    await session.setWatchedPaths(["/a"], for: first)
    await session.setWatchedPaths(["/b"], for: second)
    let union = try await channel.request(.watch, index: 1)
    #expect(Set(union.paths ?? []) == ["/a", "/b"])

    await session.setWatchedPaths(["/a"], for: first)
    await session.setWatchedPaths(["/a", "/b"], for: second)
    #expect(channel.count(.watch) == 2)

    await session.unsubscribe(second)
    let reduced = try await channel.request(.watch, index: 2)
    #expect(reduced.paths == ["/a"])
  }

  @Test func helloTimeoutCountsAsOfflineAndRetries() async throws {
    let clock = TestClock()
    let launcher = FakeServeLauncher()
    let session = makeSession(launcher, clock: clock)
    await session.retain()
    let channel = try await launcher.channel(0)
    await clock.advance(by: RemoteKageServeSession.helloTimeout)
    #expect(await serveEventually { channel.terminated.value })
    #expect(
      await serveEventually { await session.status == .unavailable(.offline(RemoteKageServeFailure.noAnswerMessage)) })
    await clock.advance(by: .seconds(5))
    _ = try await launcher.channel(1)
  }

  @Test func launchFailureIsOffline() async throws {
    let launcher = FakeServeLauncher()
    launcher.failure.setValue("This host's address or username isn't valid.")
    let session = makeSession(launcher)
    await #expect(throws: RemoteKageServeError.unavailable(.offline("This host's address or username isn't valid."))) {
      try await session.call({ .stat(id: $0, path: "/") }, as: RemoteFileStatResult.self)
    }
  }

  @Test func statusUpdatesStreamInOrder() async throws {
    let launcher = FakeServeLauncher()
    let session = makeSession(launcher)
    let statuses = EventRecorder(session.statusUpdates)
    defer { statuses.cancel() }
    await session.retain()
    try await launcher.channel(0).answerHello()
    #expect(await serveEventually { statuses.events.value.last == .connected })
    #expect(statuses.events.value.contains(.connecting))
  }

  private func waitForPath(_ path: String, in channel: FakeServeChannel) async -> RemoteFileRequest? {
    var found: RemoteFileRequest?
    _ = await serveEventually {
      found = channel.requests.value.first { $0.path == path }
      return found != nil
    }
    return found
  }
}
