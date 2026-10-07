import Foundation

/// Fixed storage; recording allocates nothing. Sort only when the HUD requests
/// a snapshot. Update cadence is deliberately distinguished from presented FPS.
public struct FrameTiming: Sendable {
  public struct Snapshot: Sendable, Encodable {
    public let count: Int
    public let seconds: Double
    public let updateHz: Double
    public let intervalP95Milliseconds: Double
    public let intervalP99Milliseconds: Double
    public let intervalMaxMilliseconds: Double
    public let cpuMeanMilliseconds: Double
    public let cpuP95Milliseconds: Double
    public let cpuP99Milliseconds: Double
    public let cpuMaxMilliseconds: Double
    public let intervalsOver50Milliseconds: Int
    public let over60BudgetPercent: Double
    public let over90BudgetPercent: Double
  }
  private var intervals: [Double]
  private var costs: [Double]
  private var cursor = 0
  public private(set) var count = 0
  public init(capacity: Int = 360) {
    precondition(capacity > 0)
    intervals = .init(repeating: 0, count: capacity)
    costs = .init(repeating: 0, count: capacity)
  }
  public mutating func record(interval: Double, cpuTime: Double) {
    guard interval.isFinite && interval > 0 && cpuTime.isFinite && cpuTime >= 0 else { return }
    intervals[cursor] = interval
    costs[cursor] = cpuTime
    cursor = (cursor + 1) % intervals.count
    count = min(intervals.count, count + 1)
  }
  public mutating func reset() {
    cursor = 0
    count = 0
  }
  public var snapshot: Snapshot {
    guard count > 0 else {
      return .init(
        count: 0, seconds: 0, updateHz: 0, intervalP95Milliseconds: 0,
        intervalP99Milliseconds: 0, intervalMaxMilliseconds: 0, cpuMeanMilliseconds: 0,
        cpuP95Milliseconds: 0, cpuP99Milliseconds: 0, cpuMaxMilliseconds: 0,
        intervalsOver50Milliseconds: 0, over60BudgetPercent: 0, over90BudgetPercent: 0)
    }
    let frames = Array(intervals.prefix(count)).sorted()
    let cpu = Array(costs.prefix(count)).sorted()
    let percentile = max(0, Int(ceil(Double(count) * 0.95)) - 1)
    let p99 = max(0, Int(ceil(Double(count) * 0.99)) - 1)
    let seconds = frames.reduce(0, +)
    return .init(
      count: count, seconds: seconds, updateHz: Double(count) / seconds,
      intervalP95Milliseconds: frames[percentile] * 1_000,
      intervalP99Milliseconds: frames[p99] * 1_000,
      intervalMaxMilliseconds: frames[count - 1] * 1_000,
      cpuMeanMilliseconds: cpu.reduce(0, +) * 1_000 / Double(count),
      cpuP95Milliseconds: cpu[percentile] * 1_000,
      cpuP99Milliseconds: cpu[p99] * 1_000,
      cpuMaxMilliseconds: cpu[count - 1] * 1_000,
      intervalsOver50Milliseconds: frames.filter { $0 > 0.050 }.count,
      over60BudgetPercent: Double(frames.filter { $0 > 1.0 / 60 + 0.0001 }.count) * 100
        / Double(count),
      over90BudgetPercent: Double(frames.filter { $0 > 1.0 / 90 + 0.0001 }.count) * 100
        / Double(count))
  }
}

/// Bounded duration samples for asynchronous GPU command completions. An empty
/// window has no durations, rather than reporting a misleading zero GPU cost.
public struct DurationTiming: Sendable {
  public struct Snapshot: Sendable, Encodable {
    public let count: Int
    public let meanMilliseconds: Double?
    public let p95Milliseconds: Double?
    public let maxMilliseconds: Double?
  }
  private var samples: [Double]
  private var cursor = 0
  public private(set) var count = 0
  public init(capacity: Int = 256) {
    precondition(capacity > 0)
    samples = .init(repeating: 0, count: capacity)
  }
  public mutating func record(seconds: Double) {
    guard seconds.isFinite && seconds >= 0 else { return }
    samples[cursor] = seconds
    cursor = (cursor + 1) % samples.count
    count = min(samples.count, count + 1)
  }
  public mutating func reset() {
    cursor = 0
    count = 0
  }
  public var snapshot: Snapshot {
    guard count > 0 else {
      return .init(count: 0, meanMilliseconds: nil, p95Milliseconds: nil, maxMilliseconds: nil)
    }
    let values = Array(samples.prefix(count)).sorted()
    let p95 = max(0, Int(ceil(Double(count) * 0.95)) - 1)
    return .init(
      count: count, meanMilliseconds: values.reduce(0, +) * 1_000 / Double(count),
      p95Milliseconds: values[p95] * 1_000, maxMilliseconds: values[count - 1] * 1_000)
  }
}
