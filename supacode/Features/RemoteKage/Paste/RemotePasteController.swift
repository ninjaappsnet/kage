import AppKit
import Foundation
import Observation

/// Takes file and image pastes in one remote attached terminal, uploads them
/// to the host and pastes their remote paths once every file of the paste has
/// landed. Pastes are handled one after another, so paths arrive in the order
/// the pastes were made. A failed paste pastes nothing and says why.
@MainActor
@Observable
final class RemotePasteController {
  enum Status: Equatable, Sendable {
    case idle
    case uploading(itemCount: Int)
    case failed(String)
  }

  private(set) var status: Status = .idle
  /// Sends text into the terminal as a paste. Set by the surface owner.
  @ObservationIgnored var insert: (String) -> Void = { _ in }
  @ObservationIgnored private let uploader: RemotePasteUploader
  @ObservationIgnored private let token: () -> String
  @ObservationIgnored private var tail: Task<Void, Never>?
  @ObservationIgnored private var pending = 0

  init(uploader: RemotePasteUploader, token: @escaping () -> String = RemotePasteName.randomToken) {
    self.uploader = uploader
    self.token = token
  }

  nonisolated deinit {}

  /// The surface's paste hook: true when the paste is taken over (an upload
  /// started), false to let the terminal paste as usual.
  func intercept(_ pasteboard: NSPasteboard) -> Bool {
    let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
    let plan = RemotePastePlan.make(fileURLs: urls, types: pasteboard.types ?? [])
    // Read now: the clipboard may change while earlier pastes upload.
    let png = plan == .uploadImage ? RemotePasteImage.pngData(from: pasteboard) : nil
    return handle(plan: plan, imagePNG: png)
  }

  func handle(plan: RemotePastePlan, imagePNG: Data?) -> Bool {
    let itemCount: Int
    switch plan {
    case .passThrough: return false
    case .uploadFiles(let files): itemCount = files.count
    case .uploadImage: itemCount = 1
    }
    // Names are fixed in paste order, before any waiting.
    let tokens = (0..<itemCount).map { _ in token() }
    pending += 1
    status = .uploading(itemCount: itemCount)
    let previous = tail
    let uploader = uploader
    tail = Task { [weak self] in
      await previous?.value
      let outcome = await Task.detached {
        await Self.upload(plan: plan, imagePNG: imagePNG, tokens: tokens, uploader: uploader)
      }.value
      self?.finish(outcome)
    }
    return true
  }

  func dismissFailure() {
    if case .failed = status { status = .idle }
  }

  /// Waits for every paste made so far to finish.
  func waitUntilIdle() async {
    await tail?.value
  }

  private func finish(_ outcome: Result<[String], RemotePasteProblem>) {
    pending -= 1
    switch outcome {
    case .success(let paths):
      insert(paths.map(NSPasteboard.ghosttyEscape).joined(separator: " "))
      if pending == 0 { status = .idle }
    case .failure(let problem):
      status = .failed(problem.message)
    }
  }

  private nonisolated static func upload(
    plan: RemotePastePlan,
    imagePNG: Data?,
    tokens: [String],
    uploader: RemotePasteUploader
  ) async -> Result<[String], RemotePasteProblem> {
    var remaining = tokens.makeIterator()
    let next = { remaining.next() ?? RemotePasteName.randomToken() }
    do {
      let items: [RemotePasteItem]
      switch plan {
      case .passThrough: return .success([])
      case .uploadFiles(let files): items = try RemotePastePreparation.items(files: files, token: next)
      case .uploadImage: items = [try RemotePastePreparation.imageItem(png: imagePNG, token: next)]
      }
      var paths: [String] = []
      for item in items {
        paths.append(try await uploader.upload(item))
      }
      return .success(paths)
    } catch let problem as RemotePasteProblem {
      return .failure(problem)
    } catch {
      return .failure(.uploadFailed(error.localizedDescription))
    }
  }
}
