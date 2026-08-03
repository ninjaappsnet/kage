import Foundation
import Testing
import WebKit

@testable import supacode

/// End-to-end cover for the piece the pure policy tests cannot reach: that a real
/// `WKWebView` actually renders the document through the scheme handler, that a
/// sibling stylesheet is served, and that inline script still runs under the
/// default policy. A live web engine is the only thing that can answer those.
@MainActor
struct HTMLPreviewWebViewTests {
  private static func makeFixture(html: String, css: String?) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "hpreview-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let page = directory.appending(path: "page.html")
    try Data(html.utf8).write(to: page)
    if let css {
      try Data(css.utf8).write(to: directory.appending(path: "style.css"))
    }
    return page
  }

  /// `makeWebView()` starts the load synchronously and `didFinish` can only
  /// arrive at a suspension point, so installing the callback before the first
  /// `await` cannot miss it.
  private static func load(_ page: URL, trusted: Bool = false) async -> (
    HTMLPreviewWebView.Coordinator, WKWebView
  ) {
    let coordinator = HTMLPreviewWebView.Coordinator(fileURL: page, isTrusted: trusted)
    let webView = coordinator.makeWebView()
    await withCheckedContinuation { continuation in
      coordinator.onNavigationSettled = { continuation.resume() }
    }
    coordinator.onNavigationSettled = nil
    return (coordinator, webView)
  }

  @Test(.timeLimit(.minutes(1)))
  func servesDocumentAndSiblingStylesheet() async throws {
    let page = try Self.makeFixture(
      html: """
        <!doctype html>
        <html><head><link rel="stylesheet" href="style.css"></head>
        <body><p id="hello">hi</p></body></html>
        """,
      css: "body { background-color: rgb(1, 2, 3); }"
    )
    defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }

    let (coordinator, webView) = await Self.load(page)
    defer { coordinator.tearDown(webView) }

    let background =
      try await webView.evaluateJavaScript(
        "getComputedStyle(document.body).backgroundColor"
      ) as? String
    #expect(background == "rgb(1, 2, 3)")
  }

  @Test(.timeLimit(.minutes(1)))
  func runsInlineScriptUnderTheDefaultPolicy() async throws {
    // The whole point of keeping 'unsafe-inline'/'unsafe-eval': agent-written
    // reports are inline script, and a policy that blocks them renders nothing.
    let page = try Self.makeFixture(
      html: """
        <!doctype html>
        <html><body><div id="out"></div>
        <script>
          document.getElementById('out').textContent = 'scripted';
          document.title = eval("'evaluated'");
        </script>
        </body></html>
        """,
      css: nil
    )
    defer { try? FileManager.default.removeItem(at: page.deletingLastPathComponent()) }

    let (coordinator, webView) = await Self.load(page)
    defer { coordinator.tearDown(webView) }

    let text = try await webView.evaluateJavaScript("document.getElementById('out').textContent") as? String
    #expect(text == "scripted")
    let title = try await webView.evaluateJavaScript("document.title") as? String
    #expect(title == "evaluated")
  }

  @Test(.timeLimit(.minutes(1)))
  func deniesSecretSiblingRequestedByThePage() async throws {
    let page = try Self.makeFixture(
      html: """
        <!doctype html>
        <html><head><link rel="stylesheet" href=".env"></head><body>x</body></html>
        """,
      css: nil
    )
    let directory = page.deletingLastPathComponent()
    try Data("SECRET=1".utf8).write(to: directory.appending(path: ".env"))
    defer { try? FileManager.default.removeItem(at: directory) }

    var denied: [String] = []
    let coordinator = HTMLPreviewWebView.Coordinator(fileURL: page, isTrusted: false)
    coordinator.onBlockedResource = { denied.append($0) }
    let webView = coordinator.makeWebView()
    await withCheckedContinuation { continuation in
      coordinator.onNavigationSettled = { continuation.resume() }
    }
    coordinator.onNavigationSettled = nil
    defer { coordinator.tearDown(webView) }

    #expect(denied.contains(".env"))
  }
}
