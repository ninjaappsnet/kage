import Foundation

/// The life of one attached remote terminal, kept apart from AppKit so the
/// rules are testable:
/// - the surface is built once, never again after it was closed;
/// - the end of the session (the ssh loop exited, or Ghostty asked to close
///   the surface) is reported to the owner exactly once, and only while it
///   runs: Ghostty reports a normal exit twice (child exited, then close);
/// - the owner's own close (the view went away) frees the surface and is never
///   echoed back as an end, even when Ghostty reports the killed child after.
nonisolated struct RemoteKageAttachLifecycle: Equatable, Sendable {
  enum Phase: Equatable, Sendable {
    case idle
    case running
    /// The session ended on its own; the surface is still allocated.
    case finished
    /// The owner closed it; the surface is freed.
    case closed
  }

  private(set) var phase: Phase = .idle

  /// True when the caller should build the surface now.
  mutating func start() -> Bool {
    guard phase == .idle else { return false }
    phase = .running
    return true
  }

  /// True when the caller should report the end to the owner.
  mutating func finish() -> Bool {
    guard phase == .running else { return false }
    phase = .finished
    return true
  }

  /// True when the caller should free the surface.
  mutating func close() -> Bool {
    let hadSurface = phase == .running || phase == .finished
    phase = .closed
    return hadSurface
  }
}
