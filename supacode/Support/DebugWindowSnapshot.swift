import AppKit
import SupacodeSettingsShared

private nonisolated let debugWindowSnapshotLogger = SupaLogger("DebugWindowSnapshot")

/// Debug builds only: saves pictures of this app's own windows on request, so an
/// agent can look at a test Kage without Screen Recording permission (an app may
/// always draw its own views). Opt-in via `KAGE_DEBUG_SNAPSHOT_DIR`; inert
/// otherwise and compiled out of Release. Trigger it with the distributed
/// notification `net.ninjaapps.kage.debug.snapshot` whose object is a tag;
/// each visible window is written to `<dir>/<tag>-<n>.png`, then
/// `<dir>/<tag>.done` lists them. `scripts/dev-sandbox-app.sh snapshot` sends it.
/// Views drawn by Metal (terminal surfaces) come out blank.
enum DebugWindowSnapshot {
  static let directoryEnvironmentKey = "KAGE_DEBUG_SNAPSHOT_DIR"
  static let notificationName = Notification.Name("net.ninjaapps.kage.debug.snapshot")

  private static var observer: (any NSObjectProtocol)?

  static func directory(environment: [String: String]) -> URL? {
    guard let path = environment[directoryEnvironmentKey], !path.isEmpty else { return nil }
    return URL(filePath: path, directoryHint: .isDirectory)
  }

  static func fileURL(directory: URL, tag: String, windowIndex: Int) -> URL {
    directory.appending(path: "\(safeTag(tag))-\(windowIndex).png")
  }

  /// Letters, digits, `-` and `_` only, so a tag can never leave the directory.
  static func safeTag(_ tag: String) -> String {
    let safe = tag.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    return safe.isEmpty ? "snapshot" : safe
  }

  static func installIfRequested(environment: [String: String] = ProcessInfo.processInfo.environment) {
    #if DEBUG
      guard observer == nil, let directory = directory(environment: environment) else { return }
      observer = DistributedNotificationCenter.default().addObserver(
        forName: notificationName,
        object: nil,
        queue: .main
      ) { notification in
        let tag = notification.object as? String ?? "snapshot"
        MainActor.assumeIsolated { writeSnapshots(directory: directory, tag: tag) }
      }
      debugWindowSnapshotLogger.info("Window snapshots enabled into \(directory.path(percentEncoded: false))")
    #endif
  }

  private static func pngData(of view: NSView) -> Data? {
    guard view.bounds.width > 0, view.bounds.height > 0,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return nil }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap.representation(using: .png, properties: [:])
  }

  /// Outline views (the sidebar) sit inside a glass container the window
  /// server composites, so a whole-window drawing leaves them blank; drawn on
  /// their own they come out whole.
  private static func outlineViews(in view: NSView) -> [NSOutlineView] {
    if let outline = view as? NSOutlineView { return [outline] }
    return view.subviews.flatMap { outlineViews(in: $0) }
  }

  private static func writeSnapshots(directory: URL, tag: String) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let windows = NSApp.windows.filter(\.isVisible).sorted { $0.windowNumber < $1.windowNumber }
    var written: [String] = []
    for (index, window) in windows.enumerated() {
      // The frame view includes the title bar and toolbar.
      guard let view = window.contentView?.superview ?? window.contentView,
        let data = pngData(of: view)
      else { continue }
      let url = fileURL(directory: directory, tag: tag, windowIndex: index)
      do {
        try data.write(to: url)
        written.append("\(url.path(percentEncoded: false))\t\(window.title)")
      } catch {
        debugWindowSnapshotLogger.warning("Could not write \(url.path(percentEncoded: false)): \(error)")
      }
      for (outlineIndex, outline) in outlineViews(in: view).enumerated() {
        guard let outlineData = pngData(of: outline) else { continue }
        let outlineURL = directory.appending(path: "\(safeTag(tag))-\(index)-outline-\(outlineIndex).png")
        if (try? outlineData.write(to: outlineURL)) != nil {
          written.append("\(outlineURL.path(percentEncoded: false))\t\(window.title) outline")
        }
      }
    }
    let done = directory.appending(path: "\(safeTag(tag)).done")
    try? written.joined(separator: "\n").write(to: done, atomically: true, encoding: .utf8)
  }
}
