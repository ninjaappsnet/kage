import Foundation

/// Wire types of `kage host serve` (protocol v1): newline-delimited JSON over the
/// serve process's stdin / stdout. Compiled into both the CLI (the host side) and
/// the app (the viewer side), so the two ends cannot drift apart. Foundation-only
/// and nonisolated: both targets default to main-actor isolation, and the host
/// handles requests off the main thread.
///
/// Paths are absolute POSIX strings; times are milliseconds since 1970.
nonisolated enum RemoteFileWire {
  static let protocolVersion = 1

  /// Encodes one message as a single line (no trailing newline; the writer adds it).
  static func encodeLine(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  static func decode<Value: Decodable>(_ type: Value.Type, from line: Data) throws -> Value {
    try JSONDecoder().decode(type, from: line)
  }
}

/// The operations a viewer can request.
nonisolated enum RemoteFileOperation: String, Codable, Sendable, CaseIterable {
  case hello
  case list
  case stat
  case read
  case write
  case watch
  case gitStatus
}

/// A request line: `{"id": N, "op": "<name>", ...args}`. Arguments are flat
/// optionals so a line needs no per-operation envelope; the host validates the
/// ones its operation requires and answers `badRequest` otherwise.
nonisolated struct RemoteFileRequest: Codable, Equatable, Sendable {
  var id: Int
  var operation: RemoteFileOperation
  var path: String?
  var showHidden: Bool?
  var maxBytes: Int64?
  /// File contents for `write`; JSON carries `Data` as base64.
  var data: Data?
  var expectedMtime: Int64?
  var paths: [String]?
  var root: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case operation = "op"
    case path
    case showHidden
    case maxBytes
    case data
    case expectedMtime
    case paths
    case root
  }

  static func hello(id: Int) -> Self { Self(id: id, operation: .hello) }

  static func list(id: Int, path: String, showHidden: Bool) -> Self {
    Self(id: id, operation: .list, path: path, showHidden: showHidden)
  }

  static func stat(id: Int, path: String) -> Self { Self(id: id, operation: .stat, path: path) }

  static func read(id: Int, path: String, maxBytes: Int64) -> Self {
    Self(id: id, operation: .read, path: path, maxBytes: maxBytes)
  }

  static func write(id: Int, path: String, data: Data, expectedMtime: Int64?) -> Self {
    Self(id: id, operation: .write, path: path, data: data, expectedMtime: expectedMtime)
  }

  static func watch(id: Int, paths: [String]) -> Self { Self(id: id, operation: .watch, paths: paths) }

  static func gitStatus(id: Int, root: String) -> Self { Self(id: id, operation: .gitStatus, root: root) }
}

nonisolated enum RemoteFileErrorCode: String, Codable, Sendable {
  case notFound
  case permission
  case tooLarge
  case conflict
  case notGit
  case badRequest
  case inputOutput = "io"

  /// A code from a newer host reads as a generic I/O failure rather than
  /// failing the whole response.
  init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = Self(rawValue: raw) ?? .inputOutput
  }
}

/// The `error` object of a failed response. `size` rides on `tooLarge`,
/// `mtime` on `conflict` (absent when the file no longer exists).
nonisolated struct RemoteFileError: Error, Codable, Equatable, Sendable {
  var code: RemoteFileErrorCode
  var message: String
  var size: Int64?
  var mtime: Int64?
}

nonisolated enum RemoteFileKind: String, Codable, Sendable {
  case file
  case dir
  case symlink
}

nonisolated struct RemoteFileHelloResult: Codable, Equatable, Sendable {
  var protocolVersion: Int
  var kageVersion: String?
}

nonisolated struct RemoteFileListResult: Codable, Equatable, Sendable {
  nonisolated struct Entry: Codable, Equatable, Sendable {
    var name: String
    var kind: RemoteFileKind
    var size: Int64
    var mtime: Int64
    /// For a symlink, what it points at (`file` or `dir`); absent when dangling.
    var targetKind: RemoteFileKind?
  }

  /// Unsorted; the viewer sorts.
  var entries: [Entry]
}

nonisolated struct RemoteFileStatResult: Codable, Equatable, Sendable {
  var kind: RemoteFileKind
  var size: Int64
  var mtime: Int64
}

nonisolated struct RemoteFileReadResult: Codable, Equatable, Sendable {
  var data: Data
  var size: Int64
  var mtime: Int64
}

nonisolated struct RemoteFileWriteResult: Codable, Equatable, Sendable {
  var mtime: Int64
}

nonisolated struct RemoteFileEmptyResult: Codable, Equatable, Sendable {}

nonisolated struct RemoteFileGitStatusResult: Codable, Equatable, Sendable {
  /// Raw `git status --porcelain=v2 -z --untracked-files=all --ignored=matching
  /// --no-renames` output (NUL-separated records), as the local files inspector reads it.
  var porcelain: String
}

/// A response line: `{"id": N, "ok": true, "result": {...}}` or
/// `{"id": N, "ok": false, "error": {...}}`. `id` is absent only when the
/// request line was so malformed that it carried none.
nonisolated struct RemoteFileResponse<Result: Codable & Sendable>: Codable, Sendable {
  var id: Int?
  var isSuccess: Bool
  var result: Result?
  var error: RemoteFileError?

  private enum CodingKeys: String, CodingKey {
    case id
    case isSuccess = "ok"
    case result
    case error
  }

  static func success(id: Int, _ result: Result) -> Self { Self(id: id, isSuccess: true, result: result) }

  static func failure(id: Int?, _ error: RemoteFileError) -> Self { Self(id: id, isSuccess: false, error: error) }
}

nonisolated extension RemoteFileResponse: Equatable where Result: Equatable {}

/// Routes an incoming host line before decoding it fully: a line with `event`
/// is an event, otherwise a response for `id`.
nonisolated struct RemoteFileLineHeader: Decodable, Equatable, Sendable {
  var id: Int?
  var isSuccess: Bool?
  var event: String?

  private enum CodingKeys: String, CodingKey {
    case id
    case isSuccess = "ok"
    case event
  }
}

/// Host → viewer push, no id.
nonisolated enum RemoteFileEvent: Codable, Equatable, Sendable {
  /// Listings of these watched paths changed (a watched directory, or the
  /// directory holding a watched file, saw an entry change).
  case changed(paths: [String])
  /// Something under this watched root changed, `.git/HEAD` and `.git/index`
  /// included (drives the viewer's git status refresh).
  case treeChanged(root: String)
  /// The host lost track of events under this path (dropped events, root moved,
  /// volume unmounted): re-list everything under it.
  case rescan(path: String)

  private enum CodingKeys: String, CodingKey {
    case event
    case paths
    case root
    case path
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let name = try container.decode(String.self, forKey: .event)
    switch name {
    case "changed": self = .changed(paths: try container.decode([String].self, forKey: .paths))
    case "treeChanged": self = .treeChanged(root: try container.decode(String.self, forKey: .root))
    case "rescan": self = .rescan(path: try container.decode(String.self, forKey: .path))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .event,
        in: container,
        debugDescription: "Unknown event \(name)",
      )
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .changed(let paths):
      try container.encode("changed", forKey: .event)
      try container.encode(paths, forKey: .paths)
    case .treeChanged(let root):
      try container.encode("treeChanged", forKey: .event)
      try container.encode(root, forKey: .root)
    case .rescan(let path):
      try container.encode("rescan", forKey: .event)
      try container.encode(path, forKey: .path)
    }
  }
}
