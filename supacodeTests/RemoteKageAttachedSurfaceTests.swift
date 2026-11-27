import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

struct RemoteKageAttachLifecycleTests {
  @Test func startsOnlyOnce() {
    var lifecycle = RemoteKageAttachLifecycle()
    let first = lifecycle.start()
    let second = lifecycle.start()
    #expect(first)
    #expect(!second)
    #expect(lifecycle.phase == .running)
  }

  @Test func reportsTheEndOfARunningSessionExactlyOnce() {
    // Ghostty reports a normal exit twice (child exited, then close request).
    var lifecycle = RemoteKageAttachLifecycle()
    _ = lifecycle.start()
    let first = lifecycle.finish()
    let second = lifecycle.finish()
    #expect(first)
    #expect(!second)
    #expect(lifecycle.phase == .finished)
  }

  @Test func neverReportsAnEndBeforeStarting() {
    var lifecycle = RemoteKageAttachLifecycle()
    let finished = lifecycle.finish()
    #expect(!finished)
    #expect(lifecycle.phase == .idle)
  }

  @Test func closingARunningSurfaceFreesItWithoutReportingAnEnd() {
    // Removing the view is the owner's own detach: it must not be echoed back
    // as an exit when Ghostty reports the killed process afterwards.
    var lifecycle = RemoteKageAttachLifecycle()
    _ = lifecycle.start()
    let freed = lifecycle.close()
    let finished = lifecycle.finish()
    #expect(freed)
    #expect(!finished)
    #expect(lifecycle.phase == .closed)
  }

  @Test func closingAFinishedSurfaceStillFreesIt() {
    var lifecycle = RemoteKageAttachLifecycle()
    _ = lifecycle.start()
    _ = lifecycle.finish()
    let first = lifecycle.close()
    let second = lifecycle.close()
    #expect(first)
    #expect(!second)
  }

  @Test func closingBeforeStartingFreesNothingAndBlocksALateStart() {
    var lifecycle = RemoteKageAttachLifecycle()
    let freed = lifecycle.close()
    let started = lifecycle.start()
    #expect(!freed)
    #expect(!started)
    #expect(lifecycle.phase == .closed)
  }
}

@MainActor
struct RemoteKageAttachedSurfaceTests {
  private static let host = RemoteKageHost(name: "Mini", username: "ahmet", address: "mini.tail.ts.net")
  private static let zmxPath = "/Applications/Kage.app/Contents/Resources/zmx/zmx"
  private static let session = "supa-0259f68d-3ac4-42dd-a622-d055383ff36a"

  // MARK: - Configuration

  @Test func configurationRunsTheAttachCommandOutsideZmx() throws {
    let configuration = try RemoteKageAttachedSurface.Configuration.make(
      host: Self.host,
      zmxPath: Self.zmxPath,
      session: Self.session
    ).get()
    let expected = try RemoteKageAttachCommand.surfaceCommand(
      host: Self.host,
      zmxPath: Self.zmxPath,
      session: Self.session
    ).get()
    #expect(configuration.command == expected)
    // No local zmx wrapper: this Mac must not keep its own persistent copy.
    #expect(configuration.commandWrapper.isEmpty)
    // ssh is not a shell; Ghostty's integration has nothing to inject into.
    #expect(configuration.disableShellIntegration)
    // Not a worktree surface: no SUPACODE_* identity, so nothing local (agent
    // hooks, CLI) can mistake it for one of this Mac's tabs.
    #expect(configuration.environment.isEmpty)
    #expect(configuration.workingDirectory == URL.homeDirectory)
  }

  @Test func configurationRejectsAnUnsafeHost() {
    let host = RemoteKageHost(name: "Bad", username: "ahmet", address: "-oProxyCommand=x")
    #expect(
      RemoteKageAttachedSurface.Configuration.make(host: host, zmxPath: Self.zmxPath, session: Self.session)
        == .failure(.invalidDestination)
    )
  }

  // MARK: - Bridge wiring

  @Test func localTopologyActionsAreConsumedWithoutEffect() {
    let bridge = GhosttySurfaceBridge()
    var ends = 0
    RemoteKageAttachedSurface.wire(bridge, onEnd: { ends += 1 })
    #expect(bridge.onNewTab?() == true)
    #expect(bridge.onSplitAction?(.newSplit(direction: .right)) == true)
    #expect(bridge.onSplitAction?(.toggleSplitZoom) == true)
    #expect(bridge.onGotoTab?(GHOSTTY_GOTO_TAB_NEXT) == true)
    #expect(ends == 0)
  }

  @Test func closeTabClosesOnlyThisSurface() {
    let bridge = GhosttySurfaceBridge()
    var ends = 0
    RemoteKageAttachedSurface.wire(bridge, onEnd: { ends += 1 })
    #expect(bridge.onCloseTab?(GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS) == true)
    #expect(ends == 1)
  }

  @Test func processExitAndCloseRequestsEndTheSurface() {
    let bridge = GhosttySurfaceBridge()
    var ends = 0
    RemoteKageAttachedSurface.wire(bridge, onEnd: { ends += 1 })
    bridge.onChildExited?(0)
    bridge.closeSurface(processAlive: false)
    // Dedup is the lifecycle's job; the wiring forwards both.
    #expect(ends == 2)
  }

  // MARK: - Surface lifecycle (real Ghostty surface)

  @Test func startBuildsOneSurfaceAndCloseFreesItWithoutReportingAnExit() throws {
    var exits = 0
    let attached = RemoteKageAttachedSurface(
      configuration: Self.harmlessConfiguration,
      runtime: GhosttyRuntime(),
      onExit: { exits += 1 }
    )
    let view = attached.start(geometry: .fallback)
    #expect(view != nil)
    #expect(attached.start(geometry: .fallback) === view)
    attached.close()
    #expect(view?.surface == nil)
    #expect(attached.surfaceView == nil)
    // Ghostty reporting the killed process after the owner's own close.
    view?.bridge.closeSurface(processAlive: false)
    #expect(exits == 0)
  }

  @Test func startHandsPastesToThePasteController() throws {
    let controller = RemotePasteController(uploader: RemotePasteUploader { _ in "/tmp/kage-me/a.png" })
    let attached = RemoteKageAttachedSurface(
      configuration: Self.harmlessConfiguration,
      runtime: GhosttyRuntime(),
      pasteController: controller,
      onExit: {}
    )
    let view = try #require(attached.start(geometry: .fallback))
    defer { attached.close() }
    let interceptor = try #require(view.pasteInterceptor)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.declareTypes([.string], owner: nil)
    pasteboard.setString("plain text", forType: .string)
    // Text still pastes through the terminal itself.
    #expect(!interceptor(pasteboard))
    pasteboard.declareTypes([.png], owner: nil)
    pasteboard.setData(Data([1]), forType: .png)
    #expect(interceptor(pasteboard))
    #expect(controller.status == .uploading(itemCount: 1))
  }

  @Test func withoutAPasteControllerTheSurfacePastesAsBefore() throws {
    let attached = RemoteKageAttachedSurface(
      configuration: Self.harmlessConfiguration,
      runtime: GhosttyRuntime(),
      onExit: {}
    )
    let view = try #require(attached.start(geometry: .fallback))
    defer { attached.close() }
    #expect(view.pasteInterceptor == nil)
  }

  @Test func theProcessEndingReportsExitOnce() throws {
    var exits = 0
    let attached = RemoteKageAttachedSurface(
      configuration: Self.harmlessConfiguration,
      runtime: GhosttyRuntime(),
      onExit: { exits += 1 }
    )
    let view = try #require(attached.start(geometry: .fallback))
    defer { attached.close() }
    view.bridge.onChildExited?(0)
    view.bridge.closeSurface(processAlive: false)
    #expect(exits == 1)
  }

  @Test func neverStartsAfterClose() {
    let attached = RemoteKageAttachedSurface(
      configuration: Self.harmlessConfiguration,
      runtime: GhosttyRuntime(),
      onExit: {}
    )
    attached.close()
    #expect(attached.start(geometry: .fallback) == nil)
  }

  /// A real surface needs a real child; this one waits on stdin and dies with
  /// the surface's SIGHUP, never touching the network.
  private static let harmlessConfiguration = RemoteKageAttachedSurface.Configuration(
    command: "/bin/cat",
    workingDirectory: URL.homeDirectory,
    environment: [:],
    commandWrapper: [],
    disableShellIntegration: true
  )
}

struct RemoteKageSurfaceFocusTests {
  @Test(arguments: [
    RemoteKageSurfaceFocus.Owner.none, .window, .terminal, .other,
  ])
  func firstShowTakesFocusFromAnythingButTextInput(owner: RemoteKageSurfaceFocus.Owner) {
    #expect(RemoteKageSurfaceFocus.shouldClaim(firstShow: true, currentOwner: owner))
  }

  @Test func firstShowNeverStealsFromTextInput() {
    // Typing in a search field or a rename box must not be yanked away.
    #expect(!RemoteKageSurfaceFocus.shouldClaim(firstShow: true, currentOwner: .textInput))
  }

  @Test(arguments: [RemoteKageSurfaceFocus.Owner.none, .window, .terminal])
  func reshowReclaimsOnlyFromNobodyOrATerminal(owner: RemoteKageSurfaceFocus.Owner) {
    #expect(RemoteKageSurfaceFocus.shouldClaim(firstShow: false, currentOwner: owner))
  }

  @Test(arguments: [RemoteKageSurfaceFocus.Owner.other, .textInput])
  func reshowLeavesOtherOwnersAlone(owner: RemoteKageSurfaceFocus.Owner) {
    #expect(!RemoteKageSurfaceFocus.shouldClaim(firstShow: false, currentOwner: owner))
  }

  @Test func classifiesResponders() {
    let window = NSWindow()
    #expect(RemoteKageSurfaceFocus.owner(of: nil, in: window) == .none)
    #expect(RemoteKageSurfaceFocus.owner(of: window, in: window) == .window)
    #expect(RemoteKageSurfaceFocus.owner(of: NSTextView(), in: window) == .textInput)
    #expect(RemoteKageSurfaceFocus.owner(of: NSButton(), in: window) == .other)
  }
}
