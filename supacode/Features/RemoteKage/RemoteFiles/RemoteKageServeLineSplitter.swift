import Foundation

/// NDJSON framing for the `kage host serve` stream: stdout arrives in pipe-sized
/// chunks that split lines anywhere, or carry several at once. Feed every chunk
/// in order; each call returns the lines it completed (without the newline,
/// trailing `\r` dropped, blank lines skipped) and keeps the partial tail.
nonisolated struct RemoteKageServeLineSplitter: Sendable {
  private var pending = Data()

  mutating func append(_ chunk: Data) -> [Data] {
    pending.append(chunk)
    var lines: [Data] = []
    var start = pending.startIndex
    while let newline = pending[start...].firstIndex(of: UInt8(ascii: "\n")) {
      var end = newline
      if end > start, pending[pending.index(before: end)] == UInt8(ascii: "\r") {
        end = pending.index(before: end)
      }
      if end > start {
        lines.append(Data(pending[start..<end]))
      }
      start = pending.index(after: newline)
    }
    if start > pending.startIndex {
      pending = Data(pending[start...])
    }
    return lines
  }
}
