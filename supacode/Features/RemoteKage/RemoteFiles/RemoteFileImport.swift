import Foundation
import SupacodeSettingsShared

/// Why a copy onto a remote host failed.
nonisolated enum RemoteFileImportProblem: Error, Equatable, LocalizedError {
  case invalidHost
  case unreachable
  case importFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidHost: "This host’s address or username isn’t valid."
    case .unreachable: "Couldn’t reach the host."
    case .importFailed(let message): message
    }
  }
}

/// Copies one file or folder from this Mac into a directory on a remote Kage
/// host: `tar` here streams into `ssh -T` over the shared ControlMaster, and a
/// small script on the host unpacks it into a temporary folder beside the
/// destination and renames it in under a free name. Nothing from Kage is
/// needed on the host, and the bytes are never held in memory.
nonisolated enum RemoteFileImport {
  struct Invocation: Equatable, Sendable {
    var executableURL: URL
    var arguments: [String]
  }

  static let debugLogger = SupaLogger("RemoteFiles")

  /// `$0` of the host's `/bin/sh`, which prefixes its error messages.
  static let scriptName = "kage-import"

  /// Runs on the host. `$1` destination directory, `$2` the item's name, `$3`
  /// and `$4` the name's stem and extension for a Finder-style "stem copy N.ext".
  static let script = #"""
    set -eu
    case "$2" in ''|.|..|*/*) echo "kage-import: invalid name" >&2; exit 2 ;; esac
    if [ ! -d "$1" ]; then echo "kage-import: $1 is not a folder" >&2; exit 3; fi
    cd -- "$1"
    tmp=$(mktemp -d ./.kage-import.XXXXXX)
    trap 'rm -rf -- "$tmp"' EXIT
    tar -x -f - -C "$tmp"
    if [ ! -e "$tmp/$2" ] && [ ! -L "$tmp/$2" ]; then echo "kage-import: nothing arrived" >&2; exit 4; fi
    target=$2
    n=1
    while [ -e "$target" ] || [ -L "$target" ]; do
    if [ "$n" -eq 1 ]; then stem="$3 copy"; else stem="$3 copy $n"; fi
    if [ -n "$4" ]; then target="$stem.$4"; else target=$stem; fi
    n=$((n + 1))
    done
    mv -- "$tmp/$2" "./$target"
    printf '%s\n' "$target"
    """#

  /// Runs here: archives `$2` from folder `$1` (no AppleDouble files) into the
  /// receiving command, which is the rest of the arguments.
  static let sendScript = #"""
    set -o pipefail
    parent=$1
    name=$2
    shift 2
    COPYFILE_DISABLE=1 /usr/bin/tar -c -f - -C "$parent" "./$name" | "$@"
    """#

  /// The command that receives the archive on the host.
  static func receiverArguments(directory: String, name: String) -> [String] {
    let ext = (name as NSString).pathExtension
    let stem = (name as NSString).deletingPathExtension
    return ["/bin/sh", "-c", script, scriptName, directory, name, stem, ext]
  }

  /// This Mac's side: `tar` piped into `receiver`, under `/bin/bash` for `pipefail`.
  static func pipeline(source: URL, receiver: [String]) -> Invocation {
    let parent = source.deletingLastPathComponent().path(percentEncoded: false)
    return Invocation(
      executableURL: URL(filePath: "/bin/bash"),
      arguments: ["-c", sendScript, "kage-import-send", parent, source.lastPathComponent] + receiver
    )
  }

  static func invocation(host: RemoteKageHost, source: URL, directory: String)
    -> Result<Invocation, RemoteFileImportProblem>
  {
    guard RemoteKageCommand.isSafe(host) else { return .failure(.invalidHost) }
    let receiver = receiverArguments(directory: directory, name: source.lastPathComponent)
    let ssh = SSHCommand.invocation(
      host: host.remoteHost,
      executable: receiver[0],
      arguments: Array(receiver.dropFirst()),
      workingDirectory: nil,
      extraOptions: SSHCommand.backgroundProbeOptions + ["-T"]
    )
    return .success(pipeline(source: source, receiver: [ssh.executableURL.path] + ssh.arguments))
  }

  /// The name the item landed under: the script's last line (a login shell may
  /// print before it). ssh's own failure is 255.
  static func landedName(from result: RemotePasteProcess.Result) -> Result<String, RemoteFileImportProblem> {
    if result.status == 255 { return .failure(.unreachable) }
    guard result.status == 0 else {
      let lines = lastLines(result.stderr)
      let prefix = scriptName + ": "
      let message =
        lines.last(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
        ?? lines.last
        ?? "The copy failed (exit \(result.status))."
      return .failure(.importFailed(message))
    }
    guard let name = lastLines(result.stdout).last, !name.contains("/"),
      !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
    else { return .failure(.importFailed("The host answered with an unexpected name.")) }
    return .success(name)
  }

  private static func lastLines(_ data: Data) -> [String] {
    (String(bytes: data, encoding: .utf8) ?? "")
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }
}

extension FileExplorerImporter {
  /// Copies onto `host`, one item per ssh run over the shared connection.
  static func remote(host: RemoteKageHost) -> Self {
    Self { sources, directory in
      let destination = RemoteFileSystemSource.path(directory)
      var landed: [String] = []
      for source in sources {
        let invocation = try RemoteFileImport.invocation(host: host, source: source, directory: destination).get()
        let result: RemotePasteProcess.Result
        do {
          result = try await RemotePasteProcess.run(
            executableURL: invocation.executableURL, arguments: invocation.arguments, input: Data())
        } catch {
          throw RemoteFileImportProblem.importFailed(error.localizedDescription)
        }
        landed.append(try RemoteFileImport.landedName(from: result).get())
      }
      return landed
    }
  }
}
