import Foundation
import Synchronization

/// Paces `kage host serve` events so an agent rewriting hundreds of files
/// costs the link a handful of lines: `changed` paths batch over 200 ms;
/// `treeChanged` goes out at once, then at most once a second per root (a
/// trailing one when more changes landed inside the window); `rescan` goes
/// out at once. Timers exist only while something is pending, so an idle host
/// does no work at all.
nonisolated final class RemoteFileEventCoalescer: Sendable {
  private struct TreeWindow {
    var pending = false
    var generation: Int
    var task: Task<Void, Never>
  }

  private struct State {
    var pendingChanged: Set<String> = []
    var changedTask: Task<Void, Never>?
    var changedGeneration = 0
    var trees: [String: TreeWindow] = [:]
    var nextGeneration = 0
  }

  private let state = Mutex(State())
  private let clock: any Clock<Duration>
  private let changedDelay: Duration
  private let treeInterval: Duration
  private let emit: @Sendable (RemoteFileEvent) -> Void

  init(
    clock: any Clock<Duration>,
    changedDelay: Duration = .milliseconds(200),
    treeInterval: Duration = .seconds(1),
    emit: @escaping @Sendable (RemoteFileEvent) -> Void
  ) {
    self.clock = clock
    self.changedDelay = changedDelay
    self.treeInterval = treeInterval
    self.emit = emit
  }

  func ingest(_ classification: RemoteFileEventClassification) {
    var immediate: [RemoteFileEvent] = classification.rescans.sorted().map { .rescan(path: $0) }
    state.withLock { state in
      if !classification.changed.isEmpty {
        state.pendingChanged.formUnion(classification.changed)
        if state.changedTask == nil {
          state.nextGeneration += 1
          let generation = state.nextGeneration
          state.changedGeneration = generation
          state.changedTask = Task { [weak self, clock, changedDelay] in
            try? await clock.sleep(for: changedDelay)
            guard !Task.isCancelled else { return }
            self?.flushChanged(generation: generation)
          }
        }
      }
      for root in classification.treeRoots.sorted() {
        if state.trees[root] != nil {
          state.trees[root]?.pending = true
        } else {
          immediate.append(.treeChanged(root: root))
          state.trees[root] = openTreeWindow(root, in: &state)
        }
      }
    }
    for event in immediate { emit(event) }
  }

  /// Drops everything pending and stops every timer.
  func cancel() {
    state.withLock { state in
      state.changedTask?.cancel()
      state.changedTask = nil
      state.pendingChanged = []
      for window in state.trees.values { window.task.cancel() }
      state.trees = [:]
    }
  }

  private func flushChanged(generation: Int) {
    let paths: [String]? = state.withLock { state in
      guard state.changedGeneration == generation, state.changedTask != nil else { return nil }
      state.changedTask = nil
      defer { state.pendingChanged = [] }
      return state.pendingChanged.sorted()
    }
    guard let paths, !paths.isEmpty else { return }
    emit(.changed(paths: paths))
  }

  private func openTreeWindow(_ root: String, in state: inout State) -> TreeWindow {
    state.nextGeneration += 1
    let generation = state.nextGeneration
    let task = Task { [weak self, clock, treeInterval] in
      try? await clock.sleep(for: treeInterval)
      guard !Task.isCancelled else { return }
      self?.closeTreeWindow(root, generation: generation)
    }
    return TreeWindow(generation: generation, task: task)
  }

  private func closeTreeWindow(_ root: String, generation: Int) {
    let emitTrailing = state.withLock { state -> Bool in
      guard let window = state.trees[root], window.generation == generation else { return false }
      guard window.pending else {
        state.trees[root] = nil
        return false
      }
      state.trees[root] = openTreeWindow(root, in: &state)
      return true
    }
    if emitTrailing { emit(.treeChanged(root: root)) }
  }
}
