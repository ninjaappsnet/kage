import ConcurrencyExtras
import Foundation
import Observation

/// One `kage host serve` session (and its `RemoteFileSystemSource`) per remote
/// host, created on first use and registered with `FileSystemSources` under
/// `remote-kage:<host id>`. Creating one starts nothing: the session opens only
/// when a visible explorer or viewer holds it (`RemoteKageServeSession.hold()`).
/// Mirrors each session's status for the views.
@MainActor
@Observable
final class RemoteKageFileSessions {
  static let shared = RemoteKageFileSessions()

  private(set) var statusByHost: [RemoteKageHost.ID: RemoteKageServeSession.Status] = [:]

  private struct Entry {
    let host: RemoteKageHost
    let cliPath: LockIsolated<String>
    let session: RemoteKageServeSession
    let source: RemoteFileSystemSource
    let statusTask: Task<Void, Never>
  }

  @ObservationIgnored private var entries: [RemoteKageHost.ID: Entry] = [:]
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private let environment: [String: String]
  @ObservationIgnored private let makeLauncher:
    @MainActor (RemoteKageHost, LockIsolated<String>) -> RemoteKageServeLauncher

  nonisolated deinit {}

  init(
    clock: any Clock<Duration> = ContinuousClock(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    makeLauncher: @escaping @MainActor (RemoteKageHost, LockIsolated<String>) -> RemoteKageServeLauncher = {
      host, cliPath in
      .ssh(host: host, cliPath: { cliPath.value })
    }
  ) {
    self.clock = clock
    self.environment = environment
    self.makeLauncher = makeLauncher
  }

  /// The host's source, reusing its session while the host's address and login
  /// stay the same. `reportedCLIPath` (from the host's last snapshot) is used
  /// from the next launch on.
  func source(for host: RemoteKageHost, reportedCLIPath: String?) -> RemoteFileSystemSource {
    let cliPath = RemoteKageServeCommand.cliPath(reported: reportedCLIPath, environment: environment)
    if let entry = entries[host.id], entry.host.remoteHost == host.remoteHost {
      if entry.cliPath.value != cliPath {
        entry.cliPath.setValue(cliPath)
      }
      return entry.source
    }
    if let stale = entries.removeValue(forKey: host.id) {
      stale.statusTask.cancel()
      Task { await stale.session.shutdown() }
    }
    let box = LockIsolated(cliPath)
    let session = RemoteKageServeSession(launcher: makeLauncher(host, box), clock: clock)
    let source = RemoteFileSystemSource(hostID: host.id, session: session)
    let hostID = host.id
    let statusTask = Task { [weak self] in
      for await status in session.statusUpdates {
        self?.statusByHost[hostID] = status
      }
    }
    entries[host.id] = Entry(host: host, cliPath: box, session: session, source: source, statusTask: statusTask)
    FileSystemSources.register(source)
    return source
  }

  func status(for hostID: RemoteKageHost.ID) -> RemoteKageServeSession.Status? {
    statusByHost[hostID]
  }
}
