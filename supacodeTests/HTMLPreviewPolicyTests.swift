import Foundation
import Testing

@testable import supacode

struct HTMLPreviewPolicyTests {
  // MARK: - Classification

  @Test func previewableByExtension() {
    #expect(HTMLPreviewPolicy.isPreviewable(url: URL(filePath: "/r/report.html")))
    #expect(HTMLPreviewPolicy.isPreviewable(url: URL(filePath: "/r/index.htm")))
    #expect(HTMLPreviewPolicy.isPreviewable(url: URL(filePath: "/r/REPORT.HTML")))
    #expect(!HTMLPreviewPolicy.isPreviewable(url: URL(filePath: "/r/notes.md")))
    #expect(!HTMLPreviewPolicy.isPreviewable(url: URL(filePath: "/r/main.swift")))
    // SVG is XML we edit as text, not a page we render.
    #expect(!HTMLPreviewPolicy.isPreviewable(url: URL(filePath: "/r/icon.svg")))
  }

  // MARK: - Content Security Policy

  @Test func untrustedPolicyBlocksAllNetwork() {
    let csp = HTMLPreviewPolicy.contentSecurityPolicy(trusted: false)
    // The load-bearing directive: JS runs, but cannot phone home.
    #expect(csp.contains("connect-src 'none'"))
    #expect(!csp.contains("https:"))
    #expect(csp.contains("object-src 'none'"))
    #expect(csp.contains("base-uri 'none'"))
    #expect(csp.contains("form-action 'none'"))
  }

  @Test func untrustedPolicyStillAllowsInlineScriptAndEval() {
    // Agent-generated HTML is inline <script> and eval-happy charting libs;
    // without these the page renders blank and the feature is pointless.
    let csp = HTMLPreviewPolicy.contentSecurityPolicy(trusted: false)
    #expect(csp.contains("'unsafe-inline'"))
    #expect(csp.contains("'unsafe-eval'"))
    #expect(csp.contains("data:"))
    #expect(csp.contains("blob:"))
  }

  @Test func trustedPolicyAllowsHTTPSButKeepsHardLimits() {
    let csp = HTMLPreviewPolicy.contentSecurityPolicy(trusted: true)
    #expect(csp.contains("connect-src"))
    #expect(!csp.contains("connect-src 'none'"))
    #expect(csp.contains("https:"))
    // Relaxing the CDN case must not re-open plugin content or form posts.
    #expect(csp.contains("object-src 'none'"))
    #expect(csp.contains("form-action 'none'"))
  }

  // MARK: - MIME mapping

  @Test func mimeTypeMapping() {
    #expect(HTMLPreviewPolicy.mimeType(forPathExtension: "html") == "text/html")
    #expect(HTMLPreviewPolicy.mimeType(forPathExtension: "HTML") == "text/html")
    #expect(HTMLPreviewPolicy.mimeType(forPathExtension: "css") == "text/css")
    #expect(HTMLPreviewPolicy.mimeType(forPathExtension: "js") == "text/javascript")
    #expect(HTMLPreviewPolicy.mimeType(forPathExtension: "mjs") == "text/javascript")
    #expect(HTMLPreviewPolicy.mimeType(forPathExtension: "json") == "application/json")
    #expect(HTMLPreviewPolicy.mimeType(forPathExtension: "svg") == "image/svg+xml")
    #expect(HTMLPreviewPolicy.mimeType(forPathExtension: "png") == "image/png")
    #expect(HTMLPreviewPolicy.mimeType(forPathExtension: "woff2") == "font/woff2")
    // Unknown extensions must not be sniffed as HTML.
    #expect(HTMLPreviewPolicy.mimeType(forPathExtension: "sqlite3") == "application/octet-stream")
    #expect(HTMLPreviewPolicy.mimeType(forPathExtension: "") == "application/octet-stream")
  }

  // MARK: - Path resolution

  private static let root = URL(filePath: "/repo/docs", directoryHint: .isDirectory)

  @Test func resolvesSiblingAssets() {
    let css = HTMLPreviewPolicy.resolve(requestPath: "/style.css", in: Self.root, entryFileName: "report.html")
    #expect(css?.path(percentEncoded: false) == "/repo/docs/style.css")

    let nested = HTMLPreviewPolicy.resolve(requestPath: "/assets/app.js", in: Self.root, entryFileName: "report.html")
    #expect(nested?.path(percentEncoded: false) == "/repo/docs/assets/app.js")
  }

  @Test func resolvesPercentEncodedNames() {
    let spaced = HTMLPreviewPolicy.resolve(
      requestPath: "/my%20chart.png",
      in: Self.root,
      entryFileName: "report.html"
    )
    #expect(spaced?.path(percentEncoded: false) == "/repo/docs/my chart.png")
  }

  @Test func rejectsTraversalOutsideRoot() {
    #expect(
      HTMLPreviewPolicy.resolve(requestPath: "/../secrets.txt", in: Self.root, entryFileName: "report.html") == nil
    )
    #expect(
      HTMLPreviewPolicy.resolve(
        requestPath: "/../../etc/passwd",
        in: Self.root,
        entryFileName: "report.html"
      ) == nil
    )
    #expect(
      HTMLPreviewPolicy.resolve(
        requestPath: "/assets/../../outside.js",
        in: Self.root,
        entryFileName: "report.html"
      ) == nil
    )
  }

  @Test func rejectsPercentEncodedTraversal() {
    // A page cannot smuggle `..` past the guard by encoding the separator.
    #expect(
      HTMLPreviewPolicy.resolve(
        requestPath: "/%2e%2e%2fsecrets.txt",
        in: Self.root,
        entryFileName: "report.html"
      ) == nil
    )
  }

  @Test func rejectsPrefixSiblingDirectory() {
    // "/repo/docs-private" shares a string prefix with "/repo/docs" but is not
    // inside it; a naive hasPrefix check would let it through.
    #expect(
      HTMLPreviewPolicy.resolve(
        requestPath: "/../docs-private/leak.js",
        in: Self.root,
        entryFileName: "report.html"
      ) == nil
    )
  }

  @Test func deniesSecretBearingFiles() {
    let denied = [
      "/.env", "/.env.local", "/.git/config", "/deploy.pem", "/server.key",
      "/id_rsa", "/id_ed25519", "/.netrc", "/.npmrc", "/creds.p12",
    ]
    for path in denied {
      #expect(
        HTMLPreviewPolicy.resolve(requestPath: path, in: Self.root, entryFileName: "report.html") == nil,
        "expected \(path) to be denied"
      )
    }
  }

  @Test func deniesSecretsInNestedDirectories() {
    #expect(
      HTMLPreviewPolicy.resolve(
        requestPath: "/assets/.env",
        in: Self.root,
        entryFileName: "report.html"
      ) == nil
    )
    #expect(
      HTMLPreviewPolicy.resolve(
        requestPath: "/.git/objects/ab/cdef",
        in: Self.root,
        entryFileName: "report.html"
      ) == nil
    )
  }

  @Test func entryDocumentIsAlwaysServed() {
    // The user explicitly opened this file, so the denylist must not shadow it
    // even when its name looks secret-ish.
    let entry = HTMLPreviewPolicy.resolve(requestPath: "/.env.html", in: Self.root, entryFileName: ".env.html")
    #expect(entry?.path(percentEncoded: false) == "/repo/docs/.env.html")

    // …but only that exact name, not every dotfile alongside it.
    #expect(
      HTMLPreviewPolicy.resolve(requestPath: "/.env", in: Self.root, entryFileName: ".env.html") == nil
    )
  }

  @Test func emptyRequestPathServesEntryDocument() {
    let root = HTMLPreviewPolicy.resolve(requestPath: "/", in: Self.root, entryFileName: "report.html")
    #expect(root?.path(percentEncoded: false) == "/repo/docs/report.html")
  }

  // MARK: - Preview URL

  @Test func previewURLUsesCustomScheme() {
    let url = HTMLPreviewPolicy.previewURL(forEntryFileName: "report.html")
    #expect(url?.scheme == HTMLPreviewPolicy.scheme)
    #expect(url?.path(percentEncoded: false) == "/report.html")
    // A reserved scheme would throw when registered as a handler.
    #expect(HTMLPreviewPolicy.scheme != "file")
    #expect(HTMLPreviewPolicy.scheme != "http")
    #expect(HTMLPreviewPolicy.scheme != "https")
  }
}
