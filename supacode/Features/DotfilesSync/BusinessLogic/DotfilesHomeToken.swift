import Foundation

/// Keeps synced text free of the machine's home path, so the same file works
/// under any user name: the home directory is written as `{{HOME}}` in the
/// repository and expanded back on the way out.
nonisolated enum DotfilesHomeToken {
  static let token = "{{HOME}}"

  /// Replaces `home` wherever it stands as a whole path (followed by `/`, the end,
  /// or a character that can't continue a path component), so `/Users/alice2`
  /// is left alone when home is `/Users/alice`.
  static func encode(_ text: String, home: String) -> String {
    guard !home.isEmpty, text.contains(home) else { return text }
    var result = ""
    var rest = text[...]
    while let range = rest.range(of: home) {
      let next = rest[range.upperBound...].first
      result += rest[..<range.lowerBound]
      if let next, Self.continuesPath(next) {
        result += rest[range]
      } else {
        result += token
      }
      rest = rest[range.upperBound...]
    }
    return result + rest
  }

  static func decode(_ text: String, home: String) -> String {
    text.replacing(token, with: home)
  }

  private static func continuesPath(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
  }
}
