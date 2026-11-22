import ComposableArchitecture
import SwiftUI

/// Settings → Remote Hosts.
struct RemoteKageSettingsView: View {
  @Bindable var store: StoreOf<RemoteKageSettingsFeature>

  var body: some View {
    Form {
      Section {
        if store.file.hosts.isEmpty {
          Text("No remote hosts yet.")
            .foregroundStyle(.secondary)
        }
        ForEach(store.file.hosts) { host in
          RemoteKageHostRow(
            host: host,
            onEdit: { store.send(.editButtonTapped(host.id)) },
            onRemove: { store.send(.removeButtonTapped(host.id)) }
          )
        }
      } header: {
        HStack {
          Text("Hosts")
          Spacer()
          Button("Add Host…", systemImage: "plus") {
            store.send(.addButtonTapped)
          }
          .help("Add another Mac running Kage")
        }
      } footer: {
        Text(
          """
          Kage on this Mac shows the projects and sessions of Kage running on these Macs over SSH. \
          Set up SSH key login first (ssh-copy-id user@address), and the other Mac needs a Kage \
          build with remote host support.
          """
        )
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Remote Hosts")
    .sheet(isPresented: $store.isEditorPresented) {
      RemoteKageHostEditor(store: store)
    }
    .alert($store.scope(state: \.alert, action: \.alert))
  }
}

private struct RemoteKageHostRow: View {
  let host: RemoteKageHost
  let onEdit: () -> Void
  let onRemove: () -> Void

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(host.name)
        Text(host.sshDestination)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer()
      Button("Edit…", action: onEdit)
        .help("Edit this host")
      Button("Remove…", role: .destructive, action: onRemove)
        .help("Stop showing this host")
    }
  }
}

private struct RemoteKageHostEditor: View {
  @Bindable var store: StoreOf<RemoteKageSettingsFeature>

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          field("Name", prompt: "Mini 1", text: $store.draft.name, issue: store.nameIssue, invalid: "")
          field(
            "Username", prompt: "user", text: $store.draft.username, issue: store.usernameIssue,
            invalid: "Use letters, digits, dot, underscore and hyphen only.", monospaced: true)
          field(
            "Address", prompt: "mini.local or 192.168.1.20", text: $store.draft.address, issue: store.addressIssue,
            invalid: "Enter a DNS name, an IPv4 address or an IPv6 address.", monospaced: true)
        } header: {
          Text(store.isEditing ? "Edit Host" : "Add Host")
        }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Cancel") { store.send(.cancelEditorTapped) }
          .keyboardShortcut(.cancelAction)
          .help("Discard changes (Esc)")
        Button("Save") { store.send(.saveEditorTapped) }
          .keyboardShortcut(.defaultAction)
          .disabled(!store.canSave)
          .help("Save this host (Return)")
      }
      .padding()
    }
    .frame(minWidth: 420)
  }

  @ViewBuilder
  private func field(
    _ title: LocalizedStringKey,
    prompt: String,
    text: Binding<String>,
    issue: RemoteKageHostIssue?,
    invalid: String,
    monospaced: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      TextField(title, text: text, prompt: Text(prompt))
        .font(monospaced ? .body.monospaced() : .body)
        .autocorrectionDisabled()
      // A blank field only disables Save; wording appears once there is input.
      if let issue, issue != .required {
        Text(issue.message(invalid: invalid))
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }
}
