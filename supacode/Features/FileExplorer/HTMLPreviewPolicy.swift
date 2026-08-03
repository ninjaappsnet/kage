import Foundation

/// Pure policy for the HTML preview: which files render as a page, the Content
/// Security Policy each trust level gets, the extension-to-MIME mapping, and the
/// request guard that keeps a page inside its own directory and away from
/// credential files. Caseless enum so it stays one namespace and unit-testable
/// without WebKit or I/O.
enum HTMLPreviewPolicy {
  /// Previewed documents are served over a private scheme instead of `file:`.
  /// A custom scheme gives the page a normal origin (so CSP applies the way it
  /// would on the web), routes every byte through `resolve(requestPath:in:entryFileName:)`,
  /// and lets the policy ride in as a response header — so the file on disk is
  /// never rewritten. WebKit reserves `file`/`http`/`https`/`about`/`data`/`blob`
  /// and throws when a handler is registered for one, hence the custom name.
  static let scheme = "kage-preview"
  static let host = "preview"

  private static let previewableExtensions: Set<String> = ["html", "htm"]

  /// True for documents rendered as a live page. SVG is deliberately excluded:
  /// it is XML we edit as text, not a page.
  static func isPreviewable(url: URL) -> Bool {
    previewableExtensions.contains(url.pathExtension.lowercased())
  }

  // MARK: - Content Security Policy

  /// The policy served with every preview response.
  ///
  /// Untrusted is the default and the interesting case: scripts still run —
  /// agent-written HTML is inline `<script>` and eval-happy charting libraries,
  /// so stripping `'unsafe-inline'`/`'unsafe-eval'` would render a blank page and
  /// make the feature pointless — but `connect-src 'none'` removes every egress
  /// channel (fetch, XHR, WebSocket, `sendBeacon`). JS executes; it cannot report
  /// what it saw.
  ///
  /// Trusted is opt-in per document, for pages that pull Chart.js/Tailwind/D3
  /// from a CDN and otherwise render empty. It reopens HTTPS only; plugin
  /// content, base-URI rewriting and form submission stay closed at both levels.
  static func contentSecurityPolicy(trusted: Bool) -> String {
    let this = "\(scheme):"
    let remote = trusted ? " https:" : ""
    let directives = [
      "default-src 'self' \(this)\(remote)",
      "script-src 'self' 'unsafe-inline' 'unsafe-eval' \(this) blob:\(remote)",
      "style-src 'self' 'unsafe-inline' \(this)\(remote)",
      "img-src 'self' \(this) data: blob:\(remote)",
      "font-src 'self' \(this) data:\(remote)",
      "media-src 'self' \(this) data: blob:\(remote)",
      trusted ? "connect-src 'self' https:" : "connect-src 'none'",
      trusted ? "frame-src https:" : "frame-src 'none'",
      "object-src 'none'",
      "base-uri 'none'",
      "form-action 'none'",
    ]
    return directives.joined(separator: "; ")
  }

  // MARK: - MIME types

  private static let mimeTypeByExtension: [String: String] = [
    "html": "text/html", "htm": "text/html",
    "css": "text/css",
    "js": "text/javascript", "mjs": "text/javascript", "cjs": "text/javascript",
    "json": "application/json", "map": "application/json",
    "svg": "image/svg+xml",
    "png": "image/png",
    "jpg": "image/jpeg", "jpeg": "image/jpeg",
    "gif": "image/gif",
    "webp": "image/webp",
    "avif": "image/avif",
    "bmp": "image/bmp",
    "ico": "image/x-icon",
    "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
    "txt": "text/plain", "md": "text/plain", "csv": "text/csv",
    "xml": "application/xml",
    "wasm": "application/wasm",
    "pdf": "application/pdf",
    "mp4": "video/mp4", "webm": "video/webm", "mov": "video/quicktime",
    "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg",
  ]

  /// Falls back to `application/octet-stream` so an unknown extension is never
  /// sniffed into `text/html` and executed as a document.
  static func mimeType(forPathExtension pathExtension: String) -> String {
    mimeTypeByExtension[pathExtension.lowercased()] ?? "application/octet-stream"
  }

  // MARK: - Request resolution

  private static let deniedFileNames: Set<String> = [
    "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
    ".netrc", ".npmrc", ".pypirc", ".htpasswd", ".dockercfg",
  ]

  private static let deniedDirectoryNames: Set<String> = [".git", ".ssh", ".gnupg", ".aws"]

  private static let deniedExtensions: Set<String> = ["pem", "key", "p12", "pfx", "jks", "keystore", "ppk", "asc"]

  /// Maps a request path onto a file inside `root`, or `nil` when the request
  /// must be refused.
  ///
  /// Two independent guards. Containment: the standardized path must sit under
  /// `root` — compared with a trailing separator so `/repo/docs-private` cannot
  /// pass as `/repo/docs`, and again after symlink resolution so a link inside
  /// the directory cannot point out of it. Screening: no path component may name
  /// a credential store, which is what stops a page from `<img src>`-ing `.env`
  /// into an attacker-visible load.
  ///
  /// `entryFileName` is the document the user explicitly opened. It bypasses the
  /// screen — never the containment check — so a file named `.env.html` still
  /// previews, while a sibling `.env` it tries to fetch does not.
  static func resolve(requestPath: String, in root: URL, entryFileName: String) -> URL? {
    // Decode before any `..` inspection so an encoded separator (`%2e%2e%2f`)
    // cannot smuggle a traversal past the containment check.
    var relative = requestPath.removingPercentEncoding ?? requestPath
    if let query = relative.firstIndex(of: "?") { relative = String(relative[..<query]) }
    if let fragment = relative.firstIndex(of: "#") { relative = String(relative[..<fragment]) }
    while relative.hasPrefix("/") { relative.removeFirst() }
    if relative.isEmpty { relative = entryFileName }

    var rootPath = root.standardizedFileURL.path(percentEncoded: false)
    while rootPath.count > 1, rootPath.hasSuffix("/") { rootPath.removeLast() }

    let candidate = URL(filePath: rootPath, directoryHint: .isDirectory)
      .appending(path: relative)
      .standardizedFileURL
    let candidatePath = candidate.path(percentEncoded: false)

    let prefix = rootPath + "/"
    guard candidatePath.hasPrefix(prefix) else { return nil }

    // Non-existent paths resolve to themselves, so this is a no-op for assets
    // that simply aren't there and only bites on a real escaping symlink.
    let resolvedRoot = URL(filePath: rootPath).resolvingSymlinksInPath().path(percentEncoded: false)
    let resolvedCandidate = candidate.resolvingSymlinksInPath().path(percentEncoded: false)
    let resolvedPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
    guard resolvedCandidate.hasPrefix(resolvedPrefix) else { return nil }

    let components = candidatePath.dropFirst(prefix.count).split(separator: "/").map(String.init)
    guard !components.isEmpty else { return nil }
    if components == [entryFileName] { return candidate }
    guard !components.contains(where: isDenied) else { return nil }
    return candidate
  }

  private static func isDenied(_ component: String) -> Bool {
    let lowercased = component.lowercased()
    if lowercased.hasPrefix(".env") { return true }
    if deniedDirectoryNames.contains(lowercased) { return true }
    if deniedFileNames.contains(lowercased) { return true }
    return deniedExtensions.contains(URL(filePath: lowercased).pathExtension)
  }

  /// The URL the web view loads for `entryFileName`. Relative references inside
  /// the document then resolve against it and come back through the handler.
  static func previewURL(forEntryFileName entryFileName: String) -> URL? {
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.path = "/" + entryFileName
    return components.url
  }
}
