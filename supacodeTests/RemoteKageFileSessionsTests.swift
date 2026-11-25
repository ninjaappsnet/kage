import Clocks
import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

@MainActor
@Suite(.serialized)
struct RemoteKageFileSessionsTests {
  private let host = RemoteKageHost(
    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!, name: "Mini", username: "ahmet", address: "mini")

  @Test func reusesOneSessionPerHostAndRegistersItsSource() {
    let launcher = FakeServeLauncher()
    let sessions = RemoteKageFileSessions(clock: TestClock(), environment: [:]) { _, _ in launcher.launcher }
    let first = sessions.source(for: host, reportedCLIPath: nil)
    let second = sessions.source(for: host, reportedCLIPath: "/opt/kage/supacode")
    #expect(first.session === second.session)
    #expect(first.id == RemoteFileSystemSource.sourceID(hostID: host.id))
    let registered = FileSystemSources.source(for: first.id) as? RemoteFileSystemSource
    #expect(registered?.session === first.session)
    // Nothing runs until something holds it.
    #expect(launcher.launchCount == 0)
  }

  @Test func aHostWithANewAddressGetsANewSession() {
    let launcher = FakeServeLauncher()
    let sessions = RemoteKageFileSessions(clock: TestClock(), environment: [:]) { _, _ in launcher.launcher }
    let first = sessions.source(for: host, reportedCLIPath: nil)
    var moved = host
    moved.address = "mini-2"
    #expect(sessions.source(for: moved, reportedCLIPath: nil).session !== first.session)
    var renamed = moved
    renamed.name = "Mini Two"
    #expect(
      sessions.source(for: renamed, reportedCLIPath: nil).session
        === sessions.source(for: moved, reportedCLIPath: nil).session)
  }

  @Test func launchesWithTheLatestReportedCLIPath() async throws {
    let paths = LockIsolated<[String]>([])
    let launcher = FakeServeLauncher()
    let sessions = RemoteKageFileSessions(clock: TestClock(), environment: [:]) { _, cliPath in
      RemoteKageServeLauncher {
        paths.withValue { $0.append(cliPath.value) }
        return try launcher.launcher.launch()
      }
    }
    _ = sessions.source(for: host, reportedCLIPath: nil)
    let source = sessions.source(for: host, reportedCLIPath: "/opt/kage/supacode")
    await source.session.retain()
    #expect(paths.value == ["/opt/kage/supacode"])
  }

  @Test func mirrorsTheSessionStatus() async throws {
    let launcher = FakeServeLauncher()
    let sessions = RemoteKageFileSessions(clock: TestClock(), environment: [:]) { _, _ in launcher.launcher }
    let source = sessions.source(for: host, reportedCLIPath: nil)
    await source.session.retain()
    try await launcher.channel(0).answerHello()
    #expect(await serveEventually { sessions.status(for: host.id) == .connected })
  }
}
