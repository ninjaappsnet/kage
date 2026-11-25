import Foundation
import Testing

@testable import supacode

struct DebugWindowSnapshotTests {
  @Test func disabledWithoutTheEnvironmentKey() {
    #expect(DebugWindowSnapshot.directory(environment: [:]) == nil)
    #expect(DebugWindowSnapshot.directory(environment: ["KAGE_DEBUG_SNAPSHOT_DIR": ""]) == nil)
  }

  @Test func directoryComesFromTheEnvironment() {
    let directory = DebugWindowSnapshot.directory(environment: ["KAGE_DEBUG_SNAPSHOT_DIR": "/tmp/shots"])
    #expect(directory?.path(percentEncoded: false) == "/tmp/shots/")
  }

  @Test func fileNameKeepsOnlySafeTagCharacters() {
    let directory = URL(filePath: "/tmp/shots", directoryHint: .isDirectory)
    let url = DebugWindowSnapshot.fileURL(directory: directory, tag: "../side bar-1_x", windowIndex: 2)
    #expect(url.path(percentEncoded: false) == "/tmp/shots/sidebar-1_x-2.png")
  }

  @Test func emptyTagFallsBackToSnapshot() {
    let directory = URL(filePath: "/tmp/shots", directoryHint: .isDirectory)
    let url = DebugWindowSnapshot.fileURL(directory: directory, tag: "///", windowIndex: 0)
    #expect(url.path(percentEncoded: false) == "/tmp/shots/snapshot-0.png")
  }
}
