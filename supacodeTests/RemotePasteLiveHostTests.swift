import Foundation
import Testing

@testable import supacode

/// Uploads through real ssh to a real host. Off unless
/// `KAGE_REMOTE_PASTE_E2E_HOST` (`user@address`) is set, e.g.
/// `TEST_RUNNER_KAGE_REMOTE_PASTE_E2E_HOST=me@mini.ts.net xcodebuild test …`.
nonisolated struct RemotePasteLiveHostTests {
  private static let destination = ProcessInfo.processInfo.environment["KAGE_REMOTE_PASTE_E2E_HOST"]

  @Test(.enabled(if: destination != nil), .timeLimit(.minutes(1)))
  func uploadsToTheHostAndReturnsItsPath() async throws {
    let parts = try #require(Self.destination?.split(separator: "@", maxSplits: 1).map(String.init))
    try #require(parts.count == 2)
    let host = RemoteKageHost(name: "E2E", username: parts[0], address: parts[1])
    let name = RemotePasteName.make(original: "kage-e2e.bin", token: RemotePasteName.randomToken())
    // Screenshot-sized, so the stdin pipe really streams.
    let data = Data((0..<(6 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    let path = try await RemotePasteUploader.ssh(host: host).upload(RemotePasteItem(name: name, data: data))

    #expect(path == "/tmp/kage-\(parts[0])/\(name)")
  }
}
