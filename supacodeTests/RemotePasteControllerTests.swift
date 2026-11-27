import AppKit
import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

@MainActor
struct RemotePasteControllerTests {
  private static func temporaryFile(_ name: String, _ data: Data = Data([1])) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "remote-paste-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: name)
    try data.write(to: url)
    return url
  }

  private static func controller(
    upload: @escaping @Sendable (RemotePasteItem) async throws -> String
  ) -> (RemotePasteController, LockIsolated<[String]>) {
    let inserted = LockIsolated<[String]>([])
    let controller = RemotePasteController(uploader: RemotePasteUploader(upload: upload), token: { "abc123" })
    controller.insert = { text in inserted.withValue { $0.append(text) } }
    return (controller, inserted)
  }

  @Test func textPastesAreLeftToTheTerminal() async {
    let (controller, inserted) = Self.controller { _ in
      Issue.record("no upload expected")
      return ""
    }
    #expect(!controller.handle(plan: .passThrough, imagePNG: nil))
    await controller.waitUntilIdle()
    #expect(inserted.value.isEmpty)
    #expect(controller.status == .idle)
  }

  @Test func uploadedFilesArePastedAsTheirRemotePathsInOrder() async throws {
    let first = try Self.temporaryFile("one.png")
    let second = try Self.temporaryFile("two.png")
    let uploaded = LockIsolated<[String]>([])
    let (controller, inserted) = Self.controller { item in
      uploaded.withValue { $0.append(item.name) }
      return "/tmp/kage-me/" + item.name
    }

    #expect(controller.handle(plan: .uploadFiles([first, second]), imagePNG: nil))
    await controller.waitUntilIdle()

    #expect(uploaded.value == ["one-abc123.png", "two-abc123.png"])
    #expect(inserted.value == ["/tmp/kage-me/one-abc123.png /tmp/kage-me/two-abc123.png"])
    #expect(controller.status == .idle)
  }

  @Test func remotePathsAreEscapedForTheTerminal() async throws {
    let (controller, inserted) = Self.controller { _ in "/tmp/kage-me/a b.png" }
    #expect(controller.handle(plan: .uploadImage, imagePNG: Data([1])))
    await controller.waitUntilIdle()
    #expect(inserted.value == ["/tmp/kage-me/a\\ b.png"])
  }

  @Test func anImageIsUploadedAsPNG() async {
    let names = LockIsolated<[String]>([])
    let (controller, inserted) = Self.controller { item in
      names.withValue { $0.append(item.name) }
      return "/tmp/kage-me/" + item.name
    }
    #expect(controller.handle(plan: .uploadImage, imagePNG: Data([7])))
    await controller.waitUntilIdle()
    #expect(names.value == ["pasted-image-abc123.png"])
    #expect(inserted.value == ["/tmp/kage-me/pasted-image-abc123.png"])
  }

  @Test func aFailedUploadPastesNothingAndSaysWhy() async throws {
    let file = try Self.temporaryFile("one.png")
    let (controller, inserted) = Self.controller { _ in throw RemotePasteProblem.unreachable }
    #expect(controller.handle(plan: .uploadFiles([file]), imagePNG: nil))
    await controller.waitUntilIdle()
    #expect(inserted.value.isEmpty)
    #expect(controller.status == .failed(RemotePasteProblem.unreachable.message))
  }

  @Test func aProblemPreparingThePasteIsReportedWithoutUploading() async {
    let (controller, inserted) = Self.controller { _ in
      Issue.record("no upload expected")
      return ""
    }
    #expect(controller.handle(plan: .uploadImage, imagePNG: nil))
    await controller.waitUntilIdle()
    #expect(inserted.value.isEmpty)
    #expect(controller.status == .failed(RemotePasteProblem.noImage.message))
  }

  @Test func showsProgressWhileUploading() async {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let (controller, _) = Self.controller { item in
      for await _ in gate {}
      return "/tmp/kage-me/" + item.name
    }
    #expect(controller.handle(plan: .uploadImage, imagePNG: Data([1])))
    #expect(controller.status == .uploading(itemCount: 1))
    release.finish()
    await controller.waitUntilIdle()
    #expect(controller.status == .idle)
  }

  @Test func aNewPasteClearsAnEarlierFailure() async {
    let fail = LockIsolated(true)
    let (controller, inserted) = Self.controller { item in
      if fail.value { throw RemotePasteProblem.unreachable }
      return "/tmp/kage-me/" + item.name
    }
    _ = controller.handle(plan: .uploadImage, imagePNG: Data([1]))
    await controller.waitUntilIdle()
    fail.setValue(false)
    _ = controller.handle(plan: .uploadImage, imagePNG: Data([1]))
    await controller.waitUntilIdle()
    #expect(controller.status == .idle)
    #expect(inserted.value.count == 1)
  }

  @Test func dismissingClearsAFailure() async {
    let (controller, _) = Self.controller { _ in throw RemotePasteProblem.unreachable }
    _ = controller.handle(plan: .uploadImage, imagePNG: Data([1]))
    await controller.waitUntilIdle()
    controller.dismissFailure()
    #expect(controller.status == .idle)
  }

  @Test func pastesLandInTheOrderTheyWereMade() async {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let inserted = LockIsolated<[String]>([])
    var token = 0
    let controller = RemotePasteController(
      uploader: RemotePasteUploader { item in
        // The first upload is held until the second paste has been made.
        if item.name == "pasted-image-t1.png" { for await _ in gate {} }
        return "/tmp/kage-me/" + item.name
      },
      token: {
        token += 1
        return "t\(token)"
      }
    )
    controller.insert = { text in inserted.withValue { $0.append(text) } }
    _ = controller.handle(plan: .uploadImage, imagePNG: Data([1]))
    _ = controller.handle(plan: .uploadImage, imagePNG: Data([1]))
    release.finish()
    await controller.waitUntilIdle()
    #expect(inserted.value == ["/tmp/kage-me/pasted-image-t1.png", "/tmp/kage-me/pasted-image-t2.png"])
  }
}
