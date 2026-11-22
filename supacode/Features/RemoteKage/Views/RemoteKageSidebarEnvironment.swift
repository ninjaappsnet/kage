import ComposableArchitecture
import SwiftUI

extension EnvironmentValues {
  /// The remote Kage hosts store, handed to the sidebar through the
  /// environment so upstream's `SidebarView` / `SidebarListView` initializers
  /// stay untouched. nil (previews, tests) hides the host sections.
  @Entry var remoteKageStore: StoreOf<RemoteKageFeature>?
}
