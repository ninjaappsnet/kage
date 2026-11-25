import ArgumentParser
import Darwin
import Foundation

extension HostCommand {
  /// `kage host serve`: the host end of the remote file explorer. A viewer
  /// starts it over ssh and keeps it open; it reads NDJSON requests from stdin
  /// and writes responses and change events to stdout (protocol v1, see
  /// `RemoteFileWire`). It does not need Kage to be running and exits when
  /// stdin closes.
  struct Serve: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Serve this Mac's files to a viewing Kage over stdin/stdout (NDJSON). Exits when stdin closes."
    )

    func run() throws {
      // A viewer that went away closes the pipe: end quietly instead of dying on SIGPIPE.
      signal(SIGPIPE, SIG_IGN)
      let output = RemoteFileLineOutput { line in
        do {
          try FileHandle.standardOutput.write(contentsOf: line)
        } catch {
          Darwin.exit(0)
        }
      }
      let watcher = RemoteFileWatcher.live { output.send($0) }
      let server = RemoteFileServer(
        handler: RemoteFileRequestHandler(kageVersion: Self.kageVersion()),
        watcher: watcher,
        output: output
      )
      // Blocking reads park the main thread in read(2): no CPU while idle.
      while let line = readLine(strippingNewline: true) {
        server.receive(line: Data(line.utf8))
      }
      server.finish()
    }

    /// The version of the Kage.app this binary ships in (it lives at
    /// `Kage.app/Contents/Resources/bin`, usually reached through a symlink).
    private static func kageVersion() -> String? {
      guard var url = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
      while url.pathComponents.count > 1 {
        url = url.deletingLastPathComponent()
        guard url.lastPathComponent == "Contents" else { continue }
        let bundle = Bundle(url: url.deletingLastPathComponent())
        return bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      }
      return nil
    }
  }
}
