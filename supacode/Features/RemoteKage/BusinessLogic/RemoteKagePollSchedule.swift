import Foundation

/// Per-host polling cadence: every tick while the host answers, exponential
/// backoff (5 s, 10 s, 20 s, 40 s, then 60 s) while it doesn't.
nonisolated struct RemoteKagePollSchedule: Equatable, Sendable {
  static let tickInterval: Duration = .seconds(5)
  static let maximumRetryDelay: Duration = .seconds(60)

  private(set) var failureCount = 0
  private var ticksToSkip = 0

  /// How long to wait before the next attempt after `failures` failures in a row.
  static func retryDelay(afterFailures failures: Int) -> Duration {
    guard failures > 0 else { return tickInterval }
    let doubled = tickInterval * (1 << min(failures - 1, 5))
    return min(doubled, maximumRetryDelay)
  }

  /// Called once per tick; true when this tick should poll.
  mutating func consumeTick() -> Bool {
    guard ticksToSkip > 0 else { return true }
    ticksToSkip -= 1
    return false
  }

  mutating func recordFailure() {
    failureCount += 1
    let ticks = Int((Self.retryDelay(afterFailures: failureCount) / Self.tickInterval).rounded(.up))
    ticksToSkip = max(ticks - 1, 0)
  }

  mutating func recordSuccess() {
    failureCount = 0
    ticksToSkip = 0
  }
}
