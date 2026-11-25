import Darwin
import Foundation

/// The POSIX calls behind `kage host serve`. Plain syscalls rather than
/// `FileManager`: a listing is one `readdir` pass plus one `fstatat` per
/// entry, with no per-item object allocation.
nonisolated enum RemoteFilePOSIX {
  /// macOS resolves at most MAXSYMLINKS (32) links before ELOOP.
  static let maxFollowedSymbolicLinks = 32

  static func requireAbsolute(_ path: String?, _ argument: String) throws(RemoteFileError) -> String {
    guard let path else { throw .badRequest("Missing \(argument).") }
    guard path.hasPrefix("/") else { throw .badRequest("\(argument) must be an absolute path: \(path)") }
    return path
  }

  static func fileStatus(_ path: String, followingSymlinks: Bool = true) throws(RemoteFileError) -> stat {
    var info = stat()
    let result = followingSymlinks ? stat(path, &info) : lstat(path, &info)
    guard result == 0 else { throw .posix(errno, path: path) }
    return info
  }

  /// `nil` when nothing exists at `path`; other failures throw.
  static func fileStatusIfPresent(_ path: String) throws(RemoteFileError) -> stat? {
    var info = stat()
    guard stat(path, &info) == 0 else {
      let code = errno
      if code == ENOENT { return nil }
      throw .posix(code, path: path)
    }
    return info
  }

  /// Sockets, FIFOs and devices list as files; the viewer only distinguishes
  /// what it can open as a directory.
  static func kind(of mode: mode_t) -> RemoteFileKind {
    switch mode & S_IFMT {
    case S_IFDIR: .dir
    case S_IFLNK: .symlink
    default: .file
    }
  }

  static func milliseconds(_ time: timespec) -> Int64 {
    Int64(time.tv_sec) * 1000 + Int64(time.tv_nsec) / 1_000_000
  }

  static func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// Strips trailing slashes (except the root's own).
  static func normalized(_ path: String) -> String {
    var trimmed = Substring(path)
    while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
    return String(trimmed)
  }

  static func parent(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "/" }
    return slash == path.startIndex ? "/" : String(path[..<slash])
  }

  /// Follows a symlink chain at `path` to the real file a write should
  /// replace, so the link survives. Returns `path` itself when it is not a link
  /// (including a file that does not exist yet). Relative targets resolve
  /// against the link's real directory, as the kernel does. Mirrors
  /// `SymlinkPreservingFileWriter`, which the CLI cannot link.
  static func symlinkTarget(of path: String) throws(RemoteFileError) -> String {
    var current = path
    var visited: Set<String> = []
    while true {
      var info = stat()
      guard lstat(current, &info) == 0 else {
        let code = errno
        if code == ENOENT { return current }
        throw .posix(code, path: current)
      }
      guard info.st_mode & S_IFMT == S_IFLNK else { return current }
      guard visited.insert(current).inserted, visited.count <= maxFollowedSymbolicLinks else {
        throw RemoteFileError(code: .inputOutput, message: "Too many levels of symbolic links: \(path)")
      }
      var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
      let length = readlink(current, &buffer, buffer.count - 1)
      guard length >= 0 else { throw .posix(errno, path: current) }
      buffer[length] = 0
      let destination = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
      let base = destination.hasPrefix("/") ? "" : (realPath(parent(of: current)) ?? parent(of: current)) + "/"
      current = URL(filePath: base + destination).standardized.path(percentEncoded: false)
    }
  }

  /// Writes `data` to a temp file next to `target` and renames it over the
  /// target, so a reader never sees a half-written file. `mode` carries the
  /// replaced file's permission bits; a new file gets the umask default.
  static func atomicWrite(_ data: Data, to target: String, mode: mode_t?) throws(RemoteFileError) {
    let directory = parent(of: target)
    let name = String(target[target.index(after: target.lastIndex(of: "/") ?? target.startIndex)...])
    let temporary = "\(directory)/.\(name).kage-\(UUID().uuidString).tmp"
    let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
    guard descriptor >= 0 else { throw .posix(errno, path: temporary) }
    var failure: RemoteFileError?
    if let mode, fchmod(descriptor, mode & 0o7777) != 0 {
      failure = .posix(errno, path: temporary)
    }
    if failure == nil {
      failure = data.withUnsafeBytes { buffer -> RemoteFileError? in
        var offset = 0
        while offset < buffer.count {
          let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
          if written < 0 {
            if errno == EINTR { continue }
            return .posix(errno, path: temporary)
          }
          offset += written
        }
        return nil
      }
    }
    if close(descriptor) != 0, failure == nil {
      failure = .posix(errno, path: temporary)
    }
    if failure == nil, rename(temporary, target) != 0 {
      failure = .posix(errno, path: target)
    }
    if let failure {
      unlink(temporary)
      throw failure
    }
  }
}

nonisolated extension RemoteFileError {
  static func badRequest(_ message: String) -> Self { Self(code: .badRequest, message: message) }

  static func posix(_ code: Int32, path: String) -> Self {
    let description = String(cString: strerror(code))
    switch code {
    case ENOENT, ENOTDIR: return Self(code: .notFound, message: "\(description): \(path)")
    case EACCES, EPERM, EROFS: return Self(code: .permission, message: "\(description): \(path)")
    default: return Self(code: .inputOutput, message: "\(description): \(path)")
    }
  }
}
