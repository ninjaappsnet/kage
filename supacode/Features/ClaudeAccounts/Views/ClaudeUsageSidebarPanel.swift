import ComposableArchitecture
import Sharing
import SupacodeSettingsShared
import SwiftUI

/// Bottom-of-sidebar card listing every Claude account with its weekly plan
/// usage, when the week resets, and how long until then. Shown while
/// View → Show Claude Usage in Sidebar is on; dismissing turns that off.
/// Keeps the numbers fresh only while on screen (`usagePanelAppeared`).
struct ClaudeUsageSidebarPanel: View {
  let store: StoreOf<ClaudeAccountsFeature>
  @Shared(.claudeUsageSidebarPanelVisible) private var isVisible: Bool

  var body: some View {
    if isVisible {
      SidebarCard(
        onDismiss: { $isVisible.withLock { $0 = false } },
        content: {
          TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 10) {
              ForEach(store.file.allAccounts) { account in
                ClaudeUsageSidebarRow(
                  name: account.name,
                  weekly: store.usages[account.id]?.usage?.sevenDay,
                  placeholder: placeholder(for: account.id),
                  now: context.date
                )
              }
            }
          }
        },
        header: {
          Label("Claude Usage", systemImage: "gauge.with.dots.needle.33percent")
            .appFont(.subheadline)
            .fontWeight(.semibold)
        }
      )
      .help("Weekly plan limit used by each Claude account. Hide it from View → Show Claude Usage in Sidebar.")
      .task {
        store.send(.usagePanelAppeared)
      }
      .onDisappear {
        store.send(.usagePanelDisappeared)
      }
    }
  }

  private func placeholder(for id: ClaudeAccountID) -> String {
    switch store.statuses[id] {
    case .loaded(let status) where !status.loggedIn: "Not logged in"
    case .loaded: "Usage unavailable"
    case .failed: "Status unavailable"
    case .loading, nil: "Checking…"
    }
  }
}

private struct ClaudeUsageSidebarRow: View {
  let name: String
  let weekly: ClaudeUsage.Window?
  let placeholder: String
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline) {
        Text(name)
          .appFont(.caption)
          .fontWeight(.medium)
          .lineLimit(1)
        Spacer(minLength: 4)
        if let weekly {
          Text(weekly.percentLabel)
            .appFont(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
      }
      if let weekly {
        ProgressView(value: min(max(weekly.percentUsed, 0), 100), total: 100)
          .progressViewStyle(.linear)
          .tint(weekly.percentUsed >= 90 ? .red : weekly.percentUsed >= 75 ? .orange : .accentColor)
          .accessibilityLabel("\(name) weekly limit used")
          .accessibilityValue(weekly.percentLabel)
        if let resetsAt = weekly.resetsAt, let left = weekly.timeUntilReset(now: now) {
          Text("Resets \(resetsAt.formatted(Self.resetFormat)) · \(left) left")
            .appFont(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      } else {
        Text(placeholder)
          .appFont(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// "Mon 17 Nov 14:00", in the user's locale.
  private static let resetFormat = Date.FormatStyle.dateTime
    .weekday(.abbreviated).day().month(.abbreviated).hour().minute()
}
