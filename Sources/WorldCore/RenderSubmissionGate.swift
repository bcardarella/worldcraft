import Foundation

/// Never waits for GPU capacity. Completion handlers release capacity directly,
/// even if the main actor is busy, and collect timing without a main-actor hop.
public final class RenderSubmissionGate: @unchecked Sendable {
  public struct Snapshot: Sendable, Encodable {
    public let inFlight: Int
    public let oldestInFlightMilliseconds: Double?
    public let submittedTotal, completedTotal, failedTotal, skippedTotal: Int
    public let gpu: DurationTiming.Snapshot
    public let completionLatency: DurationTiming.Snapshot
  }
  private let lock = NSLock()
  private let limit: Int
  private var next: UInt64 = 0
  private var outstanding: [UInt64: Double] = [:]
  private var submitted = 0, completed = 0, failed = 0, skipped = 0
  private var gpu = DurationTiming(), latency = DurationTiming()
  public init(limit: Int = 2) { precondition(limit > 0); self.limit = limit }
  public func acquire(at time: Double) -> UInt64? {
    lock.lock(); defer { lock.unlock() }
    guard outstanding.count < limit else { skipped += 1; return nil }
    next &+= 1; outstanding[next] = time; submitted += 1
    return next
  }
  public func complete(_ token: UInt64, at time: Double, gpuSeconds: Double? = nil, failed error: Bool = false) {
    lock.lock(); defer { lock.unlock() }
    guard let start = outstanding.removeValue(forKey: token) else { return }
    completed += 1
    if error { failed += 1 }
    if let gpuSeconds { gpu.record(seconds: gpuSeconds) }
    latency.record(seconds: max(0, time - start))
  }
  public func consume(at time: Double) -> Snapshot {
    lock.lock(); defer { lock.unlock() }
    defer { gpu.reset(); latency.reset() }
    return .init(inFlight: outstanding.count,
      oldestInFlightMilliseconds: outstanding.values.min().map { max(0, time - $0) * 1_000 },
      submittedTotal: submitted, completedTotal: completed, failedTotal: failed, skippedTotal: skipped,
      gpu: gpu.snapshot, completionLatency: latency.snapshot)
  }
}
