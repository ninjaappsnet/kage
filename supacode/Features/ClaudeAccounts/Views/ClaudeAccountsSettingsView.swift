import ComposableArchitecture
import SupacodeSettingsFeature
import SupacodeSettingsShared
import SwiftUI

/// Settings → Claude Accounts.
struct ClaudeAccountsSettingsView: View {
  @Bindable var store: StoreOf<ClaudeAccountsFeature>
  /// Local repositories, for per-repository overrides. Remote ones are left out:
  /// their sessions run elsewhere, so a local config directory can't apply.
  let repositories: [SettingsRepositorySummary]

  var body: some View {
    Form {
      Section {
        ForEach(store.file.allAccounts) { account in
          ClaudeAccountRow(
            account: account,
            status: store.statuses[account.id],
            usage: store.usages[account.id]?.usage,
            isDefault: store.file.defaultAccountID == account.id,
            onLogin: { store.send(.loginButtonTapped(account.id)) },
            onLogout: { store.send(.logoutButtonTapped(account.id)) },
            onRename: { store.send(.renameAccount(account.id, $0)) },
            onRemove: { store.send(.removeAccountButtonTapped(account.id)) }
          )
        }
      } header: {
        HStack {
          Text("Accounts")
          Spacer()
          Button("Add Account…", systemImage: "plus") {
            store.send(.addAccountButtonTapped)
          }
          .help("Add another Claude Code login")
        }
      } footer: {
        if let errorMessage = store.errorMessage {
          Text(errorMessage).foregroundStyle(.red)
        }
      }

      Section {
        Picker(
          "New terminal sessions use",
          selection: Binding(
            get: { store.file.defaultAccountID },
            set: { store.send(.setDefaultAccount($0)) }
          )
        ) {
          ForEach(store.file.allAccounts) { account in
            Text(account.name).tag(account.id)
          }
        }
        .help("The account claude runs as in new terminal tabs, unless a repository or tab overrides it")
      } header: {
        Text("Default")
      } footer: {
        Text(
          """
          Applies to sessions started after the change. Use File → New Tab with Claude Account to pick \
          one for a single tab. A CLAUDE_CONFIG_DIR exported by your shell's rc file overrides this.
          """
        )
      }

      if !repositories.isEmpty {
        Section("Repositories") {
          ForEach(repositories, id: \.id) { repository in
            let path = repository.rootURL.path(percentEncoded: false)
            let key = ClaudeAccountEnvironment.normalizedPath(path)
            Picker(
              repository.name,
              selection: Binding(
                get: { store.file.repositoryAccountIDs[key] },
                set: { store.send(.setRepositoryAccount(repositoryRootPath: path, $0)) }
              )
            ) {
              Text("Default").tag(ClaudeAccountID?.none)
              Divider()
              ForEach(store.file.allAccounts) { account in
                Text(account.name).tag(ClaudeAccountID?.some(account.id))
              }
            }
            .help("The account claude runs as in this repository's new terminal tabs")
          }
        }
      }

      Section {
        LabeledContent("Personal MCP servers") {
          HStack {
            ClaudeMCPSyncStatusView(state: store.mcpSync)
            Button("Sync Now") {
              store.send(.syncMCPServersButtonTapped)
            }
            .disabled(store.mcpSync == .syncing)
            .help("Copy MCP servers added with --scope user to every account now")
          }
        }
      } header: {
        Text("Shared Between Accounts")
      } footer: {
        Text(
          """
          Every account shares ~/.claude: history and resume, memory, settings and hooks, plugins, skills, \
          agents, commands and CLAUDE.md. Personal MCP servers are copied between accounts, so one added in \
          any account appears in all of them. Each account keeps its own login, claude.ai connectors and \
          folder-trust answers.
          """
        )
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Claude Accounts")
    .task { store.send(.refreshStatuses) }
    .sheet(isPresented: $store.isAddAccountPresented) {
      ClaudeAddAccountSheet(store: store)
    }
    .sheet(
      isPresented: Binding(
        get: { store.login != nil },
        set: { if !$0 { store.send(.loginDismissed) } }
      )
    ) {
      ClaudeLoginSheet(store: store)
    }
    .alert($store.scope(state: \.alert, action: \.alert))
  }
}

private struct ClaudeAccountRow: View {
  let account: ClaudeAccount
  let status: ClaudeAccountsFeature.StatusEntry?
  let usage: ClaudeUsage?
  let isDefault: Bool
  let onLogin: () -> Void
  let onLogout: () -> Void
  let onRename: (String) -> Void
  let onRemove: () -> Void

  @State private var draftName = ""
  @FocusState private var isEditingName: Bool

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          if account.isMain {
            Text(account.name)
          } else {
            TextField("Name", text: $draftName)
              .textFieldStyle(.plain)
              .focused($isEditingName)
              .onSubmit { onRename(draftName) }
              .onChange(of: isEditingName) { _, editing in
                if !editing { onRename(draftName) }
              }
              .fixedSize()
              .help("Rename this account")
          }
          if isDefault {
            Text("Default")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text(account.configDirectoryPath.map(Self.abbreviated) ?? "~/.claude")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        ClaudeAccountStatusView(status: status)
        if let usage {
          ClaudeAccountUsageView(usage: usage)
        }
      }
      Spacer()
      if case .loaded(let status) = status, status.loggedIn, status.health(now: Date()) == .loggedIn {
        Button("Log Out", action: onLogout)
          .help("Sign this account out of Claude Code")
      } else {
        Button("Log In…", action: onLogin)
          .help("Sign in to Claude Code with this account")
      }
      if !account.isMain {
        Menu {
          Button("Log In Again…", action: onLogin)
          Divider()
          Button("Remove Account…", role: .destructive, action: onRemove)
        } label: {
          Image(systemName: "ellipsis.circle")
            .accessibilityLabel("More actions")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("More actions for this account")
      }
    }
    .onAppear { draftName = account.name }
    .onChange(of: account.name) { _, name in draftName = name }
  }

  private static func abbreviated(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
    return path.hasPrefix(trimmedHome) ? "~" + path.dropFirst(trimmedHome.count) : path
  }
}

private struct ClaudeAccountStatusView: View {
  let status: ClaudeAccountsFeature.StatusEntry?

  var body: some View {
    switch status {
    case .none, .loading:
      Text("Checking…")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .loaded(let status):
      loaded(status)
    }
  }

  @ViewBuilder
  private func loaded(_ status: ClaudeAuthStatus) -> some View {
    let identity = [status.email, status.subscriptionType.map { $0.capitalized }]
      .compactMap { $0 }
      .joined(separator: " · ")
    switch status.health(now: Date()) {
    case .loggedIn:
      Text(identity.isEmpty ? "Logged in" : identity)
        .font(.caption)
        .foregroundStyle(.secondary)
    case .expiringSoon(let date):
      Label(
        "\(identity) — login expires \(date.formatted(.relative(presentation: .named)))",
        systemImage: "clock.badge.exclamationmark"
      )
      .font(.caption)
      .foregroundStyle(.orange)
    case .expired:
      Label("Login expired — log in again", systemImage: "exclamationmark.circle")
        .font(.caption)
        .foregroundStyle(.red)
    case .loggedOut:
      Text("Not logged in")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct ClaudeMCPSyncStatusView: View {
  let state: ClaudeAccountsFeature.MCPSyncState

  var body: some View {
    switch state {
    case .idle:
      EmptyView()
    case .syncing:
      ProgressView().controlSize(.small)
    case .synced(let date):
      Text("Synced \(date.formatted(.relative(presentation: .named)))")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.red)
        .lineLimit(2)
    }
  }
}

private struct ClaudeAddAccountSheet: View {
  @Bindable var store: StoreOf<ClaudeAccountsFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add Claude Account")
        .font(.headline)
      Text("Give the account a name, then sign in. Kage sets up its folder so it shares everything with ~/.claude.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      TextField("Name, e.g. Work", text: $store.newAccountName)
        .onSubmit { store.send(.addAccountConfirmed) }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { store.send(.addAccountCancelled) }
          .keyboardShortcut(.cancelAction)
          .help("Close without adding an account (Esc)")
        Button("Add and Log In…") { store.send(.addAccountConfirmed) }
          .keyboardShortcut(.defaultAction)
          .disabled(!store.isNewAccountNameValid)
          .help("Create the account and start signing in (Return)")
      }
    }
    .padding(20)
    .frame(width: 420)
  }
}
