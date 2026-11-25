import Foundation
import Testing

@testable import supacode

/// A persisted viewer tab names its source by id; the registry turns that back
/// into a live source, and an id nobody registered (a host not connected this
/// session) must fail loudly rather than silently read this Mac's disk.
@MainActor
struct FileSystemSourcesTests {
  @Test func theLocalIdAlwaysResolvesToTheDisk() {
    #expect(FileSystemSources.source(for: .local).isLocal)
  }

  @Test func aRegisteredSourceResolvesByItsId() {
    let id = FileSystemSourceID(rawValue: "remote:test-\(UUID().uuidString)")
    let source = InMemoryFileSystemSource(id: id)
    FileSystemSources.register(source)
    defer { FileSystemSources.unregister(id) }

    #expect(FileSystemSources.source(for: id).id == id)
    #expect(!FileSystemSources.source(for: id).isLocal)
  }

  @Test func anUnknownIdFailsAsADroppedLinkInsteadOfReadingLocally() async {
    let id = FileSystemSourceID(rawValue: "remote:nobody-\(UUID().uuidString)")
    let source = FileSystemSources.source(for: id)

    #expect(source.id == id)
    #expect(!source.isLocal)
    do {
      _ = try await source.read(URL(filePath: "/etc/hosts"), maxBytes: 1024)
      Issue.record("expected a connection failure")
    } catch {
      #expect(error.code == .connection)
    }
  }
}
