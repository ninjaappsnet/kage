import AppKit
import SupacodeSettingsShared
import SwiftUI
import WebKit

/// Renders an HTML document as a live page — CSS, JavaScript, canvas and all —
/// which is the point: agent-written reports are interactive, and a static
/// render of one is not worth much.
///
/// AppKit rather than SwiftUI because there is no SwiftUI web view that exposes
/// the pieces that make this safe to do: a custom scheme handler, a
/// non-persistent data store, and navigation/UI delegates.
struct HTMLPreviewWebView: NSViewRepresentable {
  let fileURL: URL
  let isTrusted: Bool
  let onBlockedResource: (String) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(fileURL: fileURL, isTrusted: isTrusted)
  }

  func makeNSView(context: Context) -> WKWebView {
    context.coordinator.onBlockedResource = onBlockedResource
    return context.coordinator.makeWebView()
  }

  func updateNSView(_ webView: WKWebView, context: Context) {
    context.coordinator.onBlockedResource = onBlockedResource
    context.coordinator.apply(isTrusted: isTrusted, to: webView)
  }

  static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
    coordinator.tearDown(webView)
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    /// The page reports its own blocked loads here; native only counts them.
    /// One-way by design — nothing the page sends can reach app state.
    private static let violationMessageName = "kagePreviewCSP"

    /// `securitypolicyviolation` is the only signal that a page came out wrong
    /// because the policy stopped it, as opposed to being broken on its own.
    private static let violationReporter = """
      document.addEventListener('securitypolicyviolation', function (event) {
        try {
          window.webkit.messageHandlers.\(violationMessageName).postMessage(
            String(event.blockedURI || event.violatedDirective || '')
          );
        } catch (error) {}
      });
      """

    var onBlockedResource: (String) -> Void = { _ in }

    /// Fires once the page has either finished or given up loading.
    var onNavigationSettled: (() -> Void)?

    private let handler: HTMLPreviewSchemeHandler
    private let entryFileName: String
    private var appliedTrust: Bool

    init(fileURL: URL, isTrusted: Bool) {
      // The document's own directory is the root, not the worktree: a report
      // reaches its sibling stylesheet and nothing above it, so `.env` and
      // `.git` are out of scope before any denylist is consulted.
      entryFileName = fileURL.lastPathComponent
      handler = HTMLPreviewSchemeHandler(
        rootDirectory: fileURL.deletingLastPathComponent(),
        entryFileName: fileURL.lastPathComponent
      )
      appliedTrust = isTrusted
      super.init()
      handler.isTrusted = isTrusted
      handler.onDeniedRequest = { [weak self] url in
        self?.onBlockedResource(url.lastPathComponent)
      }
    }

    func makeWebView() -> WKWebView {
      let configuration = WKWebViewConfiguration()
      // Nothing the page stores outlives the preview: no cookies, no
      // localStorage, no cache shared with anything else.
      configuration.websiteDataStore = .nonPersistent()
      configuration.defaultWebpagePreferences.allowsContentJavaScript = true
      configuration.setURLSchemeHandler(handler, forURLScheme: HTMLPreviewPolicy.scheme)
      configuration.userContentController.addUserScript(
        WKUserScript(source: Self.violationReporter, injectionTime: .atDocumentStart, forMainFrameOnly: false)
      )
      configuration.userContentController.add(self, name: Self.violationMessageName)

      let webView = WKWebView(frame: .zero, configuration: configuration)
      webView.navigationDelegate = self
      webView.uiDelegate = self
      webView.allowsBackForwardNavigationGestures = false
      webView.allowsMagnification = true
      // Avoids a white flash under a dark appearance before the page paints.
      webView.underPageBackgroundColor = .textBackgroundColor
      #if DEBUG
        webView.isInspectable = true
      #endif
      load(into: webView)
      return webView
    }

    func apply(isTrusted: Bool, to webView: WKWebView) {
      guard isTrusted != appliedTrust else { return }
      appliedTrust = isTrusted
      handler.isTrusted = isTrusted
      // The policy arrives as a response header, so re-requesting the document
      // is what applies it. `reload()` would be enough today, but an explicit
      // load also recovers a page that failed its first navigation.
      load(into: webView)
    }

    func tearDown(_ webView: WKWebView) {
      webView.stopLoading()
      webView.navigationDelegate = nil
      webView.uiDelegate = nil
      // The content controller retains this coordinator; without the removal the
      // web view and its process outlive the panel.
      webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.violationMessageName)
      webView.configuration.userContentController.removeAllUserScripts()
    }

    private func load(into webView: WKWebView) {
      guard let url = HTMLPreviewPolicy.previewURL(forEntryFileName: entryFileName) else { return }
      webView.load(URLRequest(url: url))
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      guard message.name == Self.violationMessageName, let blocked = message.body as? String else { return }
      onBlockedResource(blocked)
    }

    // MARK: - WKNavigationDelegate

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = navigationAction.request.url else {
        decisionHandler(.cancel)
        return
      }
      if url.scheme == HTMLPreviewPolicy.scheme {
        decisionHandler(.allow)
        return
      }
      // Only a click leaves the preview, and it leaves to the browser — an
      // automatic redirect to an external URL is silently dropped instead.
      if navigationAction.navigationType == .linkActivated, let scheme = url.scheme,
        scheme == "http" || scheme == "https"
      {
        NSWorkspace.shared.open(url)
      }
      decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      onNavigationSettled?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
      onNavigationSettled?()
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: any Error
    ) {
      onNavigationSettled?()
    }

    // MARK: - WKUIDelegate

    func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      // `window.open` gets no second web view; the navigation delegate above
      // has already routed anything worth opening to the browser.
      nil
    }

    /// The JavaScript dialog family below is not optional. WebKit blocks the
    /// page until the delegate answers, and a `WKUIDelegate` that omits these
    /// never answers — so a single `alert()` in an agent-written file would wedge
    /// the preview permanently.
    func webView(
      _ webView: WKWebView,
      runJavaScriptAlertPanelWithMessage message: String,
      initiatedByFrame frame: WKFrameInfo,
      completionHandler: @escaping () -> Void
    ) {
      let alert = Self.alert(message: message)
      alert.addButton(withTitle: "OK")
      Self.present(alert, over: webView) { _ in completionHandler() }
    }

    func webView(
      _ webView: WKWebView,
      runJavaScriptConfirmPanelWithMessage message: String,
      initiatedByFrame frame: WKFrameInfo,
      completionHandler: @escaping (Bool) -> Void
    ) {
      let alert = Self.alert(message: message)
      alert.addButton(withTitle: "OK")
      alert.addButton(withTitle: "Cancel")
      Self.present(alert, over: webView) { response in
        completionHandler(response == .alertFirstButtonReturn)
      }
    }

    func webView(
      _ webView: WKWebView,
      runJavaScriptTextInputPanelWithPrompt prompt: String,
      defaultText: String?,
      initiatedByFrame frame: WKFrameInfo,
      completionHandler: @escaping (String?) -> Void
    ) {
      let alert = Self.alert(message: prompt)
      alert.addButton(withTitle: "OK")
      alert.addButton(withTitle: "Cancel")
      let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
      field.stringValue = defaultText ?? ""
      alert.accessoryView = field
      Self.present(alert, over: webView) { response in
        completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
      }
    }

    private static func alert(message: String) -> NSAlert {
      let alert = NSAlert()
      alert.alertStyle = .informational
      // Named so it is unmistakably the previewed document talking, not the app.
      alert.messageText = "Preview"
      alert.informativeText = message
      return alert
    }

    private static func present(
      _ alert: NSAlert,
      over webView: WKWebView,
      completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
      if let window = webView.window {
        alert.beginSheetModal(for: window) { response in completion(response) }
      } else {
        completion(alert.runModal())
      }
    }
  }
}
