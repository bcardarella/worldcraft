import Foundation

/// Optional preparation must never be a barrier to attaching the scene or
/// delivering frames. Each job has its own task; cancellation invalidates late
/// completions even when a framework operation does not cooperate with it.
@MainActor public final class ScenePreparation {
  public enum Job: String, CaseIterable, Sendable {
    case tracking, planets, audio, rocketAudio
  }
  public enum Event: Sendable {
    case started(Job)
    case finished(Job, milliseconds: Double)
    case failed(Job, message: String)
  }
  public var onEvent: (@MainActor (Event) -> Void)?
  private var tasks: [Job: Task<Void, Never>] = [:]
  private var generation = UUID()
  public var pending: [Job] { Job.allCases.filter { tasks[$0] != nil } }

  public init() {}

  public func launch(_ job: Job, operation: @escaping @MainActor @Sendable () async throws -> Void) {
    guard tasks[job] == nil else { return }
    let epoch = generation
    tasks[job] = Task { [weak self] in
      guard !Task.isCancelled else { return }
      let started = ProcessInfo.processInfo.systemUptime
      var failure: String?
      var cancelled = false
      do { try await operation() }
      catch is CancellationError { cancelled = true }
      catch { failure = error.localizedDescription }
      guard let self, !Task.isCancelled, self.generation == epoch else { return }
      self.tasks[job] = nil
      guard !cancelled else { return }
      if let failure { self.onEvent?(.failed(job, message: failure)) }
      else {
        self.onEvent?(.finished(job, milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000))
      }
    }
    onEvent?(.started(job))
  }

  public func cancel() {
    generation = UUID()
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
  }
}
