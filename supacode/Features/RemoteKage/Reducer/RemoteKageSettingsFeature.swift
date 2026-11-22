import ComposableArchitecture
import Foundation

/// Settings → Remote Hosts: add, edit and remove the hosts in
/// `remote-hosts.json`. Values are validated by `RemoteKageHost.validate*`
/// (they reach ssh's argv) and saved trimmed.
@Reducer
struct RemoteKageSettingsFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.remoteKageHostsFile) var file = RemoteKageHostsFile()
    var draft = Draft()
    var isEditorPresented = false
    @Presents var alert: AlertState<Alert>?

    /// The add / edit form. `id` is nil while adding.
    nonisolated struct Draft: Equatable, Sendable {
      var id: RemoteKageHost.ID?
      var name = ""
      var username = ""
      var address = ""
    }

    var isEditing: Bool { draft.id != nil }

    private var otherHosts: [RemoteKageHost] { file.hosts.filter { $0.id != draft.id } }
    var nameIssue: RemoteKageHostIssue? { RemoteKageHost.validateName(draft.name, among: otherHosts) }
    var usernameIssue: RemoteKageHostIssue? { RemoteKageHost.validateUsername(draft.username) }
    var addressIssue: RemoteKageHostIssue? { RemoteKageHost.validateAddress(draft.address) }
    var canSave: Bool { nameIssue == nil && usernameIssue == nil && addressIssue == nil }
  }

  enum Action: Equatable, BindableAction {
    case binding(BindingAction<State>)
    case addButtonTapped
    case editButtonTapped(RemoteKageHost.ID)
    case cancelEditorTapped
    case saveEditorTapped
    case removeButtonTapped(RemoteKageHost.ID)
    case alert(PresentationAction<Alert>)
  }

  enum Alert: Equatable {
    case confirmRemove(RemoteKageHost.ID)
  }

  @Dependency(\.remoteKageCurrentUser) var currentUser
  @Dependency(\.uuid) var uuid

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .addButtonTapped:
        state.draft = State.Draft(username: currentUser.name())
        state.isEditorPresented = true
        return .none

      case .editButtonTapped(let id):
        guard let host = state.file.hosts.first(where: { $0.id == id }) else { return .none }
        state.draft = State.Draft(id: host.id, name: host.name, username: host.username, address: host.address)
        state.isEditorPresented = true
        return .none

      case .cancelEditorTapped:
        state.isEditorPresented = false
        return .none

      case .saveEditorTapped:
        guard state.canSave else { return .none }
        let draft = state.draft
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = RemoteKageHost.normalizedAddress(draft.address)
        state.$file.withLock { file in
          if let id = draft.id, let index = file.hosts.firstIndex(where: { $0.id == id }) {
            file.hosts[index].name = name
            file.hosts[index].username = username
            file.hosts[index].address = address
          } else if draft.id == nil {
            file.hosts.append(RemoteKageHost(id: uuid(), name: name, username: username, address: address))
          }
        }
        state.isEditorPresented = false
        return .none

      case .removeButtonTapped(let id):
        guard let host = state.file.hosts.first(where: { $0.id == id }) else { return .none }
        state.alert = AlertState {
          TextState("Remove \(host.name)?")
        } actions: {
          ButtonState(role: .destructive, action: .confirmRemove(id)) {
            TextState("Remove")
          }
          ButtonState(role: .cancel) {
            TextState("Cancel")
          }
        } message: {
          TextState("Kage stops showing \(host.sshDestination). Nothing changes on that Mac.")
        }
        return .none

      case .alert(.presented(.confirmRemove(let id))):
        state.$file.withLock { $0.hosts.removeAll { $0.id == id } }
        return .none

      case .alert:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
  }
}

// MARK: - This Mac's user name

/// This Mac's user name, injectable for tests.
nonisolated struct RemoteKageCurrentUser: Sendable {
  var name: @Sendable () -> String
}

private nonisolated enum RemoteKageCurrentUserKey: DependencyKey {
  static let liveValue = RemoteKageCurrentUser(name: { NSUserName() })
  static let testValue = RemoteKageCurrentUser(name: { "tester" })
}

extension DependencyValues {
  /// The login name pre-filled for a new host (this Mac's user).
  nonisolated var remoteKageCurrentUser: RemoteKageCurrentUser {
    get { self[RemoteKageCurrentUserKey.self] }
    set { self[RemoteKageCurrentUserKey.self] = newValue }
  }
}
