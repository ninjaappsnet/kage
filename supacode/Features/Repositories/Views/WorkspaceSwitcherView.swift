import ComposableArchitecture
import OrderedCollections
import SwiftUI

/// Top-of-sidebar workspace switcher. A workspace is a named filter over
/// repositories (single membership via `SidebarState.Section.workspaceID`):
/// switching filters the sidebar to that workspace's projects, "All Projects"
/// clears the filter. The dropdown also creates / renames / deletes workspaces.
///
/// Lives in its own file (mounted via a single `.safeAreaInset` in
/// `SidebarView`) so the workspaces feature stays additive to upstream — see
/// "Minimizing Upstream Merge Conflicts" in AGENTS.md.
struct WorkspaceSwitcherView: View {
  @Bindable var store: StoreOf<RepositoriesFeature>
  @State private var prompt: Prompt?
  @State private var promptText = ""

  /// A pending name-entry prompt surfaced as an alert with a text field.
  enum Prompt: Equatable, Identifiable {
    case create
    case rename(id: SidebarState.Workspace.ID, current: String)

    var id: String {
      switch self {
      case .create: "create"
      case .rename(let id, _): "rename-\(id)"
      }
    }

    var title: String {
      switch self {
      case .create: "New Workspace"
      case .rename: "Rename Workspace"
      }
    }

    var confirmTitle: String {
      switch self {
      case .create: "Create"
      case .rename: "Rename"
      }
    }
  }

  var body: some View {
    let sidebar = store.state.sidebar
    let workspaces = Array(sidebar.workspaces.values)
    let activeID = sidebar.activeWorkspaceID
    let activeWorkspace = activeID.flatMap { sidebar.workspaces[$0] }

    Menu {
      Picker("Active Workspace", selection: activeWorkspaceBinding) {
        Text("All Projects").tag(SidebarState.Workspace.ID?.none)
        ForEach(workspaces) { workspace in
          Text(workspace.name).tag(SidebarState.Workspace.ID?.some(workspace.id))
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()

      Divider()

      Button {
        promptText = ""
        prompt = .create
      } label: {
        Label("New Workspace…", systemImage: "plus")
      }

      if let activeWorkspace {
        Button {
          promptText = activeWorkspace.name
          prompt = .rename(id: activeWorkspace.id, current: activeWorkspace.name)
        } label: {
          Label("Rename “\(activeWorkspace.name)”…", systemImage: "pencil")
        }
        Button(role: .destructive) {
          store.send(.deleteWorkspace(id: activeWorkspace.id))
        } label: {
          Label("Delete “\(activeWorkspace.name)”", systemImage: "trash")
        }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "rectangle.3.group")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(activeWorkspace?.name ?? "All Projects")
          .fontWeight(.medium)
          .lineLimit(1)
        Spacer(minLength: 0)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .contentShape(.rect)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
    .help("Switch, create, rename, or delete a workspace to filter the projects shown in the sidebar")
    .alert(prompt?.title ?? "", isPresented: promptPresented, presenting: prompt) { prompt in
      TextField("Name", text: $promptText)
      Button(prompt.confirmTitle) { submit(prompt) }
      Button("Cancel", role: .cancel) {}
    }
  }

  private var activeWorkspaceBinding: Binding<SidebarState.Workspace.ID?> {
    Binding(
      get: { store.state.sidebar.activeWorkspaceID },
      set: { store.send(.setActiveWorkspace($0)) }
    )
  }

  private var promptPresented: Binding<Bool> {
    Binding(
      get: { prompt != nil },
      set: { isPresented in
        if !isPresented { prompt = nil }
      }
    )
  }

  private func submit(_ prompt: Prompt) {
    let name = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    switch prompt {
    case .create:
      store.send(.createWorkspace(name: name))
    case .rename(let id, _):
      store.send(.renameWorkspace(id: id, name: name))
    }
  }
}

/// Reusable context-menu submenu that assigns a repository to a workspace
/// (single membership). Used by both the git repo section-header ellipsis menu
/// and the folder row context menu. Workspaces are created in
/// `WorkspaceSwitcherView`; this menu only assigns to existing ones, or clears
/// membership with "None".
struct WorkspaceAssignmentMenu: View {
  let repositoryID: Repository.ID
  @Bindable var store: StoreOf<RepositoriesFeature>

  var body: some View {
    let sidebar = store.state.sidebar
    let workspaces = Array(sidebar.workspaces.values)
    Menu {
      if workspaces.isEmpty {
        Button("No Workspaces") {}
          .disabled(true)
      } else {
        Picker("Workspace", selection: assignmentBinding) {
          Text("None").tag(SidebarState.Workspace.ID?.none)
          ForEach(workspaces) { workspace in
            Text(workspace.name).tag(SidebarState.Workspace.ID?.some(workspace.id))
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
    } label: {
      Label("Move to Workspace", systemImage: "rectangle.3.group")
    }
  }

  private var assignmentBinding: Binding<SidebarState.Workspace.ID?> {
    Binding(
      get: { store.state.sidebar.sections[repositoryID]?.workspaceID },
      set: { store.send(.assignRepositoryToWorkspace(repositoryID: repositoryID, workspaceID: $0)) }
    )
  }
}
