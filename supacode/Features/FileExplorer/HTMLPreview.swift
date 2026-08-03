import SwiftUI

/// Rendered HTML for the viewer's "Rendered" mode, plus the affordance that
/// makes the default policy livable: a page that came out wrong because its CDN
/// scripts were blocked says so, and offers to reload with network access,
/// rather than silently showing a blank document.
struct HTMLPreview: View {
  let fileURL: URL
  let isTrusted: Bool
  let onTrust: () -> Void

  /// Names rather than counts of loads, so a page retrying the same blocked
  /// asset in a loop does not inflate the banner.
  @State private var blockedResources: Set<String> = []

  var body: some View {
    HTMLPreviewWebView(fileURL: fileURL, isTrusted: isTrusted) { blocked in
      blockedResources.insert(blocked)
    }
    .id(fileURL)
    .safeAreaInset(edge: .top, spacing: 0) {
      if !isTrusted, !blockedResources.isEmpty {
        blockedBanner
      }
    }
    .onChange(of: fileURL) { _, _ in blockedResources.removeAll() }
    .onChange(of: isTrusted) { _, _ in blockedResources.removeAll() }
  }

  private var blockedBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "network.slash")
        .accessibilityHidden(true)
      Text(blockedMessage)
        .lineLimit(2)
      Spacer(minLength: 8)
      Button("Allow Network", action: onTrust)
        .controlSize(.small)
        .help(
          """
          Reload with internet access so the page can load scripts, styles and fonts from a CDN. \
          Only for files you trust: its JavaScript will then be able to send data out.
          """
        )
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var blockedMessage: String {
    blockedResources.count == 1
      ? "Blocked 1 external resource"
      : "Blocked \(blockedResources.count) external resources"
  }
}
