import SwiftUI

/// A live terminal attached to one remote zmx session over SSH. Closing it
/// (removing the view) detaches; the session keeps running on the host.
/// Implemented in Phase 5.
struct RemoteKageAttachedTerminalView: View {
  let host: RemoteKageHost
  let zmxPath: String
  let session: String

  var body: some View {
    ContentUnavailableView("Attaching isn't available yet", systemImage: "terminal")
  }
}
