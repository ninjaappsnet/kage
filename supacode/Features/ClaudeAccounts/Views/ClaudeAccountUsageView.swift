import SwiftUI

/// Plan usage under an account row: one gauge per reported window, weekly first.
struct ClaudeAccountUsageView: View {
  let usage: ClaudeUsage

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let weekly = usage.sevenDay {
        ClaudeUsageWindowView(title: "Weekly", window: weekly)
      }
      if let session = usage.fiveHour {
        ClaudeUsageWindowView(title: "Session", window: session)
      }
    }
    .padding(.top, 2)
  }
}

private struct ClaudeUsageWindowView: View {
  let title: String
  let window: ClaudeUsage.Window

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ProgressView(value: min(max(window.percentUsed, 0), 100), total: 100)
        .progressViewStyle(.linear)
        .tint(window.percentUsed >= 90 ? .red : window.percentUsed >= 75 ? .orange : .accentColor)
        .frame(maxWidth: 220)
        .accessibilityLabel("\(title) limit used")
        .accessibilityValue(window.percentLabel)
      Text(caption)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .help("\(title) plan limit used by this account, as Claude Code's /usage reports it")
  }

  private var caption: String {
    let used = "\(title) \(window.percentLabel) used"
    guard let resetsAt = window.resetsAt else { return used }
    return "\(used) · resets \(resetsAt.formatted(.relative(presentation: .named)))"
  }
}
