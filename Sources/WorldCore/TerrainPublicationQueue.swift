import Foundation

/// Pace synchronous native buffer work independently of callback frequency.
/// Framework awaits do not spend this budget. A single expensive allocation
/// must make progress, but its followers wait for the next service window.
public struct TerrainBufferBudget: Sendable {
  private let interval, budget: Double
  private var began = -Double.infinity, spent = 0.0, estimate = 0.0007
  public init(interval: Double = 1.0 / 90.0, budget: Double = 0.0022) {
    precondition(interval > 0 && budget > 0 && budget <= interval)
    self.interval = interval; self.budget = budget
  }
  public mutating func delay(at time: Double) -> Double {
    if time - began >= interval { began = time; spent = 0 }
    guard spent > 0, spent + estimate > budget else { return 0 }
    return max(0, interval - (time - began))
  }
  public mutating func record(seconds: Double) {
    guard seconds.isFinite, seconds >= 0 else { return }
    spent += seconds; estimate = estimate * 0.75 + seconds * 0.25
  }
}

public struct TerrainPublicationMetrics: Sendable, Encodable {
  public let running, ready, retainedBytes, peakEntries, peakBytes: Int
  public let maximumRunning, maximumEntries, byteWatermark: Int
  public let admitted, completed, failed, discarded, oversized: Int
  /// Includes scheduling and suspension; never label this CPU or GPU time.
  public let preparationLatency, readyWait: DurationTiming.Snapshot
}

/// Native resources stay on MainActor. Only the framework operation suspends;
/// no detached task may touch its output. There is no extra pending queue.
/// Canceled jobs retain their count/byte reservations until they really return.
@MainActor public final class TerrainPublicationQueue<Value> {
  public struct Ready {
    public let input: PreparedTerrainTile
    public let result: Result<Value, Error>
  }
  private struct Running {
    let input: PreparedTerrainTile
    let bytes: Int
    let started: Double
    let task: Task<Void, Never>
    var current: Bool
  }
  private struct Finished {
    let value: Ready
    let bytes: Int
    let finished: Double
  }
  public let maximumRunning, maximumEntries, byteWatermark: Int
  private let prepare: @MainActor (PreparedTerrainTile) async throws -> Value
  private let discard: @MainActor (Value) -> Void
  private var running: [UUID: Running] = [:]
  private var ready: [Finished] = []
  private var bytes = 0, peakEntries = 0, peakBytes = 0
  private var admitted = 0, completed = 0, failed = 0, discarded = 0, oversized = 0
  private var latency = DurationTiming(), wait = DurationTiming()
  /// A bounded consumer may refill freed preparation slots independently of
  /// rendering. This only signals; it must not synchronously re-enter the queue.
  public var onCapacityAvailable: (@MainActor () -> Void)?

  public init(maximumRunning: Int = 2, maximumEntries: Int = 4,
    byteWatermark: Int = 16 * 1_024 * 1_024,
    prepare: @escaping @MainActor (PreparedTerrainTile) async throws -> Value,
    discard: @escaping @MainActor (Value) -> Void) {
    precondition(maximumRunning > 0 && maximumEntries >= maximumRunning && byteWatermark > 0)
    self.maximumRunning = maximumRunning; self.maximumEntries = maximumEntries
    self.byteWatermark = byteWatermark; self.prepare = prepare; self.discard = discard
  }
  public var hasCapacity: Bool {
    running.count < maximumRunning && running.count + ready.count < maximumEntries && bytes <= byteWatermark
  }
  /// Cheap status for the HUD; timing histograms are only sampled by telemetry.
  public var counts: (running: Int, ready: Int) { (running.count, ready.count) }
  /// A single oversize tile may progress only when this stage is empty. The
  /// watermark isn't an allocator bound; framework copies are not observable.
  public var availableBytes: Int { running.isEmpty && ready.isEmpty ? .max : max(0, byteWatermark - bytes) }

  @discardableResult public func admit(_ input: PreparedTerrainTile, bytes cost: Int) -> Bool {
    precondition(cost >= 0)
    guard hasCapacity, cost <= availableBytes,
      !running.values.contains(where: { $0.input.id == input.id }),
      !ready.contains(where: { $0.value.input.id == input.id }) else { return false }
    let token = UUID(), prepare = prepare, discard = discard
    bytes += cost; admitted += 1
    if cost > byteWatermark { oversized += 1 }
    let task = Task(priority: .utility) { @MainActor [weak self] in
      let result: Result<Value, Error>
      do {
        try Task.checkCancellation()
        result = .success(try await prepare(input))
      } catch { result = .failure(error) }
      guard let self else {
        if case let .success(value) = result { discard(value) }
        return
      }
      self.finish(token, result: result)
    }
    running[token] = .init(input: input, bytes: cost,
      started: ProcessInfo.processInfo.systemUptime, task: task, current: true)
    peakEntries = max(peakEntries, running.count + ready.count); peakBytes = max(peakBytes, bytes)
    return true
  }
  private func finish(_ token: UUID, result: Result<Value, Error>) {
    guard let job = running.removeValue(forKey: token) else { return }
    defer { onCapacityAvailable?() }
    let now = ProcessInfo.processInfo.systemUptime
    latency.record(seconds: now - job.started)
    guard job.current else {
      bytes -= job.bytes; discarded += 1
      if case let .success(value) = result { discard(value) }
      return
    }
    switch result { case .success: completed += 1; case .failure: failed += 1 }
    ready.append(.init(value: .init(input: job.input, result: result), bytes: job.bytes, finished: now))
  }
  /// Identity includes the world, revision and incarnation. Cancellation is not
  /// trusted to prevent a late framework result from becoming ready.
  public func retain(where accepts: (TerrainWorkID) -> Bool) {
    for (token, job) in running where job.current && !accepts(job.input.id) {
      running[token]?.current = false; job.task.cancel()
    }
    let previousReadyCount = ready.count
    ready.removeAll { entry in
      guard !accepts(entry.value.input.id) else { return false }
      bytes -= entry.bytes; discarded += 1
      if case let .success(value) = entry.value.result { discard(value) }
      return true
    }
    if ready.count < previousReadyCount { onCapacityAvailable?() }
  }
  public func takeReady(maximumBytes: Int = .max) -> Ready? {
    guard let index = ready.firstIndex(where: { $0.value.input.byteCount <= maximumBytes }) else { return nil }
    let entry = ready.remove(at: index); bytes -= entry.bytes
    wait.record(seconds: ProcessInfo.processInfo.systemUptime - entry.finished)
    onCapacityAvailable?()
    return entry.value
  }
  public var metrics: TerrainPublicationMetrics {
    .init(running: running.count, ready: ready.count, retainedBytes: bytes,
      peakEntries: peakEntries, peakBytes: peakBytes, maximumRunning: maximumRunning,
      maximumEntries: maximumEntries, byteWatermark: byteWatermark, admitted: admitted,
      completed: completed, failed: failed, discarded: discarded, oversized: oversized,
      preparationLatency: latency.snapshot, readyWait: wait.snapshot)
  }
}
