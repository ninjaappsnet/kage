import Foundation
import Testing
import WebKit

@testable import supacode

/// The preview's scheme handler answering from a `FileSystemSource` rather than
/// the disk, so a page on a remote host still loads its relative stylesheet and
/// scripts. Driven with a fake scheme task: what matters is which bytes and
/// headers come back, and that a stopped task is never answered (WebKit throws
/// when one is).
@MainActor
struct HTMLPreviewSchemeHandlerSourceTests {
  private final class FakeSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var response: URLResponse?
    private(set) var body = Data()
    private(set) var finished = false
    private(set) var failure: (any Error)?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated deinit {}

    init(path: String) {
      request = URLRequest(url: URL(string: "\(HTMLPreviewPolicy.scheme)://\(HTMLPreviewPolicy.host)\(path)")!)
    }

    var isSettled: Bool { finished || failure != nil }

    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) { body.append(data) }

    func didFinish() {
      finished = true
      settle()
    }

    func didFailWithError(_ error: any Error) {
      failure = error
      settle()
    }

    func settled() async {
      guard !isSettled else { return }
      await withCheckedContinuation { waiters.append($0) }
    }

    private func settle() {
      let pending = waiters
      waiters.removeAll()
      for waiter in pending { waiter.resume() }
    }
  }

  private static func makeSource() -> InMemoryFileSystemSource {
    let source = InMemoryFileSystemSource()
    source.addFile("/remote/report/page.html", "<link rel=\"stylesheet\" href=\"style.css\">")
    source.addFile("/remote/report/style.css", "body { color: red; }")
    source.addFile("/remote/report/.env", "SECRET=1")
    return source
  }

  private static func makeHandler(source: InMemoryFileSystemSource) -> HTMLPreviewSchemeHandler {
    HTMLPreviewSchemeHandler(
      rootDirectory: URL(filePath: "/remote/report", directoryHint: .isDirectory),
      entryFileName: "page.html",
      source: source
    )
  }

  @Test func servesARelativeAssetFromTheSource() async throws {
    let source = Self.makeSource()
    let handler = Self.makeHandler(source: source)
    let task = FakeSchemeTask(path: "/style.css")

    handler.webView(WKWebView(), start: task)
    await task.settled()

    #expect(task.finished)
    #expect(String(bytes: task.body, encoding: .utf8) == "body { color: red; }")
    let response = try #require(task.response as? HTTPURLResponse)
    #expect(response.value(forHTTPHeaderField: "Content-Type") == "text/css")
    #expect(response.value(forHTTPHeaderField: "Content-Security-Policy") != nil)
    #expect(source.readPaths == ["/remote/report/style.css"])
  }

  @Test func servesTheEntryDocumentForTheRoot() async {
    let source = Self.makeSource()
    let handler = Self.makeHandler(source: source)
    let task = FakeSchemeTask(path: "/")

    handler.webView(WKWebView(), start: task)
    await task.settled()

    #expect(task.finished)
    #expect(source.readPaths == ["/remote/report/page.html"])
  }

  @Test func aDeniedRequestNeverReachesTheSource() async {
    let source = Self.makeSource()
    let handler = Self.makeHandler(source: source)
    var denied: [String] = []
    handler.onDeniedRequest = { denied.append($0.lastPathComponent) }
    let task = FakeSchemeTask(path: "/.env")

    handler.webView(WKWebView(), start: task)
    await task.settled()

    #expect(task.failure != nil)
    #expect(denied == [".env"])
    #expect(source.readPaths.isEmpty)
  }

  @Test func aMissingAssetFailsTheRequest() async {
    let source = Self.makeSource()
    let handler = Self.makeHandler(source: source)
    let task = FakeSchemeTask(path: "/missing.js")

    handler.webView(WKWebView(), start: task)
    await task.settled()

    #expect(task.failure != nil)
    #expect(!task.finished)
  }

  /// A page on this Mac is answered before `start` returns, as it was before the
  /// source seam: an async read waits for a free thread in the shared pool, and a
  /// busy pool (CI's test run) stalled whole pages past their time limit.
  @Test func aLocalPageIsAnsweredBeforeStartReturns() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "preview-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("<p>x</p>".utf8).write(to: directory.appending(path: "page.html"))
    let handler = HTMLPreviewSchemeHandler(
      rootDirectory: directory,
      entryFileName: "page.html",
      source: LocalFileSystemSource()
    )
    let task = FakeSchemeTask(path: "/")

    handler.webView(WKWebView(), start: task)

    #expect(task.finished)
    #expect(String(bytes: task.body, encoding: .utf8) == "<p>x</p>")
  }

  @Test func aStoppedTaskIsNeverAnswered() async {
    let source = Self.makeSource()
    source.holdReads()
    let handler = Self.makeHandler(source: source)
    let webView = WKWebView()
    let stopped = FakeSchemeTask(path: "/style.css")

    handler.webView(webView, start: stopped)
    while source.heldReadCount < 1 { await Task.yield() }
    handler.webView(webView, stop: stopped)
    source.releaseReads()

    // A later request on the same handler settles only after the stopped one's
    // read came back, so by then the stopped task would have been answered.
    let later = FakeSchemeTask(path: "/page.html")
    handler.webView(webView, start: later)
    await later.settled()

    #expect(!stopped.isSettled)
    #expect(stopped.response == nil)
  }
}
