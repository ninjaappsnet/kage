import Sharing

extension SharedKey where Self == AppStorageKey<Bool>.Default {
  /// View → Show Claude Usage in Sidebar. On by default so the panel is found.
  static var claudeUsageSidebarPanelVisible: Self {
    Self[.appStorage("claudeUsageSidebarPanelVisible"), default: true]
  }
}

extension SidebarBottomCardView.Slot {
  /// This fork shows no upstream feature announcements at the sidebar bottom;
  /// cards the user can act on (git error, agent install prompt) stay.
  var withoutAnnouncements: Self {
    switch self {
    case .layoutModes, .fileExplorerBeta: .none
    case .none, .gitEnvironmentError, .agent: self
    }
  }
}
