import Foundation
import Testing

@testable import supacode

/// The NDJSON shapes of protocol v1, exactly as the plan's table spells them.
nonisolated struct RemoteFileWireTests {
  private static func json(_ value: some Encodable) throws -> String {
    String(bytes: try RemoteFileWire.encodeLine(value), encoding: .utf8) ?? ""
  }

  private static func object(_ line: String) throws -> NSDictionary {
    try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary)
  }

  @Test func requestsDecodeFromFlatLines() throws {
    let line = #"{"id":3,"op":"write","path":"/a/b.txt","data":"aGk=","expectedMtime":1700000000123}"#
    let request = try RemoteFileWire.decode(RemoteFileRequest.self, from: Data(line.utf8))
    #expect(request == .write(id: 3, path: "/a/b.txt", data: Data("hi".utf8), expectedMtime: 1_700_000_000_123))

    let watch = try Self.object(try Self.json(RemoteFileRequest.watch(id: 4, paths: ["/r"])))
    #expect(watch == ["id": 4, "op": "watch", "paths": ["/r"]])
  }

  @Test func responsesCarryIdOkAndResultOrError() throws {
    let success = try Self.object(try Self.json(RemoteFileResponse.success(id: 1, RemoteFileWriteResult(mtime: 42))))
    #expect(success == ["id": 1, "ok": true, "result": ["mtime": 42]])

    let failure = try Self.object(
      try Self.json(
        RemoteFileResponse<RemoteFileEmptyResult>.failure(
          id: 2,
          RemoteFileError(code: .tooLarge, message: "big", size: 99)
        )
      )
    )
    #expect(failure == ["id": 2, "ok": false, "error": ["code": "tooLarge", "message": "big", "size": 99]])

    // A code from a newer host still decodes.
    let future = #"{"id":1,"ok":false,"error":{"code":"quotaExceeded","message":"x"}}"#
    let decoded = try RemoteFileWire.decode(RemoteFileResponse<RemoteFileEmptyResult>.self, from: Data(future.utf8))
    #expect(decoded.error?.code == .inputOutput)
  }

  @Test func listEntriesAndEventsUseThePlanShapes() throws {
    let entry = RemoteFileListResult.Entry(name: "l", kind: .symlink, size: 1, mtime: 2, targetKind: .dir)
    #expect(
      try Self.object(try Self.json(entry))
        == ["name": "l", "kind": "symlink", "size": 1, "mtime": 2, "targetKind": "dir"]
    )

    // Slashes stay unescaped: paths are most of the traffic.
    #expect(try Self.json(RemoteFileEvent.changed(paths: ["/a/b"])).contains(#""paths":["/a/b"]"#))
    #expect(
      try Self.object(try Self.json(RemoteFileEvent.changed(paths: ["/a/b"]))) == [
        "event": "changed", "paths": ["/a/b"],
      ])
    #expect(
      try Self.object(try Self.json(RemoteFileEvent.treeChanged(root: "/r"))) == ["event": "treeChanged", "root": "/r"])
    #expect(try Self.object(try Self.json(RemoteFileEvent.rescan(path: "/p"))) == ["event": "rescan", "path": "/p"])
    for event in [RemoteFileEvent.changed(paths: ["/x"]), .treeChanged(root: "/r"), .rescan(path: "/p")] {
      #expect(try RemoteFileWire.decode(RemoteFileEvent.self, from: RemoteFileWire.encodeLine(event)) == event)
    }

    let header = try RemoteFileWire.decode(
      RemoteFileLineHeader.self, from: Data(#"{"event":"rescan","path":"/p"}"#.utf8))
    #expect(header == RemoteFileLineHeader(id: nil, isSuccess: nil, event: "rescan"))
  }
}
