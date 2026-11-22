import ComposableArchitecture
import Foundation

/// Settings → Remote Hosts: add, edit and remove the hosts in
/// `remote-hosts.json`. Implemented in Phase 2.
@Reducer
struct RemoteKageSettingsFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.remoteKageHostsFile) var file = RemoteKageHostsFile()
  }

  enum Action: Equatable {}

  var body: some Reducer<State, Action> {
    EmptyReducer()
  }
}
