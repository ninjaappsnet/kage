import AppKit
import Foundation
import UniformTypeIdentifiers

/// What a paste or drop into a remote attached terminal does. Local paths mean
/// nothing to the host, so files and clipboard images are uploaded to it first
/// and their remote paths pasted instead; the host's Claude Code then turns an
/// image path into an `[Image #N]` attachment as it does locally.
nonisolated enum RemotePastePlan: Equatable, Sendable {
  /// Nothing to upload: the terminal pastes as usual.
  case passThrough
  /// Local files, uploaded one by one.
  case uploadFiles([URL])
  /// Image data and nothing else (a screenshot copied to the clipboard), uploaded as PNG.
  case uploadImage

  /// File URLs win: a Finder copy carries the file's name as text and its icon
  /// as an image too. An image counts only with no text beside it, matching
  /// the local Cmd+V image routing, so a browser copy still pastes its text.
  static func make(fileURLs: [URL], types: [NSPasteboard.PasteboardType]) -> Self {
    let files = fileURLs.filter(\.isFileURL)
    if !files.isEmpty { return .uploadFiles(files) }
    guard types.contains(where: isImage), !types.contains(where: isTextOrURL) else { return .passThrough }
    return .uploadImage
  }

  private static func isImage(_ type: NSPasteboard.PasteboardType) -> Bool {
    UTType(type.rawValue)?.conforms(to: .image) == true
  }

  private static func isTextOrURL(_ type: NSPasteboard.PasteboardType) -> Bool {
    if [.string, .fileURL, .URL].contains(type) { return true }
    guard let uniformType = UTType(type.rawValue) else { return false }
    return uniformType.conforms(to: .text) || uniformType.conforms(to: .url)
  }
}

/// One file to upload: its bytes and the name it gets on the host.
nonisolated struct RemotePasteItem: Equatable, Sendable {
  var name: String
  var data: Data
}

/// Why a paste could not be uploaded. Nothing is pasted then.
nonisolated enum RemotePasteProblem: Error, Equatable, Sendable {
  case notAFile(String)
  case unreadable(String)
  case tooLarge(limit: Int)
  case noImage
  case invalidHost
  case unreachable
  case uploadFailed(String)

  var message: String {
    switch self {
    case .notAFile(let name): "“\(name)” is a folder. Only files can be pasted into a remote terminal."
    case .unreadable(let name): "Couldn't read “\(name)”."
    case .tooLarge(let limit):
      "The paste is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
    case .noImage: "Couldn't read the image on the clipboard."
    case .invalidHost: "This host's address or username isn't valid for SSH."
    case .unreachable: "Couldn't reach the host."
    case .uploadFailed(let message): message
    }
  }
}

/// The name a pasted file gets on the host: the original name reduced to
/// characters that need no escaping in a terminal or a shell (so the pasted
/// path is exactly what Claude Code looks up), plus a random token so two
/// pastes of the same name never collide.
nonisolated enum RemotePasteName {
  static let baseLimit = 60
  static let extensionLimit = 10

  static func make(original: String, token: String) -> String {
    let (base, fileExtension) = split(original)
    var safeBase = sanitized(base)
    if safeBase.count > baseLimit { safeBase = String(safeBase.prefix(baseLimit)) }
    safeBase = safeBase.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    if safeBase.isEmpty { safeBase = "file" }
    let name = safeBase + "-" + token
    return fileExtension.map { name + "." + $0 } ?? name
  }

  static func randomToken() -> String {
    String((0..<6).map { _ in "0123456789abcdef".randomElement()! })
  }

  /// A short ASCII-alphanumeric extension after the last dot; a leading dot is a hidden name, not an extension.
  private static func split(_ name: String) -> (base: String, fileExtension: String?) {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, nil) }
    let candidate = name[name.index(after: dot)...]
    guard !candidate.isEmpty, candidate.count <= extensionLimit,
      candidate.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
    else { return (name, nil) }
    return (String(name[..<dot]), candidate.lowercased())
  }

  private static func sanitized(_ value: String) -> String {
    var result = ""
    for scalar in value.unicodeScalars {
      let keep =
        scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
      let next: Character = keep ? Character(scalar) : "-"
      if next == "-", result.last == "-" { continue }
      result.append(next)
    }
    return result.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
  }
}

/// Reads what a paste uploads, enforcing the size limit before any bytes are read.
nonisolated enum RemotePastePreparation {
  /// Uploads travel over ssh while the user waits; screenshots are a few MB.
  static let byteLimit = 25 * 1024 * 1024

  static func items(
    files: [URL],
    byteLimit: Int = byteLimit,
    token: () -> String
  ) throws(RemotePasteProblem) -> [RemotePasteItem] {
    var total = 0
    for file in files {
      let values: URLResourceValues
      do {
        values = try file.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
      } catch {
        throw .unreadable(file.lastPathComponent)
      }
      if values.isDirectory == true { throw .notAFile(file.lastPathComponent) }
      total += values.fileSize ?? 0
      if total > byteLimit { throw .tooLarge(limit: byteLimit) }
    }
    var items: [RemotePasteItem] = []
    for file in files {
      let data: Data
      do {
        data = try Data(contentsOf: file)
      } catch {
        throw .unreadable(file.lastPathComponent)
      }
      items.append(
        RemotePasteItem(name: RemotePasteName.make(original: file.lastPathComponent, token: token()), data: data))
    }
    return items
  }

  static func imageItem(png: Data?, byteLimit: Int = byteLimit, token: () -> String) throws(RemotePasteProblem)
    -> RemotePasteItem
  {
    guard let png else { throw .noImage }
    guard png.count <= byteLimit else { throw .tooLarge(limit: byteLimit) }
    return RemotePasteItem(name: RemotePasteName.make(original: "pasted-image.png", token: token()), data: png)
  }
}

/// The clipboard image as PNG bytes: PNG as it is, anything else (TIFF from
/// many apps) re-encoded.
enum RemotePasteImage {
  static func pngData(from pasteboard: NSPasteboard) -> Data? {
    if let png = pasteboard.data(forType: .png) { return png }
    guard NSImage.canInit(with: pasteboard), let image = NSImage(pasteboard: pasteboard),
      let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff)
    else { return nil }
    return bitmap.representation(using: .png, properties: [:])
  }
}
