import Foundation

/// Three-way merge for JSON settings, so two machines changing different keys of
/// `settings.json` never need a human (or a model) to reconcile them.
///
/// Objects merge key by key; arrays merge as ordered sets (both sides' additions
/// kept, either side's removals honored), which is what permission and plugin
/// lists mean; a scalar both sides changed differently keeps the local value and
/// is reported.
nonisolated enum DotfilesJSONMerge {
  indirect enum Value: Equatable, Sendable {
    case object([String: Value])
    case array([Value])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    static func parse(_ data: Data) throws -> Value {
      Value(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(_ any: Any) {
      switch any {
      case let dictionary as [String: Any]: self = .object(dictionary.mapValues(Value.init))
      case let array as [Any]: self = .array(array.map(Value.init))
      case let string as String: self = .string(string)
      case let number as NSNumber:
        self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
      default: self = .null
      }
    }

    var any: Any {
      switch self {
      case .object(let dictionary): dictionary.mapValues(\.any)
      case .array(let array): array.map(\.any)
      case .string(let string): string
      case .number(let number): number.rounded() == number && abs(number) < 1e15 ? Int(number) as Any : number
      case .bool(let bool): bool
      case .null: NSNull()
      }
    }

    func serialized() throws -> Data {
      var data = try JSONSerialization.data(
        withJSONObject: any,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
      )
      data.append(contentsOf: Array("\n".utf8))
      return data
    }
  }

  struct Result: Equatable {
    var value: Value?
    /// Dotted paths where both sides changed a value differently; ours was kept.
    var conflicts: [String]
  }

  static func merge(base: Value?, ours: Value?, theirs: Value?) -> Result {
    var conflicts: [String] = []
    let value = merge(base: base, ours: ours, theirs: theirs, path: [], conflicts: &conflicts)
    return Result(value: value, conflicts: conflicts)
  }

  private static func merge(
    base: Value?,
    ours: Value?,
    theirs: Value?,
    path: [String],
    conflicts: inout [String]
  ) -> Value? {
    if ours == theirs { return ours }
    if base == ours { return theirs }
    if base == theirs { return ours }
    switch (ours, theirs) {
    case (.object(let mine), .object(let other)):
      var baseObject: [String: Value] = [:]
      if case .object(let object) = base { baseObject = object }
      var merged: [String: Value] = [:]
      for key in Set(mine.keys).union(other.keys).union(baseObject.keys) {
        let value = merge(
          base: baseObject[key], ours: mine[key], theirs: other[key], path: path + [key], conflicts: &conflicts
        )
        if let value { merged[key] = value }
      }
      return .object(merged)
    case (.array(let mine), .array(let other)):
      var baseItems: [Value] = []
      if case .array(let array) = base { baseItems = array }
      let removed = baseItems.filter { !mine.contains($0) || !other.contains($0) }
      var merged: [Value] = []
      for item in mine + other where !merged.contains(item) && !removed.contains(item) {
        merged.append(item)
      }
      return .array(merged)
    default:
      conflicts.append(path.joined(separator: "."))
      return ours
    }
  }
}
