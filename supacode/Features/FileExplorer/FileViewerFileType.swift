import Foundation

/// Pure classification helpers for the file viewer: text-vs-binary sniffing,
/// markdown detection (by extension, well-known filename, or content), and the
/// mapping from a file's extension to a highlight.js language id. Caseless enum
/// so these live in one namespace and stay unit-testable without I/O.
enum FileViewerFileType {
  /// Files larger than this are not loaded into the editor (kept responsive).
  static let maxEditableBytes = 5 * 1024 * 1024

  /// Above this size syntax highlighting is disabled: Highlightr re-highlights
  /// the whole document on every keystroke, which janks on large files. The file
  /// stays editable as plain monospaced text.
  static let maxHighlightBytes = 256 * 1024

  /// Media files are previewed (not loaded as text), so they get a larger cap.
  static let maxMediaBytes = 50 * 1024 * 1024

  /// A previewable, non-text media file.
  enum MediaKind: Equatable { case image, pdf }

  /// Image extensions `NSImage` decodes reliably. SVG is intentionally excluded —
  /// it's XML, so it opens as editable source instead.
  private static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "icns", "ico",
  ]

  /// Classifies `url` as previewable media, or `nil` for everything else (which
  /// is then handled as text/binary).
  static func mediaKind(for url: URL) -> MediaKind? {
    let ext = url.pathExtension.lowercased()
    if ext == "pdf" { return .pdf }
    if imageExtensions.contains(ext) { return .image }
    return nil
  }

  /// How many leading bytes to inspect when sniffing binary content.
  private static let binarySniffByteCount = 8192

  /// A file is treated as binary if its leading bytes contain a NUL, which no
  /// UTF-8 text file does. Cheap and matches what `git` does for "binary".
  static func isProbablyBinary(_ data: Data) -> Bool {
    data.prefix(binarySniffByteCount).contains(0)
  }

  private static let markdownExtensions: Set<String> = [
    "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "rmd",
  ]

  /// Lowercased filename stems that render as markdown even without a `.md`
  /// extension — mirrors Warp (README / LICENSE / CHANGELOG render as markdown).
  private static let markdownFilenameStems: Set<String> = [
    "readme", "license", "licence", "changelog", "contributing", "authors",
    "notice", "copying", "code_of_conduct", "history", "news",
  ]

  /// Whether `url` should render as markdown. Extension wins; then a known
  /// extension-less filename (LICENSE, README…); then a light content sniff so a
  /// `.txt` that is clearly markdown still renders. The sniff is skipped for
  /// dotfiles and recognized code/config files, whose `#` comments would
  /// otherwise be misread as markdown headings (e.g. `.gitignore`, `Makefile`).
  static func isMarkdown(url: URL, sample: String) -> Bool {
    let ext = url.pathExtension.lowercased()
    if markdownExtensions.contains(ext) { return true }
    if ext.isEmpty {
      let stem = url.deletingPathExtension().lastPathComponent.lowercased()
      if markdownFilenameStems.contains(stem) { return true }
    }
    // `.gitignore`, `.env`, … are config, not markdown.
    if url.lastPathComponent.hasPrefix(".") { return false }
    // Makefile, *.sh, *.py, *.yaml, … — a recognized language uses `#` for
    // comments, not headings.
    if highlightrLanguage(for: url) != nil { return false }
    return contentLooksLikeMarkdown(sample)
  }

  /// Conservative content heuristic: the first non-empty line is an ATX heading
  /// (`# `…`###### `) or a fenced code block. Looking only at the first line keeps
  /// a stray `#` comment deeper in a file from being misread as markdown.
  private static func contentLooksLikeMarkdown(_ sample: String) -> Bool {
    for rawLine in sample.split(separator: "\n", omittingEmptySubsequences: true).prefix(40) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      if line.hasPrefix("```") || line.hasPrefix("~~~") { return true }
      guard line.first == "#", let nonHash = line.firstIndex(where: { $0 != "#" }) else { return false }
      let hashes = line.distance(from: line.startIndex, to: nonHash)
      return (1...6).contains(hashes) && line[nonHash] == " "
    }
    return false
  }

  /// Maps a file extension (or well-known filename) to a highlight.js language
  /// id. `nil` lets Highlightr auto-detect, which is the right default for an
  /// unrecognized text file.
  static func highlightrLanguage(for url: URL) -> String? {
    let name = url.lastPathComponent.lowercased()
    if name == "dockerfile" || name.hasPrefix("dockerfile.") { return "dockerfile" }
    if name == "makefile" || name == "gnumakefile" { return "makefile" }
    if name == "cmakelists.txt" { return "cmake" }
    return languageByExtension[url.pathExtension.lowercased()]
  }

  /// File-extension → highlight.js language id. A plain table keeps
  /// `highlightrLanguage(for:)` simple instead of a sprawling switch.
  private static let languageByExtension: [String: String] = [
    "swift": "swift",
    "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
    "ts": "typescript", "tsx": "typescript",
    "py": "python", "pyw": "python",
    "rb": "ruby",
    "go": "go",
    "rs": "rust",
    "c": "c", "h": "c",
    "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp",
    "m": "objectivec", "mm": "objectivec",
    "java": "java",
    "kt": "kotlin", "kts": "kotlin",
    "cs": "csharp",
    "php": "php",
    "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash",
    "zig": "zig",
    "json": "json",
    "yaml": "yaml", "yml": "yaml",
    "toml": "ini", "ini": "ini", "cfg": "ini", "conf": "ini",
    "xml": "xml", "plist": "xml", "svg": "xml", "xib": "xml", "storyboard": "xml",
    "html": "xml", "htm": "xml",
    "css": "css",
    "scss": "scss", "sass": "scss",
    "less": "less",
    "sql": "sql",
    "lua": "lua",
    "r": "r",
    "scala": "scala",
    "dart": "dart",
    "ex": "elixir", "exs": "elixir",
    "erl": "erlang",
    "hs": "haskell",
    "pl": "perl", "pm": "perl",
    "diff": "diff", "patch": "diff",
    "gradle": "gradle",
    "proto": "protobuf",
    "vim": "vim",
    "md": "markdown", "markdown": "markdown",
  ]
}
