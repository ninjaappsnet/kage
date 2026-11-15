import AppKit
import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Settings → Sync.
struct DotfilesSyncSettingsView: View {
  @Bindable var store: StoreOf<DotfilesSyncFeature>

  var body: some View {
    Form {
      Section {
        Toggle(
          "Sync settings and memory between Macs",
          isOn: Binding(get: { store.settings.isEnabled }, set: { store.send(.setEnabled($0)) })
        )
        .disabled(store.settings.trimmedRemoteURL.isEmpty && !store.settings.isEnabled)
        .help("Commit local changes, pull other Macs' changes and push, every two minutes")
        TextField("Repository", text: $store.settings.remoteURL, prompt: Text("git@github.com:you/kage-dotfiles.git"))
          .font(.body.monospaced())
          .disabled(store.settings.isEnabled)
          .help("Clone URL of a private git repository. Turn sync off to change it.")
      } header: {
        Text("Sync")
      } footer: {
        Text(
          """
          Use a private repository: it holds your settings, rules and project notes. \
          Each Mac copies its files into a clone at ~/.kage/dotfiles and merges the others'. \
          Logins, conversation history and caches never leave this Mac.
          """
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }

      Section("Status") {
        if store.isSyncing, let progress = store.progress {
          VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress.fraction)
              .progressViewStyle(.linear)
              .accessibilityLabel("Sync progress")
              .accessibilityValue("\(Int(progress.fraction * 100))%")
            HStack {
              Text(progress.message)
                .lineLimit(1)
                .truncationMode(.middle)
              Spacer()
              Text("\(Int(progress.fraction * 100))%")
                .monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
          }
        } else {
          LabeledContent("Last sync") {
            Text(store.lastSyncedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
              .foregroundStyle(.secondary)
          }
        }
        if let error = store.lastError {
          Text(error)
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
        if let report = store.lastReport {
          DotfilesSyncReportView(report: report)
        }
        HStack {
          Button("Sync Now") { store.send(.syncNowTapped) }
            .disabled(!store.canSync || store.isSyncing)
            .help("Run a sync pass now")
          Button("Show Repository") {
            NSWorkspace.shared.open(SupacodePaths.dotfilesRepositoryDirectory)
          }
          .help("Open this Mac's clone of the sync repository in Finder")
          Button("Show Conflicts") {
            NSWorkspace.shared.open(SupacodePaths.dotfilesConflictsDirectory)
          }
          .disabled(!FileManager.default.fileExists(atPath: SupacodePaths.dotfilesConflictsDirectory.path))
          .help("Open the other Macs' copies of files that could not be merged")
        }
      }

      if !store.conflicts.isEmpty {
        Section {
          ForEach(store.conflicts) { conflict in
            DotfilesVersionConflictRow(
              conflict: conflict,
              keepLocal: { store.send(.choose(unit: conflict.unit, .keepLocal)) },
              useSynced: { store.send(.choose(unit: conflict.unit, .useRepository)) }
            )
          }
        } header: {
          HStack {
            Text("Choose which version to keep")
            Spacer()
            Button("Keep All This Mac's") { store.send(.chooseAll(.keepLocal)) }
              .help("This Mac's copies replace the synced ones on every Mac")
            Button("Use All Synced") { store.send(.chooseAll(.useRepository)) }
              .help("The synced copies replace this Mac's; this Mac's are saved in Conflicts → replaced")
          }
          .buttonStyle(.borderless)
        } footer: {
          Text(
            """
            These differ between this Mac and the others and are not merged automatically \
            (only Claude memory and JSON settings are). Until you choose, each stays as it is here.
            """
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
      }

      Section("What syncs") {
        DotfilesSyncScopeRow(
          title: "Claude Code",
          detail: "settings.json, CLAUDE.md and other top-level notes and scripts, keybindings, agents, commands, "
            + "output styles, hooks, skills (and ~/.agents/skills)"
        )
        DotfilesSyncScopeRow(
          title: "Claude memory",
          detail: "Each project's memory, matched across Macs by its git remote, wherever it is checked out"
        )
        DotfilesSyncScopeRow(title: "Codex", detail: "AGENTS.md, config.toml, hooks.json, rules, skills, prompts")
        DotfilesSyncScopeRow(title: "Kage", detail: "Terminal configuration (config.ghostty)")
        DotfilesSyncScopeRow(
          title: "Never synced",
          detail: "Logins and tokens, conversation history and transcripts, plugin caches, databases, "
            + "and any file that looks like it holds a secret"
        )
      }
    }
    .formStyle(.grouped)
  }
}

private struct DotfilesSyncScopeRow: View {
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }
}

private struct DotfilesSyncReportView: View {
  let report: DotfilesSyncReport

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(summary)
        .font(.callout)
        .foregroundStyle(.secondary)
      if !report.blockedSecrets.isEmpty {
        Label(
          "Not synced, may contain a secret: \(report.blockedSecrets.joined(separator: ", "))",
          systemImage: "exclamationmark.shield"
        )
        .font(.callout)
        .foregroundStyle(.orange)
      }
      if !report.unresolved.isEmpty {
        Label(
          "Kept this Mac's copy (other copy in Conflicts): \(report.unresolved.joined(separator: ", "))",
          systemImage: "exclamationmark.triangle"
        )
        .font(.callout)
        .foregroundStyle(.orange)
      }
      if !report.resolvedByClaude.isEmpty {
        Label("Merged by Claude: \(report.resolvedByClaude.joined(separator: ", "))", systemImage: "sparkles")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .textSelection(.enabled)
  }

  private var summary: String {
    "Sent \(report.exported.count), received \(report.imported.count), removed \(report.deletedLocally.count)"
      + (report.pushed ? ", pushed." : ".")
  }
}

private struct DotfilesVersionConflictRow: View {
  let conflict: DotfilesVersionConflict
  let keepLocal: () -> Void
  let useSynced: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(conflict.name)
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Compare", action: compare)
        .help("Show this Mac's copy and the synced copy in Finder")
      Button("Keep This Mac's", action: keepLocal)
        .help("This Mac's copy replaces the synced one on every Mac")
      Button("Use Synced", action: useSynced)
        .help("The synced copy replaces this Mac's; this Mac's is saved in Conflicts → replaced")
    }
  }

  private var detail: String {
    let files = conflict.paths.count == 1 ? "1 file differs" : "\(conflict.paths.count) files differ"
    return "\(conflict.origin) · \(files)"
  }

  private func compare() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let roots = DotfilesSyncRoot.defaults(
      kageConfigPath: DotfilesSyncClient.relativePath(of: SupacodePaths.configBaseDirectory, to: home)
    )
    let urls = [
      DotfilesSyncRoot.localURL(forRepoPath: conflict.unit, home: home, roots: roots),
      SupacodePaths.dotfilesRepositoryDirectory.appending(path: conflict.unit),
    ]
    NSWorkspace.shared.activateFileViewerSelecting(
      urls.compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path) }
    )
  }
}
