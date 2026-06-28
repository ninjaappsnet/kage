import AppKit
import PDFKit
import SwiftUI

/// Previews non-text media (images, PDFs) in the file viewer pane. Renders from
/// the file URL — nothing is loaded into the editor buffer.
struct MediaPreview: View {
  let url: URL
  let kind: FileViewerFileType.MediaKind

  var body: some View {
    switch kind {
    case .image:
      if let image = NSImage(contentsOf: url) {
        ImagePreview(image: image)
          .padding(8)
      } else {
        unsupported
      }
    case .pdf:
      if let document = PDFDocument(url: url) {
        PDFPreview(document: document)
      } else {
        unsupported
      }
    }
  }

  private var unsupported: some View {
    VStack(spacing: 12) {
      ContentUnavailableView("Can't preview this file", systemImage: "doc.questionmark")
      Button("Open in Default App") { NSWorkspace.shared.open(url) }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// `NSImageView` (not SwiftUI `Image`) so animated GIFs play and large images
/// downscale efficiently. Scales to fit while preserving aspect ratio.
private struct ImagePreview: NSViewRepresentable {
  let image: NSImage

  func makeNSView(context: Context) -> NSImageView {
    let view = NSImageView()
    view.imageScaling = .scaleProportionallyUpOrDown
    view.animates = true
    view.image = image
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    return view
  }

  func updateNSView(_ view: NSImageView, context: Context) {
    if view.image !== image { view.image = image }
  }
}

private struct PDFPreview: NSViewRepresentable {
  let document: PDFDocument

  func makeNSView(context: Context) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.document = document
    return view
  }

  func updateNSView(_ view: PDFView, context: Context) {
    if view.document !== document { view.document = document }
  }
}
