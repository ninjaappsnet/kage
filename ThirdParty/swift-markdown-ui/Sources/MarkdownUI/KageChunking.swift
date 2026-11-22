import SwiftUI

// KAGE PATCH (see KAGE-PATCHES.md): splits content into chunks a host can lay
// out lazily. MarkdownUI lays a whole document out eagerly in one VStack, which
// took ~15 s of main-thread layout on a 2.9 MB file. A chunk boundary sits only
// between top-level blocks or between items of an oversized list, and each chunk
// carries the margins the basic theme collapses at its join, so stacking the
// chunks with `markdownChunkSpacing(_:)` reproduces the whole-document layout.

/// A run of top-level blocks from a larger `MarkdownContent`.
public struct MarkdownChunk: Equatable {
  public let content: MarkdownContent

  /// The margins that meet at the join above this chunk. The space between this
  /// chunk and the previous one is the largest of them once resolved, matching
  /// MarkdownUI's margin collapsing. Empty for the first chunk and for joins that
  /// sit flush, such as between items of a tight list.
  public let leadingMargins: [RelativeSize]
}

extension MarkdownContent {
  /// Splits the content into chunks of roughly `maxCharacters` characters of
  /// plain text each. A block larger than the limit stays whole, except a list,
  /// which splits between its items (a numbered list keeps its numbering).
  /// Margins assume the basic theme.
  public func chunked(maxCharacters: Int) -> [MarkdownChunk] {
    var chunks: [MarkdownChunk] = []
    var blocks: [BlockNode] = []
    var weight = 0
    var leadingMargins: [RelativeSize] = []
    var previous: ChunkPiece?

    for piece in ChunkPiece.pieces(of: self.blocks, maxCharacters: maxCharacters) {
      if let previous, !blocks.isEmpty, piece.isListContinuation || weight + piece.weight > maxCharacters {
        chunks.append(MarkdownChunk(content: MarkdownContent(blocks: blocks), leadingMargins: leadingMargins))
        leadingMargins = ChunkPiece.joinMargins(after: previous, before: piece)
        blocks = []
        weight = 0
      }
      blocks.append(piece.block)
      weight += piece.weight
      previous = piece
    }
    if !blocks.isEmpty {
      chunks.append(MarkdownChunk(content: MarkdownContent(blocks: blocks), leadingMargins: leadingMargins))
    }
    return chunks
  }
}

extension View {
  /// Adds the space above `chunk` that its join with the previous chunk calls for.
  public func markdownChunkSpacing(_ chunk: MarkdownChunk) -> some View {
    TextStyleAttributesReader { attributes in
      self.padding(
        .top,
        chunk.leadingMargins.map { $0.points(relativeTo: attributes.fontProperties) }.max() ?? 0
      )
    }
  }
}

/// A top-level block, or a slice of an oversized list's items.
private struct ChunkPiece {
  let block: BlockNode
  let weight: Int
  /// Set when this slice continues a list split before it.
  let isListContinuation: Bool
  let isTightList: Bool

  static func pieces(of blocks: [BlockNode], maxCharacters: Int) -> [ChunkPiece] {
    blocks.flatMap { block -> [ChunkPiece] in
      let weight = Self.weight(of: [block])
      guard weight > maxCharacters, let split = Self.splitList(block, maxCharacters: maxCharacters) else {
        return [ChunkPiece(block: block, weight: weight, isListContinuation: false, isTightList: false)]
      }
      return split
    }
  }

  /// The margins meeting between `previous` and `next`, zero ones dropped.
  static func joinMargins(after previous: ChunkPiece, before next: ChunkPiece) -> [RelativeSize] {
    // Inside a tight list a predecessor's bottom margin is ignored.
    let bottoms = next.isListContinuation && next.isTightList ? [] : margins(of: previous.block).bottom
    var result: [RelativeSize] = []
    for margin in bottoms + margins(of: next.block).top where margin.value > 0 && !result.contains(margin) {
      result.append(margin)
    }
    return result
  }

  private static func weight(of blocks: [BlockNode]) -> Int {
    MarkdownContent(blocks: blocks).renderPlainText()
      .trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
  }

  private static func splitList(_ block: BlockNode, maxCharacters: Int) -> [ChunkPiece]? {
    switch block {
    case .bulletedList(let isTight, let items):
      return Self.group(items, children: \.children, isTight: isTight, maxCharacters: maxCharacters) { slice, _ in
        .bulletedList(isTight: isTight, items: slice)
      }
    case .numberedList(let isTight, let start, let items):
      return Self.group(items, children: \.children, isTight: isTight, maxCharacters: maxCharacters) {
        slice, offset in
        .numberedList(isTight: isTight, start: start + offset, items: slice)
      }
    case .taskList(let isTight, let items):
      return Self.group(items, children: \.children, isTight: isTight, maxCharacters: maxCharacters) { slice, _ in
        .taskList(isTight: isTight, items: slice)
      }
    default:
      return nil
    }
  }

  private static func group<Item>(
    _ items: [Item],
    children: KeyPath<Item, [BlockNode]>,
    isTight: Bool,
    maxCharacters: Int,
    makeList: ([Item], Int) -> BlockNode
  ) -> [ChunkPiece] {
    var pieces: [ChunkPiece] = []
    var start = 0
    var weight = 0
    for (index, item) in items.enumerated() {
      let itemWeight = Self.weight(of: item[keyPath: children])
      if index > start, weight + itemWeight > maxCharacters {
        pieces.append(
          ChunkPiece(
            block: makeList(Array(items[start..<index]), start),
            weight: weight,
            isListContinuation: start > 0,
            isTightList: isTight
          )
        )
        start = index
        weight = 0
      }
      weight += itemWeight
    }
    pieces.append(
      ChunkPiece(
        block: makeList(Array(items[start...]), start),
        weight: weight,
        isListContinuation: start > 0,
        isTightList: isTight
      )
    )
    return pieces
  }

  /// The basic theme's margins for `block`: like MarkdownUI's
  /// `BlockMarginsPreference`, a container takes the largest of its descendants'.
  private static func margins(of block: BlockNode) -> (top: [RelativeSize], bottom: [RelativeSize]) {
    switch block {
    case .heading:
      return ([.rem(1.5)], [.rem(1)])
    case .thematicBreak:
      return ([.em(2)], [.em(2)])
    case .paragraph, .codeBlock, .htmlBlock, .table:
      return ([.zero], [.em(1)])
    case .blockquote, .bulletedList, .numberedList, .taskList:
      let children = block.children.map { Self.margins(of: $0) }
      return (Self.unique(children.flatMap(\.top)), Self.unique(children.flatMap(\.bottom)))
    }
  }

  private static func unique(_ margins: [RelativeSize]) -> [RelativeSize] {
    margins.reduce(into: []) { result, margin in
      if !result.contains(margin) { result.append(margin) }
    }
  }
}
