import ComposableArchitecture
import SwiftUI

/// Drives `claude auth login` for one account: the browser normally finishes the
/// sign-in by itself; when it can't, the page shows a code to paste here.
struct ClaudeLoginSheet: View {
  @Bindable var store: StoreOf<ClaudeAccountsFeature>

  var body: some View {
    let login = store.login
    let accountName = login.flatMap { store.file.account(id: $0.accountID)?.name } ?? "Claude"
    VStack(alignment: .leading, spacing: 12) {
      Text("Log In to \(accountName)")
        .font(.headline)

      switch login?.phase {
      case .running, .none:
        Label("Finish signing in in your browser.", systemImage: "safari")
          .foregroundStyle(.secondary)
      case .succeeded:
        Label("Logged in.", systemImage: "checkmark.circle")
          .foregroundStyle(.green)
      case .failed(let message):
        Label(message, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
      }

      if let url = login?.authorizationURL, login?.phase == .running {
        Link("Open the sign-in page again", destination: url)
          .help("Open the Claude sign-in page in your browser")
      }

      if login?.isWaitingForCode == true {
        HStack {
          TextField("Paste the code from the sign-in page", text: codeBinding)
            .font(.body.monospaced())
            .onSubmit { store.send(.loginCodeSubmitted) }
          Button("Submit") { store.send(.loginCodeSubmitted) }
            .disabled(login?.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            .help("Send the code to Claude Code (Return)")
        }
      }

      DisclosureGroup("Details") {
        ScrollView {
          Text(login?.transcript ?? "")
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 120)
      }

      HStack {
        Spacer()
        if login?.phase == .running {
          Button("Cancel", role: .cancel) { store.send(.loginDismissed) }
            .keyboardShortcut(.cancelAction)
            .help("Stop signing in (Esc)")
        } else {
          Button("Done") { store.send(.loginDismissed) }
            .keyboardShortcut(.defaultAction)
            .help("Close (Return)")
        }
      }
    }
    .padding(20)
    .frame(width: 480)
  }

  private var codeBinding: Binding<String> {
    Binding(
      get: { store.login?.code ?? "" },
      set: { store.send(.loginCodeChanged($0)) }
    )
  }
}
