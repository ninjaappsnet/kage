import Foundation
import SupacodeSettingsShared
import WebKit

private nonisolated let htmlPreviewLogger = SupaLogger("HTMLPreview")

/// Serves the previewed document and the assets it references over
/// `HTMLPreviewPolicy.scheme`. Every request is screened by
/// `HTMLPreviewPolicy.resolve` and answered with the current Content Security
/// Policy as a response header, so the file on disk is never modified to carry
/// a policy.
///
/// Reads are synchronous. That is deliberate: `start` and `stop` both arrive on
/// the main thread, so answering within the same turn makes the
/// "task stopped before it was answered" race — which throws inside
/// `WKURLSchemeTask` — structurally impossible. The size cap keeps that honest
/// for the pathological case of a page referencing a huge asset.
final class HTMLPreviewSchemeHandler: NSObject, WKURLSchemeHandler {
  /// Assets alongside a report are small; anything larger is a mistake or an
  /// attempt to stall the main thread.
  private static let maxResponseBytes = 64 * 1024 * 1024

  private let rootDirectory: URL
  private let entryFileName: String

  /// Read at response time rather than captured, so flipping trust and reloading
  /// serves the new policy without rebuilding the web view.
  var isTrusted = false

  /// Reports each blocked request back to the view so it can offer to relax the
  /// policy. Distinct from CSP violations, which the page reports itself.
  var onDeniedRequest: ((URL) -> Void)?

  init(rootDirectory: URL, entryFileName: String) {
    self.rootDirectory = rootDirectory
    self.entryFileName = entryFileName
  }

  // `WKURLSchemeHandler` is `WK_SWIFT_UI_ACTOR`, so both callbacks are already
  // main-actor isolated and no hop is needed.
  func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
    respond(to: urlSchemeTask)
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
    // Nothing to cancel: `respond(to:)` completes the task before returning.
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

    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))
      let size = (attributes[.size] as? Int) ?? 0
      guard size <= Self.maxResponseBytes else {
        htmlPreviewLogger.warning("Preview asset too large (\(size) bytes): \(fileURL.lastPathComponent)")
        task.didFailWithError(URLError(.dataLengthExceedsMaximum))
        return
      }
      let data = try Data(contentsOf: fileURL)
      guard let response = Self.response(for: url, byteCount: data.count, fileURL: fileURL, trusted: isTrusted)
      else {
        task.didFailWithError(URLError(.cannotParseResponse))
        return
      }
      task.didReceive(response)
      task.didReceive(data)
      task.didFinish()
    } catch {
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
