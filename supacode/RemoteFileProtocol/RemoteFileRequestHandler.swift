import Darwin
import Foundation
import Synchronization

/// Answers every `kage host serve` operation except `watch` (which the server
/// routes to `RemoteFileWatcher`). Stateless and synchronous: the server runs
/// each request on a concurrent queue, so a slow read never holds up another
/// request or an event.
nonisolated struct RemoteFileRequestHandler: Sendable {
  var kageVersion: String?
  var gitExecutable: String

  init(kageVersion: String?, gitExecutable: String = "/usr/bin/git") {
    self.kageVersion = kageVersion
    self.gitExecutable = gitExecutable
  }

  /// The encoded response line (without its newline) for `request`.
  func respond(to request: RemoteFileRequest) -> Data {
    do throws(RemoteFileError) {
      switch request.operation {
      case .hello:
        return Self.success(request.id, hello())
      case .list:
        let path = try RemoteFilePOSIX.requireAbsolute(request.path, "path")
        return Self.success(request.id, try list(path: path, showHidden: request.showHidden ?? false))
      case .stat:
        return Self.success(request.id, try stat(path: try RemoteFilePOSIX.requireAbsolute(request.path, "path")))
      case .read:
        let path = try RemoteFilePOSIX.requireAbsolute(request.path, "path")
        guard let maxBytes = request.maxBytes else { throw .badRequest("Missing maxBytes.") }
        return Self.success(request.id, try read(path: path, maxBytes: maxBytes))
      case .write:
        let path = try RemoteFilePOSIX.requireAbsolute(request.path, "path")
        guard let data = request.data else { throw .badRequest("Missing data.") }
        return Self.success(request.id, try write(path: path, data: data, expectedMtime: request.expectedMtime))
      case .gitStatus:
        return Self.success(request.id, try gitStatus(root: try RemoteFilePOSIX.requireAbsolute(request.root, "root")))
      case .watch:
        throw .badRequest("watch is not handled here.")
      }
    } catch {
      return Self.failure(request.id, error)
    }
  }

  func hello() -> RemoteFileHelloResult {
    RemoteFileHelloResult(protocolVersion: RemoteFileWire.protocolVersion, kageVersion: kageVersion)
  }

  func list(path: String, showHidden: Bool) throws(RemoteFileError) -> RemoteFileListResult {
    _ = try RemoteFilePOSIX.requireAbsolute(path, "path")
    guard let directory = opendir(path) else { throw .posix(errno, path: path) }
    defer { closedir(directory) }
    let descriptor = dirfd(directory)
    var entries: [RemoteFileListResult.Entry] = []
    while let entry = readdir(directory) {
      let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
        String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
      }
      if name == "." || name == ".." { continue }
      if !showHidden, name.hasPrefix(".") { continue }
      var info = Darwin.stat()
      // Gone between readdir and fstatat: the next listing will not show it either.
      guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
      if !showHidden, info.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
      let kind = RemoteFilePOSIX.kind(of: info.st_mode)
      var targetKind: RemoteFileKind?
      if kind == .symlink {
        var target = Darwin.stat()
        if fstatat(descriptor, name, &target, 0) == 0 {
          targetKind = RemoteFilePOSIX.kind(of: target.st_mode)
          info = target
        }
      }
      entries.append(
        RemoteFileListResult.Entry(
          name: name,
          kind: kind,
          size: Int64(info.st_size),
          mtime: RemoteFilePOSIX.milliseconds(info.st_mtimespec),
          targetKind: targetKind
        )
      )
    }
    return RemoteFileListResult(entries: entries)
  }

  func stat(path: String) throws(RemoteFileError) -> RemoteFileStatResult {
    let info = try RemoteFilePOSIX.fileStatus(try RemoteFilePOSIX.requireAbsolute(path, "path"))
    return RemoteFileStatResult(
      kind: RemoteFilePOSIX.kind(of: info.st_mode),
      size: Int64(info.st_size),
      mtime: RemoteFilePOSIX.milliseconds(info.st_mtimespec)
    )
  }

  /// Checks the size before opening, so an oversized file costs one `stat`.
  func read(path: String, maxBytes: Int64) throws(RemoteFileError) -> RemoteFileReadResult {
    _ = try RemoteFilePOSIX.requireAbsolute(path, "path")
    let before = try RemoteFilePOSIX.fileStatus(path)
    guard RemoteFilePOSIX.kind(of: before.st_mode) == .file else {
      throw .badRequest("Not a file: \(path)")
    }
    guard Int64(before.st_size) <= maxBytes else { throw .tooLarge(size: Int64(before.st_size), maxBytes: maxBytes) }

    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw .posix(errno, path: path) }
    defer { close(descriptor) }
    var info = Darwin.stat()
    guard fstat(descriptor, &info) == 0 else { throw .posix(errno, path: path) }
    guard Int64(info.st_size) <= maxBytes else { throw .tooLarge(size: Int64(info.st_size), maxBytes: maxBytes) }

    var data = Data(capacity: Int(info.st_size))
    let chunkSize = 1 << 20
    var chunk = [UInt8](repeating: 0, count: chunkSize)
    while true {
      let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, chunkSize) }
      if count < 0 {
        if errno == EINTR { continue }
        throw .posix(errno, path: path)
      }
      if count == 0 { break }
      data.append(contentsOf: chunk.prefix(count))
      // Grew while being read: refuse rather than send more than asked for.
      if Int64(data.count) > maxBytes { throw .tooLarge(size: Int64(data.count), maxBytes: maxBytes) }
    }
    return RemoteFileReadResult(
      data: data,
      size: Int64(data.count),
      mtime: RemoteFilePOSIX.milliseconds(info.st_mtimespec)
    )
  }

  /// Saves like the local editor: refuses when the file changed (or vanished)
  /// since `expectedMtime`, writes through a symlink to its target, keeps the
  /// target's mode, and replaces it atomically.
  func write(path: String, data: Data, expectedMtime: Int64?) throws(RemoteFileError) -> RemoteFileWriteResult {
    _ = try RemoteFilePOSIX.requireAbsolute(path, "path")
    let target = try RemoteFilePOSIX.symlinkTarget(of: path)
    let current = try RemoteFilePOSIX.fileStatusIfPresent(target)
    if let expectedMtime {
      let currentMtime = current.map { RemoteFilePOSIX.milliseconds($0.st_mtimespec) }
      guard currentMtime == expectedMtime else {
        throw RemoteFileError(
          code: .conflict,
          message: currentMtime == nil ? "The file no longer exists: \(path)" : "The file changed on disk: \(path)",
          mtime: currentMtime
        )
      }
    }
    if let current, RemoteFilePOSIX.kind(of: current.st_mode) == .dir {
      throw .badRequest("Not a file: \(path)")
    }
    // Like the local writer: the destination's own folder is created when
    // missing, a symlink target's never is.
    if target == path {
      do {
        try FileManager.default.createDirectory(
          atPath: RemoteFilePOSIX.parent(of: path),
          withIntermediateDirectories: true
        )
      } catch {
        throw RemoteFileError(code: .inputOutput, message: error.localizedDescription)
      }
    }
    try RemoteFilePOSIX.atomicWrite(data, to: target, mode: current?.st_mode)
    let written = try RemoteFilePOSIX.fileStatus(target)
    return RemoteFileWriteResult(mtime: RemoteFilePOSIX.milliseconds(written.st_mtimespec))
  }

  /// Raw `git status --porcelain=v2 -z` (see `gitStatusArguments`). `--no-optional-locks` keeps git from
  /// refreshing the index, which would fire an index event, a `treeChanged`,
  /// and so another status request, forever.
  func gitStatus(root: String) throws(RemoteFileError) -> RemoteFileGitStatusResult {
    _ = try RemoteFilePOSIX.requireAbsolute(root, "root")
    let info = try RemoteFilePOSIX.fileStatus(root)
    guard RemoteFilePOSIX.kind(of: info.st_mode) == .dir else { throw .notGit(root) }

    let process = Process()
    process.executableURL = URL(filePath: gitExecutable)
    process.arguments = Self.gitStatusArguments(root: root)
    process.environment = ProcessInfo.processInfo.environment.merging(
      ["LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0"],
      uniquingKeysWith: { _, override in override }
    )
    let output = Pipe()
    let errorOutput = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errorOutput
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
      try process.run()
    } catch {
      throw RemoteFileError(code: .inputOutput, message: "Could not run git: \(error.localizedDescription)")
    }
    // Drain stderr concurrently so neither pipe can fill up and stall git.
    let errorText = Mutex(Data())
    let drained = DispatchGroup()
    DispatchQueue.global().async(group: drained) {
      let data = (try? errorOutput.fileHandleForReading.readToEnd()) ?? Data()
      errorText.withLock { $0 = data }
    }
    let porcelain = (try? output.fileHandleForReading.readToEnd()) ?? Data()
    drained.wait()
    exited.wait()

    guard process.terminationStatus == 0 else {
      let message = (String(bytes: errorText.withLock { $0 }, encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if message.contains("not a git repository") { throw .notGit(root) }
      throw RemoteFileError(code: .inputOutput, message: message.isEmpty ? "git status failed." : message)
    }
    guard let text = String(bytes: porcelain, encoding: .utf8) else {
      throw RemoteFileError(code: .inputOutput, message: "git status printed invalid UTF-8.")
    }
    return RemoteFileGitStatusResult(porcelain: text)
  }

  /// The exact argv of the local files inspector (`GitClient.fileStatus`), so
  /// the viewer parses both with `GitStatusSnapshot.parse(porcelainV2:)`.
  static func gitStatusArguments(root: String) -> [String] {
    [
      "-C", root, "--no-optional-locks", "status", "--porcelain=v2", "-z",
      "--untracked-files=all", "--ignored=matching", "--no-renames",
    ]
  }

  static func success<Result: Codable & Sendable>(_ id: Int, _ result: Result) -> Data {
    do {
      return try RemoteFileWire.encodeLine(RemoteFileResponse.success(id: id, result))
    } catch {
      return failure(id, RemoteFileError(code: .inputOutput, message: "Could not encode the result."))
    }
  }

  static func failure(_ id: Int?, _ error: RemoteFileError) -> Data {
    let response = RemoteFileResponse<RemoteFileEmptyResult>.failure(id: id, error)
    return (try? RemoteFileWire.encodeLine(response)) ?? Data(#"{"ok":false,"error":{"code":"io","message":""}}"#.utf8)
  }
}

nonisolated extension RemoteFileError {
  static func tooLarge(size: Int64, maxBytes: Int64) -> Self {
    Self(code: .tooLarge, message: "The file is \(size) bytes, over the \(maxBytes)-byte limit.", size: size)
  }

  static func notGit(_ root: String) -> Self {
    Self(code: .notGit, message: "Not a git repository: \(root)")
  }
}
