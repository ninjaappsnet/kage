import ComposableArchitecture
import SwiftUI

struct NestedFolderPromptView: View {
  @Bindable var store: StoreOf<NestedFolderPromptFeature>

  var body: some View {
    Form {
      Section {
        Picker("Add it as", selection: $store.addAction) {
          Text("A plain folder").tag(NestedFolderAddAction.addAsFolder)
          Text("A new git repository").tag(NestedFolderAddAction.createGitRepository)
        }
        .pickerStyle(.inline)
        .disabled(store.isSubmitting)
        .help("A plain folder is added as-is; a new git repository runs git init in it first")
      } header: {
        Text(headerTitle)
        Text(
          """
          \(subjectDescription) inside \(store.parentSummary), which Kage already tracks, \
          and has no repository of its own. Adding it unchanged would land on \
          \(store.parentSummary) instead.
          """
        )
      }
      .headerProminence(.increased)

      Section {
        Picker("In \(store.parentSummary)", selection: $store.ignoreTarget) {
          Text("Leave it visible").tag(NestedFolderIgnoreTarget.doNotIgnore)
          Text("Ignore it locally").tag(NestedFolderIgnoreTarget.localExclude)
          Text("Ignore it in .gitignore").tag(NestedFolderIgnoreTarget.gitignore)
        }
        .pickerStyle(.inline)
        .disabled(store.isSubmitting)
        .help("Keeps the folder out of the parent repository's status output")
      } footer: {
        Text(ignoreFootnote)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        if store.isSubmitting {
          ProgressView()
            .controlSize(.small)
        }
        if let errorMessage = store.errorMessage, !errorMessage.isEmpty {
          Text(errorMessage)
            .foregroundStyle(.red)
            .lineLimit(2)
        }
        Spacer()
        Button("Cancel") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)
        .disabled(store.isSubmitting)
        .help("Don't add anything (Esc)")
        Button("Add") {
          store.send(.addButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(store.isSubmitting)
        .help("Add the folder with the options above (↩)")
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(minWidth: 460)
  }

  private var headerTitle: String {
    store.candidates.count == 1
      ? "Add “\(store.candidates[0].folderName)”"
      : "Add \(store.candidates.count) Folders"
  }

  private var subjectDescription: String {
    store.candidates.count == 1 ? "It sits" : "They sit"
  }

  private var ignoreFootnote: String {
    switch store.ignoreTarget {
    case .doNotIgnore:
      return "The folder keeps showing up as untracked in \(store.parentSummary)."
    case .localExclude:
      return "Written to .git/info/exclude — local to this clone, never committed."
    case .gitignore:
      return "Appended to the tracked .gitignore, so it becomes a change you commit."
    }
  }
}
