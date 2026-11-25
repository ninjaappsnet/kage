import Foundation
import SupacodeSettingsShared

private nonisolated let serveSessionLogger = SupaLogger("RemoteFiles")

/// A failed call on a host's file channel.
nonisolated enum RemoteKageServeError: Error, Equatable, Sendable {
  /// The host answered with an error (`notFound`, `conflict`, …).
  case remote(RemoteFileError)
  /// The channel is not usable: old or newer host, or the link is down.
  case unavailable(RemoteKageServeFailure)
  /// The host's answer did not decode as the expected result.
  case malformedResponse(String)
}

/// One host's `kage host serve` channel (protocol v1, NDJSON over the serve
/// process's stdin / stdout), shared by everything that shows that host's files.
///
/// Lifecycle, for the least work on both Macs and on the link:
/// - Opened on first use (`retain`, a call, or a watch) and greeted with
///   `hello` before anything else; a protocol mismatch closes it for good.
/// - Reference-counted by visible consumers. When the last one goes away the
///   channel closes `idleTimeout` later (stdin EOF ends the host process; it is
///   killed `closeGrace` after that if it lingers).
/// - An unexpected exit while someone is looking reconnects with the polling
///   backoff (5, 10, 20, 40, then 60 s), re-sends the watch set and tells every
///   watcher to re-list (`rescan`), since events during the gap are lost.
/// - An old host (no `serve`) or a newer protocol is final: no retries until
///   the channel has been idle-closed and something opens it again.
actor RemoteKageServeSession {
  enum Status: Equatable, Sendable {
    /// Closed: nothing is showing this host's files.
    case idle
    /// Started, waiting for the hello answer.
    case connecting
    case connected
    /// Not usable; `offline` retries while someone is looking.
    case unavailable(RemoteKageServeFailure)
  }

  static let idleTimeout: Duration = .seconds(30)
  static let helloTimeout: Duration = .seconds(30)
  static let closeGrace: Duration = .seconds(5)

  /// Every status change, in order. One consumer (the registry).
  nonisolated let statusUpdates: AsyncStream<Status>
  private let statusContinuation: AsyncStream<Status>.Continuation

  private(set) var status: Status = .idle {
    didSet {
      if status != oldValue { statusContinuation.yield(status) }
    }
  }

  private let launcher: RemoteKageServeLauncher
  private let clock: any Clock<Duration>

  private var consumers = 0
  private var channel: RemoteKageServeChannel?
  /// Bumped for every channel and every deliberate close, so output from a
  /// channel the session already let go of is ignored.
  private var generation = 0
  private var isHelloAnswered = false
  private var helloRequestID: Int?
  private var hasEverConnected = false
  private var failureCount = 0
  private var nextRequestID = 0
  private var splitter = RemoteKageServeLineSplitter()

  private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
  private var openWaiters: [CheckedContinuation<Void, any Error>] = []

  private var subscribers: [UUID: AsyncStream<RemoteFileEvent>.Continuation] = [:]
  private var watchedPaths: [UUID: Set<String>] = [:]
  /// What the host currently watches; `nil` until sent on this channel.
  private var sentWatchSet: Set<String>?

  private var idleTask: Task<Void, Never>?
  private var retryTask: Task<Void, Never>?
  private var helloTimeoutTask: Task<Void, Never>?
  /// Kill timers for channels being closed, by generation.
  private var closingTasks: [Int: Task<Void, Never>] = [:]

  init(launcher: RemoteKageServeLauncher, clock: any Clock<Duration>) {
    self.launcher = launcher
    self.clock = clock
    (statusUpdates, statusContinuation) = AsyncStream.makeStream(of: Status.self)
  }

  // MARK: - Consumers.

  /// A consumer became visible: open (or keep) the channel.
  func retain() {
    consumers += 1
    idleTask?.cancel()
    idleTask = nil
    openIfNeeded()
  }

  /// A consumer went away. The last one starts the idle close.
  func release() {
    consumers = max(consumers - 1, 0)
    guard consumers == 0 else { return }
    retryTask?.cancel()
    retryTask = nil
    if channel == nil, case .unavailable(let failure) = status, failure.isRetryable {
      status = .idle
      failureCount = 0
      return
    }
    guard channel != nil || status != .idle else { return }
    scheduleIdleClose()
  }

  /// Holds the channel open while the calling task runs (a visible view's
  /// `.task`); returns, releasing it, when that task is cancelled.
  nonisolated func hold() async {
    await retain()
    let (stream, continuation) = AsyncStream.makeStream(of: Never.self)
    for await _ in stream {}
    continuation.finish()
    await release()
  }

  /// Closes now, whoever is still using it (the host was removed or edited).
  func shutdown() {
    consumers = 0
    idleTask?.cancel()
    idleTask = nil
    for continuation in subscribers.values { continuation.finish() }
    subscribers.removeAll()
    watchedPaths.removeAll()
    close()
    status = .idle
    failureCount = 0
    hasEverConnected = false
  }

  // MARK: - Requests.

  /// Sends one request and waits for its answer. Opens the channel when needed
  /// and waits for the hello; fails fast while the link is down between retries.
  func call<Result: Codable & Sendable>(
    _ makeRequest: @Sendable (Int) -> RemoteFileRequest,
    as type: Result.Type
  ) async throws(RemoteKageServeError) -> Result {
    retain()
    defer { release() }
    let line: Data
    do {
      try await waitUntilOpen()
      guard let channel else { throw RemoteKageServeError.unavailable(currentFailure) }
      let id = makeRequestID()
      let request = makeRequest(id)
      line = try await withCheckedThrowingContinuation { continuation in
        pending[id] = continuation
        send(request, on: channel)
      }
    } catch let error as RemoteKageServeError {
      throw error
    } catch {
      throw .unavailable(.offline(error.localizedDescription))
    }
    let response: RemoteFileResponse<Result>
    do {
      response = try RemoteFileWire.decode(RemoteFileResponse<Result>.self, from: line)
    } catch {
      throw .malformedResponse(error.localizedDescription)
    }
    if response.isSuccess, let result = response.result {
      return result
    }
    throw .remote(response.error ?? RemoteFileError(code: .inputOutput, message: "The host sent an empty answer."))
  }

  // MARK: - Watching.

  /// Starts receiving the host's events. Counts as a consumer until
  /// `unsubscribe`.
  func subscribe(_ token: UUID) -> AsyncStream<RemoteFileEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: RemoteFileEvent.self)
    subscribers[token] = continuation
    retain()
    return stream
  }

  /// Replaces what `token` watches. The host watches the union of all
  /// subscribers; it is told only when that union changes.
  func setWatchedPaths(_ paths: Set<String>, for token: UUID) {
    guard subscribers[token] != nil else { return }
    watchedPaths[token] = paths
    syncWatchSet()
  }

  func unsubscribe(_ token: UUID) {
    guard let continuation = subscribers.removeValue(forKey: token) else { return }
    continuation.finish()
    watchedPaths[token] = nil
    syncWatchSet()
    release()
  }

  // MARK: - Connection.

  private var currentFailure: RemoteKageServeFailure {
    if case .unavailable(let failure) = status { return failure }
    return .offline(RemoteKageServeFailure.connectionClosedMessage)
  }

  private func openIfNeeded() {
    guard channel == nil, retryTask == nil else { return }
    if case .unavailable(let failure) = status, !failure.isRetryable { return }
    connect()
  }

  private func waitUntilOpen() async throws {
    if channel != nil, isHelloAnswered { return }
    openIfNeeded()
    if channel == nil { throw RemoteKageServeError.unavailable(currentFailure) }
    try await withCheckedThrowingContinuation { openWaiters.append($0) }
  }

  private func connect() {
    generation += 1
    let generation = generation
    isHelloAnswered = false
    splitter = RemoteKageServeLineSplitter()
    sentWatchSet = nil
    status = .connecting
    let channel: RemoteKageServeChannel
    do {
      channel = try launcher.launch()
    } catch {
      serveSessionLogger.warning("Could not start host serve: \(error.localizedDescription)")
      channelEnded(.offline(error.localizedDescription))
      return
    }
    self.channel = channel
    Task { [weak self] in
      for await output in channel.output {
        await self?.receive(output, generation: generation)
      }
    }
    let id = makeRequestID()
    helloRequestID = id
    send(.hello(id: id), on: channel)
    helloTimeoutTask = timer(after: Self.helloTimeout) { session in
      session.helloTimedOut(generation: generation)
    }
  }

  private func receive(_ output: RemoteKageServeChannel.Output, generation: Int) {
    guard generation == self.generation else {
      if case .exited = output {
        // A channel this session closed has ended on its own: no kill needed.
        closingTasks.removeValue(forKey: generation)?.cancel()
      }
      return
    }
    switch output {
    case .data(let chunk):
      serveSessionLogger.debug("Received \(chunk.count) bytes")
      for line in splitter.append(chunk) {
        handle(line: line)
      }
    case .exited(let exitStatus, let diagnostics):
      let failure = RemoteKageServeFailure.classify(
        exitStatus: exitStatus,
        diagnostics: diagnostics,
        helloAnswered: isHelloAnswered
      )
      serveSessionLogger.info("Host serve ended (exit \(exitStatus)): \(failure.message)")
      self.generation += 1
      channel = nil
      channelEnded(failure)
    }
  }

  private func handle(line: Data) {
    // Anything that is not one of ours (login-shell noise) is skipped.
    guard let header = try? RemoteFileWire.decode(RemoteFileLineHeader.self, from: line) else { return }
    if header.event != nil {
      guard let event = try? RemoteFileWire.decode(RemoteFileEvent.self, from: line) else { return }
      for continuation in subscribers.values {
        continuation.yield(event)
      }
      return
    }
    guard let id = header.id else { return }
    if id == helloRequestID {
      handleHello(line)
    } else {
      pending.removeValue(forKey: id)?.resume(returning: line)
    }
  }

  private func handleHello(_ line: Data) {
    helloRequestID = nil
    helloTimeoutTask?.cancel()
    helloTimeoutTask = nil
    let hello = try? RemoteFileWire.decode(RemoteFileResponse<RemoteFileHelloResult>.self, from: line).result
    guard let version = hello?.protocolVersion, version == RemoteFileWire.protocolVersion else {
      let failure: RemoteKageServeFailure =
        if let version = hello?.protocolVersion, version > RemoteFileWire.protocolVersion {
          .hostIsNewer(protocolVersion: version)
        } else {
          .needsUpdate
        }
      failAll(with: failure)
      status = .unavailable(failure)
      close()
      if consumers == 0 { scheduleIdleClose() }
      return
    }
    let isReconnect = hasEverConnected
    isHelloAnswered = true
    hasEverConnected = true
    failureCount = 0
    status = .connected
    let waiters = openWaiters
    openWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
    syncWatchSet()
    if isReconnect {
      for continuation in subscribers.values {
        continuation.yield(.rescan(path: "/"))
      }
    }
  }

  private func helloTimedOut(generation: Int) {
    guard generation == self.generation, !isHelloAnswered, let channel else { return }
    self.generation += 1
    self.channel = nil
    channel.terminate()
    channelEnded(.offline(RemoteKageServeFailure.noAnswerMessage))
  }

  /// The channel is gone (already detached by the caller).
  private func channelEnded(_ failure: RemoteKageServeFailure) {
    helloTimeoutTask?.cancel()
    helloTimeoutTask = nil
    helloRequestID = nil
    isHelloAnswered = false
    sentWatchSet = nil
    failAll(with: failure)
    guard failure.isRetryable else {
      status = .unavailable(failure)
      if consumers == 0 { scheduleIdleClose() }
      return
    }
    guard consumers > 0 else {
      status = .idle
      failureCount = 0
      return
    }
    failureCount += 1
    status = .unavailable(failure)
    retryTask = timer(after: RemoteKagePollSchedule.retryDelay(afterFailures: failureCount)) { session in
      session.retryTask = nil
      guard session.consumers > 0, session.channel == nil else { return }
      session.connect()
    }
  }

  private func failAll(with failure: RemoteKageServeFailure) {
    let requests = pending
    pending.removeAll()
    for continuation in requests.values {
      continuation.resume(throwing: RemoteKageServeError.unavailable(failure))
    }
    let waiters = openWaiters
    openWaiters.removeAll()
    for waiter in waiters {
      waiter.resume(throwing: RemoteKageServeError.unavailable(failure))
    }
  }

  private func scheduleIdleClose() {
    idleTask?.cancel()
    idleTask = timer(after: Self.idleTimeout) { session in
      session.idleTask = nil
      guard session.consumers == 0 else { return }
      session.close()
      session.status = .idle
      session.failureCount = 0
      session.hasEverConnected = false
    }
  }

  /// Lets go of the channel: stdin EOF, then a kill if it lingers.
  private func close() {
    retryTask?.cancel()
    retryTask = nil
    helloTimeoutTask?.cancel()
    helloTimeoutTask = nil
    helloRequestID = nil
    isHelloAnswered = false
    sentWatchSet = nil
    let closingGeneration = generation
    generation += 1
    if let channel {
      self.channel = nil
      channel.closeInput()
      closingTasks[closingGeneration] = timer(after: Self.closeGrace) { session in
        session.closingTasks[closingGeneration] = nil
        channel.terminate()
      }
    }
    failAll(with: .offline(RemoteKageServeFailure.connectionClosedMessage))
    // A final failure stays on screen until the idle close resets it.
    if case .unavailable(let failure) = status, !failure.isRetryable { return }
    status = .idle
  }

  // MARK: - Helpers.

  private func syncWatchSet() {
    guard let channel, isHelloAnswered else { return }
    let union = watchedPaths.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    guard union != (sentWatchSet ?? []) else { return }
    sentWatchSet = union
    // Fire and forget: the answer carries nothing, and a failure shows up as
    // the channel ending.
    send(.watch(id: makeRequestID(), paths: union.sorted()), on: channel)
  }

  private func makeRequestID() -> Int {
    nextRequestID += 1
    return nextRequestID
  }

  private func send(_ request: RemoteFileRequest, on channel: RemoteKageServeChannel) {
    guard var line = try? RemoteFileWire.encodeLine(request) else { return }
    line.append(UInt8(ascii: "\n"))
    serveSessionLogger.debug("Sent \(request.operation.rawValue) (\(line.count) bytes)")
    channel.write(line)
  }

  /// Runs `body` on this actor after `duration` on the injected clock, unless
  /// cancelled. Starts immediately so the sleep is registered (and its
  /// deadline fixed) before the caller returns, which is what lets a test clock
  /// advance right after.
  private func timer(
    after duration: Duration,
    _ body: @escaping @Sendable (isolated RemoteKageServeSession) -> Void
  ) -> Task<Void, Never> {
    let clock = clock
    return Task.immediate { [self] in
      do {
        try await clock.sleep(for: duration)
      } catch {
        return
      }
      body(self)
    }
  }
}
