import Foundation
import SupacodeSettingsShared
import WebKit

private nonisolated let htmlPreviewLogger = SupaLogger("HTMLPreview")

/// Serves the previewed document and the assets it references over
/// `HTMLPreviewPolicy.scheme`. Every request is screened by
/// `HTMLPreviewPolicy.resolve` and answered with the current Content Security
/// Policy as a response header, so the file is never modified to carry a policy.
///
/// Bytes come from a `FileSystemSource`, so a page on a remote host loads its
/// relative stylesheets and scripts the same way a local one does. Reads are
/// therefore async, which reopens the "task stopped before it was answered" race
/// (WebKit throws inside `WKURLSchemeTask` when a stopped task is answered):
/// `start` records the task as in flight, `stop` forgets it, and a read that
/// lands for a forgotten task is dropped. Both callbacks and the completion run
/// on the main actor, so the bookkeeping needs no lock. The size cap keeps a page
/// referencing a huge asset from pulling it into memory.
final class HTMLPreviewSchemeHandler: NSObject, WKURLSchemeHandler {
  /// Assets alongside a report are small; anything larger is a mistake or an
  /// attempt to stall the preview.
  private static let maxResponseBytes = 64 * 1024 * 1024

  private let rootDirectory: URL
  private let entryFileName: String
  private let source: any FileSystemSource

  /// Tasks started and not yet answered or stopped.
  private var inFlight: Set<ObjectIdentifier> = []

  /// Read at response time rather than captured, so flipping trust and reloading
  /// serves the new policy without rebuilding the web view.
  var isTrusted = false

  /// Reports each blocked request back to the view so it can offer to relax the
  /// policy. Distinct from CSP violations, which the page reports itself.
  var onDeniedRequest: ((URL) -> Void)?

  nonisolated deinit {}

  init(rootDirectory: URL, entryFileName: String, source: any FileSystemSource = LocalFileSystemSource()) {
    self.rootDirectory = rootDirectory
    self.entryFileName = entryFileName
    self.source = source
  }

  // `WKURLSchemeHandler` is `WK_SWIFT_UI_ACTOR`, so both callbacks are already
  // main-actor isolated and no hop is needed.
  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    respond(to: urlSchemeTask)
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
    inFlight.remove(ObjectIdentifier(urlSchemeTask))
  }

  private func respond(to task: any WKURLSchemeTask) {
    guard let url = task.request.url else {
      task.didFailWithError(URLError(.badURL))
      return
    }

    guard
      let fileURL = HTMLPreviewPolicy.resolve(
        requestPath: url.path(percentEncoded: true),
        in: rootDirectory,
        entryFileName: entryFileName
      )
    else {
      htmlPreviewLogger.debug("Denied preview request for \(url.path(percentEncoded: false))")
      onDeniedRequest?(url)
      task.didFailWithError(URLError(.noPermissionsToReadFile))
      return
    }

    let taskID = ObjectIdentifier(task)
    inFlight.insert(taskID)
    let source = source
    Task { [weak self] in
      let outcome: Result<FileSystemReadResult, FileSystemSourceError>
      do throws(FileSystemSourceError) {
        outcome = .success(try await source.read(fileURL, maxBytes: Self.maxResponseBytes))
      } catch {
        outcome = .failure(error)
      }
      self?.finish(task, id: taskID, url: url, fileURL: fileURL, outcome: outcome)
    }
  }

  private func finish(
    _ task: any WKURLSchemeTask,
    id taskID: ObjectIdentifier,
    url: URL,
    fileURL: URL,
    outcome: Result<FileSystemReadResult, FileSystemSourceError>
  ) {
    // Stopped while the read was in flight: answering now would throw.
    guard inFlight.remove(taskID) != nil else { return }
    switch outcome {
    case .success(let result):
      guard let response = Self.response(for: url, byteCount: result.data.count, fileURL: fileURL, trusted: isTrusted)
      else {
        task.didFailWithError(URLError(.cannotParseResponse))
        return
      }
      task.didReceive(response)
      task.didReceive(result.data)
      task.didFinish()
    case .failure(let error) where error.code == .tooLarge:
      htmlPreviewLogger.warning("Preview asset too large (\(error.size ?? 0) bytes): \(fileURL.lastPathComponent)")
      task.didFailWithError(URLError(.dataLengthExceedsMaximum))
    case .failure(let error):
      htmlPreviewLogger.debug("Preview asset unreadable \(fileURL.lastPathComponent): \(error.localizedDescription)")
      task.didFailWithError(error)
    }
  }

  private static func response(for url: URL, byteCount: Int, fileURL: URL, trusted: Bool) -> HTTPURLResponse? {
    HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: [
        "Content-Type": HTMLPreviewPolicy.mimeType(forPathExtension: fileURL.pathExtension),
        "Content-Length": String(byteCount),
        "Content-Security-Policy": HTMLPreviewPolicy.contentSecurityPolicy(trusted: trusted),
        // Without this an `application/octet-stream` asset could still be
        // sniffed into a document and executed.
        "X-Content-Type-Options": "nosniff",
        "Cache-Control": "no-store",
      ]
    )
  }
}
