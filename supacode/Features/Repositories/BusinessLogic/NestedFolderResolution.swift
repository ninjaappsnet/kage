import Foundation

/// A folder the user picked that is not its own repository root: `wt root`
/// walked up to an enclosing git repository Kage already tracks. Registering it
/// unchanged would dedupe against that parent and change nothing, so the user is
/// asked what they actually meant.
nonisolated struct NestedFolderCandidate: Equatable, Identifiable, Sendable {
  let folderURL: URL
  let parentRootURL: URL

  init(folderURL: URL, parentRootURL: URL) {
    self.folderURL = URL(fileURLWithPath: NestedFolderResolution.canonicalPath(folderURL))
    self.parentRootURL = URL(fileURLWithPath: NestedFolderResolution.canonicalPath(parentRootURL))
  }

  var id: String { folderURL.path(percentEncoded: false) }
  var folderName: String { folderURL.lastPathComponent }
  var parentName: String { parentRootURL.lastPathComponent }

  /// Root-anchored pattern (`/apps/shoot/`) so the entry matches this folder
  /// only, not a same-named directory elsewhere in the parent repository.
  var ignorePattern: String {
    let parentPath = parentRootURL.path(percentEncoded: false)
    let folderPath = folderURL.path(percentEncoded: false)
    guard folderPath.hasPrefix(parentPath) else { return "/\(folderName)/" }
    var relative = String(folderPath.dropFirst(parentPath.count))
    while relative.hasPrefix("/") { relative.removeFirst() }
    while relative.hasSuffix("/") { relative.removeLast() }
    return relative.isEmpty ? "/\(folderName)/" : "/\(relative)/"
  }
}

/// What to do with a folder that sits inside an already-tracked repository.
nonisolated enum NestedFolderAddAction: String, CaseIterable, Equatable, Sendable {
  /// Register the path as-is. Kage classifies it as a folder repository.
  case addAsFolder
  /// `git init` in place first, so it becomes a repository row with worktrees.
  case createGitRepository
}

/// Where the "keep it out of the parent repo's status" entry is written.
nonisolated enum NestedFolderIgnoreTarget: String, CaseIterable, Equatable, Sendable {
  case doNotIgnore
  /// `.git/info/exclude` — local only, never committed, does not dirty a shared repo.
  case localExclude
  /// The parent's tracked `.gitignore`, so the ignore travels to the team.
  case gitignore
}

nonisolated enum NestedFolderResolution {
  enum Outcome: Equatable {
    /// Business as usual: persist this root.
    case root(URL)
    /// Ambiguous pick: ask the user before touching anything.
    case nested(NestedFolderCandidate)
  }

  /// `existingRootPaths` is the already-registered set, normalized through
  /// `RepositoryPathNormalizer`. It is the intent discriminator: when the
  /// enclosing repo is already a row, the user cannot have meant "add that repo"
  /// — the add would be a no-op — so the picked subfolder is what they want.
  /// When the parent is unknown, the upstream convenience stands: picking any
  /// subdirectory of a repo adds the repo, silently.
  static func resolve(
    pickedURL: URL,
    resolvedRoot: URL,
    existingRootPaths: Set<String>
  ) -> Outcome {
    let root = resolvedRoot.standardizedFileURL
    let pickedPath = canonicalPath(pickedURL)
    let rootPath = canonicalPath(root)
    guard pickedPath != rootPath else { return .root(root) }
    guard Set(existingRootPaths.map(canonicalPath)).contains(rootPath) else { return .root(root) }
    return .nested(NestedFolderCandidate(folderURL: pickedURL, parentRootURL: root))
  }

  /// Trailing-slash-free absolute path. Both sides of every comparison here mix
  /// forms: `URL.path(percentEncoded:)` keeps a directory URL's trailing slash,
  /// and persisted roots (`routes.json`) carry one for paths that exist on disk.
  static func canonicalPath(_ path: String) -> String {
    var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
    return trimmed
  }

  static func canonicalPath(_ url: URL) -> String {
    canonicalPath(url.standardizedFileURL.path(percentEncoded: false))
  }
}
