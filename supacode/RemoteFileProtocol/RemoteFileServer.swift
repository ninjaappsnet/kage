import Foundation
import Synchronization

/// Writes whole lines to the viewer. Responses and events come from different
/// queues, so each line goes out under one lock in one write.
nonisolated final class RemoteFileLineOutput: Sendable {
  private let lock = Mutex(())
  private let write: @Sendable (Data) -> Void

  init(write: @escaping @Sendable (Data) -> Void) {
    self.write = write
  }

  func send(_ line: Data) {
    var terminated = line
    terminated.append(UInt8(ascii: "\n"))
    lock.withLock { _ in write(terminated) }
  }

  func send(_ event: RemoteFileEvent) {
    guard let line = try? RemoteFileWire.encodeLine(event) else { return }
    send(line)
  }
}

/// The core of `kage host serve`, free of stdin / stdout so tests drive it
/// with lines. `watch` requests run in order on one serial queue (each one
/// replaces the set); every other request runs on a concurrent queue, so a big
/// read or a slow `git status` never delays another answer or an event.
nonisolated final class RemoteFileServer: Sendable {
  private struct IdentifiedLine: Decodable {
    var id: Int?
  }

  private let handler: RemoteFileRequestHandler
  private let watcher: RemoteFileWatcher
  private let output: RemoteFileLineOutput
  private let requests = DispatchQueue(
    label: "net.ninjaapps.kage.host-serve.requests",
    qos: .userInitiated,
    attributes: .concurrent
  )
  private let control = DispatchQueue(label: "net.ninjaapps.kage.host-serve.watch", qos: .userInitiated)
  private let inFlight = DispatchGroup()

  init(handler: RemoteFileRequestHandler, watcher: RemoteFileWatcher, output: RemoteFileLineOutput) {
    self.handler = handler
    self.watcher = watcher
    self.output = output
  }

  /// Handles one request line (without its newline).
  func receive(line: Data) {
    guard line.contains(where: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") && $0 != UInt8(ascii: "\r") })
    else { return }
    let request: RemoteFileRequest
    do {
      request = try RemoteFileWire.decode(RemoteFileRequest.self, from: line)
    } catch {
      let id = (try? RemoteFileWire.decode(IdentifiedLine.self, from: line))?.id
      output.send(
        RemoteFileRequestHandler.failure(id, .badRequest("Unknown operation or malformed request line."))
      )
      return
    }
    let handler = handler
    let watcher = watcher
    let output = output
    let inFlight = inFlight
    inFlight.enter()
    guard request.operation == .watch else {
      requests.async {
        output.send(handler.respond(to: request))
        inFlight.leave()
      }
      return
    }
    control.async {
      defer { inFlight.leave() }
      guard let paths = request.paths else {
        output.send(RemoteFileRequestHandler.failure(request.id, .badRequest("Missing paths.")))
        return
      }
      if let relative = paths.first(where: { !$0.hasPrefix("/") }) {
        output.send(
          RemoteFileRequestHandler.failure(request.id, .badRequest("paths must be absolute: \(relative)"))
        )
        return
      }
      watcher.setWatchedPaths(paths)
      output.send(RemoteFileRequestHandler.success(request.id, RemoteFileEmptyResult()))
    }
  }

  /// Stdin closed: let in-flight requests answer, then stop watching.
  func finish() {
    inFlight.wait()
    watcher.stop()
  }
}
