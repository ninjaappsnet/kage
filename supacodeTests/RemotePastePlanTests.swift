import AppKit
import Foundation
import Testing

@testable import supacode

struct RemotePastePlanTests {
  private static let png = NSPasteboard.PasteboardType.png
  private static let tiff = NSPasteboard.PasteboardType.tiff

  @Test func copiedFilesAreUploadedEvenWhenTheirIconRidesAlong() {
    // A Finder copy carries the file URL, its name as text and its icon as an image.
    let url = URL(fileURLWithPath: "/Users/me/Desktop/Screenshot.png")
    let plan = RemotePastePlan.make(fileURLs: [url], types: [.fileURL, .string, Self.tiff])
    #expect(plan == .uploadFiles([url]))
  }

  @Test func imageOnlyClipboardIsUploadedAsAnImage() {
    #expect(RemotePastePlan.make(fileURLs: [], types: [Self.png, Self.tiff]) == .uploadImage)
  }

  @Test func imageWithTextPassesThrough() {
    // A browser copy: the text is what the user meant, as in local tabs.
    #expect(RemotePastePlan.make(fileURLs: [], types: [.string, .html, Self.png]) == .passThrough)
  }

  @Test func plainTextPassesThrough() {
    #expect(RemotePastePlan.make(fileURLs: [], types: [.string]) == .passThrough)
  }

  @Test func webLinksPassThrough() {
    let link = URL(string: "https://example.com/a.png")!
    #expect(RemotePastePlan.make(fileURLs: [link], types: [.URL, .string]) == .passThrough)
  }

  @Test func emptyPasteboardPassesThrough() {
    #expect(RemotePastePlan.make(fileURLs: [], types: []) == .passThrough)
  }
}

struct RemotePasteNameTests {
  @Test func keepsASafeNameAndAddsTheToken() {
    #expect(RemotePasteName.make(original: "report.pdf", token: "a1b2c3") == "report-a1b2c3.pdf")
  }

  @Test func replacesSpacesAndUnicodeAndCollapsesRuns() {
    // macOS screenshot names carry a narrow no-break space before AM / PM.
    let name = RemotePasteName.make(original: "Screenshot 2026-11-27 at 6.28.00\u{202F}PM.png", token: "a1b2c3")
    #expect(name == "Screenshot-2026-11-27-at-6.28.00-PM-a1b2c3.png")
  }

  @Test func neverStartsWithADotOrADash() {
    #expect(RemotePasteName.make(original: ".hidden", token: "a1b2c3") == "hidden-a1b2c3")
    #expect(RemotePasteName.make(original: "--rf.txt", token: "a1b2c3") == "rf-a1b2c3.txt")
  }

  @Test func fallsBackWhenNothingSafeIsLeft() {
    #expect(RemotePasteName.make(original: "ü.png", token: "a1b2c3") == "file-a1b2c3.png")
  }

  @Test func lowercasesAndCapsTheExtension() {
    #expect(RemotePasteName.make(original: "a.JPG", token: "a1b2c3") == "a-a1b2c3.jpg")
    #expect(RemotePasteName.make(original: "a.thisisaverylongext", token: "a1b2c3") == "a.thisisaverylongext-a1b2c3")
  }

  @Test func capsTheBaseLength() {
    let name = RemotePasteName.make(original: String(repeating: "x", count: 300) + ".png", token: "a1b2c3")
    #expect(name == String(repeating: "x", count: RemotePasteName.baseLimit) + "-a1b2c3.png")
  }

  @Test func tokensAreSixLowercaseHexCharacters() {
    let token = RemotePasteName.randomToken()
    #expect(token.count == 6)
    #expect(token.allSatisfy { "0123456789abcdef".contains($0) })
  }
}

struct RemotePastePreparationTests {
  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "remote-paste-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func readsEachFileUnderItsRemoteName() throws {
    let folder = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = folder.appending(path: "one.png")
    let second = folder.appending(path: "two words.txt")
    try Data([1, 2, 3]).write(to: first)
    try Data("hi".utf8).write(to: second)

    let items = try RemotePastePreparation.items(files: [first, second], token: { "abc123" })

    #expect(
      items == [
        RemotePasteItem(name: "one-abc123.png", data: Data([1, 2, 3])),
        RemotePasteItem(name: "two-words-abc123.txt", data: Data("hi".utf8)),
      ]
    )
  }

  @Test func rejectsFolders() throws {
    let folder = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(throws: RemotePasteProblem.notAFile(folder.lastPathComponent)) {
      try RemotePastePreparation.items(files: [folder], token: { "abc123" })
    }
  }

  @Test func rejectsMissingFiles() {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/a.png")
    #expect(throws: RemotePasteProblem.unreadable("a.png")) {
      try RemotePastePreparation.items(files: [missing], token: { "abc123" })
    }
  }

  @Test func rejectsAPasteOverTheSizeLimitInTotal() throws {
    let folder = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = folder.appending(path: "a.bin")
    let second = folder.appending(path: "b.bin")
    try Data(count: 6).write(to: first)
    try Data(count: 6).write(to: second)
    #expect(throws: RemotePasteProblem.tooLarge(limit: 10)) {
      try RemotePastePreparation.items(files: [first, second], byteLimit: 10, token: { "abc123" })
    }
  }

  @Test func imageBecomesAPastedImagePNG() throws {
    let item = try RemotePastePreparation.imageItem(png: Data([9]), token: { "abc123" })
    #expect(item == RemotePasteItem(name: "pasted-image-abc123.png", data: Data([9])))
  }

  @Test func missingImageDataIsAProblem() {
    #expect(throws: RemotePasteProblem.noImage) {
      try RemotePastePreparation.imageItem(png: nil, token: { "abc123" })
    }
  }

  @Test func oversizedImageIsAProblem() {
    #expect(throws: RemotePasteProblem.tooLarge(limit: 2)) {
      try RemotePastePreparation.imageItem(png: Data(count: 3), byteLimit: 2, token: { "abc123" })
    }
  }
}

@MainActor
struct RemotePasteImageTests {
  @Test func keepsPNGBytesAsTheyAre() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let png = Self.onePixelPNG()
    pasteboard.declareTypes([.png], owner: nil)
    pasteboard.setData(png, forType: .png)
    #expect(RemotePasteImage.pngData(from: pasteboard) == png)
  }

  @Test func convertsTIFFToPNG() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let image = try #require(NSImage(data: Self.onePixelPNG()))
    pasteboard.declareTypes([.tiff], owner: nil)
    pasteboard.setData(try #require(image.tiffRepresentation), forType: .tiff)
    let data = try #require(RemotePasteImage.pngData(from: pasteboard))
    #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
  }

  @Test func noImageGivesNil() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.declareTypes([.string], owner: nil)
    pasteboard.setString("hi", forType: .string)
    #expect(RemotePasteImage.pngData(from: pasteboard) == nil)
  }

  private static func onePixelPNG() -> Data {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
  }
}
