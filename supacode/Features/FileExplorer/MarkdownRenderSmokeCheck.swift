import AppKit
import SwiftUI

/// Renders the file viewer's markdown path once, offscreen, then exits.
///
/// Guards a Release-only failure that no unit test can reach: tests build Debug,
/// and at -O the optimizer miscompiled MarkdownUI's associated-type witness for
/// `Markdown: View`, so every .md file aborted the app the moment its body was
/// built. Tuist/Package.swift pins MarkdownUI to -Onone to avoid it; this check
/// is what proves the pin still works, by exercising an optimized Release binary
/// the way only a real build can.
///
/// Opt-in via SUPACODE_MD_SMOKE=1, so it is inert for users. Exits 0 on success;
/// a regression aborts the process instead of returning.
enum MarkdownRenderSmokeCheck {
  @MainActor
  static func runIfRequested() {
    guard ProcessInfo.processInfo.environment["SUPACODE_MD_SMOKE"] == "1" else { return }

    let markdown = """
      # Heading

      Paragraph with `inline code`.

      ```swift
      let x = 1
      ```
      """
    let controller = NSHostingController(rootView: MarkdownPreview(markdown: markdown))
    controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    controller.view.layoutSubtreeIfNeeded()
    _ = controller.view.fittingSize

    FileHandle.standardError.write(Data("[md-smoke] rendered ok\n".utf8))
    exit(0)
  }
}
