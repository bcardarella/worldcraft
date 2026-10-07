import Foundation

/// Predicts travel from sampled final-detail demand to visible scene ownership.
/// This is not GPU/display latency. All state is a bounded value owned by the
/// renderer; no worker, actor hop or wait is added to player movement.
public struct TerrainTravelPrefetch: Sendable {
  public struct Metrics: Sendable, Encodable {
    public var enabled = true
    public var pendingTiles = 0, sampleCount = 0, completedTotal = 0, cancelledTotal = 0
    public var completionP95Milliseconds = 0.0, oldestPendingMilliseconds = 0.0
    public var predictionSeconds = 2.5
    public var requestedLeadChunks = 0.0, appliedLeadChunks = 0.0
    public var leadLimited = false
  }
  private struct Sample: Sendable { let time, seconds: Double }
  public let enabled: Bool
  private var world: UUID?
  private var pending: [TerrainTile: Double] = [:]
  private var samples: [Sample] = []
  private var lastSample: Double?
  private var previousOffset = SIMD2<Int>.zero
  public private(set) var metrics = Metrics()

  public init(enabled: Bool = true) { self.enabled = enabled; metrics.enabled = enabled }
  public mutating func reset() { self = .init(enabled: enabled) }

  /// Four samples per second, up to 128 completions from the last 30 seconds.
  /// Already-ready terrain contributes no zero-duration samples. Unfinished
  /// demand is included separately, so slow work cannot hide behind fast hits.
  public mutating func observe(world: UUID, target: Set<TerrainTile>, visible: Set<TerrainTile>, time: Double) {
    guard time.isFinite else { return }
    if self.world != world || (lastSample.map { time < $0 } ?? false) {
      reset(); self.world = world
    }
    guard lastSample.map({ time-$0 >= 0.25 }) ?? true else { return }
    let elapsed = min(1, max(0, time-(lastSample ?? time)))
    lastSample = time
    let detail = Set(target.filter(\.fullDetail))
    for tile in Array(pending.keys) where !detail.contains(tile) {
      pending.removeValue(forKey: tile); metrics.cancelledTotal += 1
    }
    // Stable order prevents Dictionary/Set traversal from choosing which
    // simultaneous completions survive the 128-sample limit.
    for tile in detail.sorted(by: { ($0.z,$0.x) < ($1.z,$1.x) }) {
      if visible.contains(tile) {
        if let began = pending.removeValue(forKey: tile) {
          samples.append(.init(time: time, seconds: max(0,time-began)))
          metrics.completedTotal += 1
        }
      } else if pending[tile] == nil { pending[tile] = time }
    }
    samples.removeAll { time-$0.time > 30 }
    if samples.count > 128 { samples.removeFirst(samples.count-128) }
    let durations = samples.map(\.seconds).sorted()
    let p95 = durations.isEmpty ? 0 : durations[min(durations.count-1,Int(ceil(Double(durations.count)*0.95))-1)]
    let oldest = pending.values.map { max(0,time-$0) }.max() ?? 0
    // Startup and fast turns still have a usable prediction before enough
    // completed observations exist. A bounded margin accounts for sampling.
    let wanted = enabled ? min(6,max(2.5,max(p95,oldest)+0.5)) : 2.5
    // Grow promptly; decay slowly so a temporary cache hit cannot repeatedly
    // discard and re-request the same ahead-of-travel detail.
    metrics.predictionSeconds = max(wanted,metrics.predictionSeconds-elapsed*0.25)
    metrics.pendingTiles = pending.count; metrics.sampleCount = samples.count
    metrics.completionP95Milliseconds = p95*1_000
    metrics.oldestPendingMilliseconds = oldest*1_000
  }

  public mutating func lookAhead(from center: ChunkCoordinate, velocity: SIMD3<Float>,
    detailRadius: Int) -> ChunkCoordinate {
    guard velocity.x.isFinite, velocity.z.isFinite else {
      previousOffset = .zero; metrics.requestedLeadChunks = 0
      metrics.appliedLeadChunks = 0; metrics.leadLimited = false
      return center
    }
    if !enabled {
      let result = TerrainStreamingPlan.lookAhead(from: center,velocity: velocity)
      let x = Double(result.x-center.x), z = Double(result.z-center.z)
      metrics.appliedLeadChunks = (x*x+z*z).squareRoot()
      metrics.requestedLeadChunks = (Double(velocity.x)*Double(velocity.x)+Double(velocity.z)*Double(velocity.z)).squareRoot()*2.5/16
      metrics.leadLimited = metrics.requestedLeadChunks > 6
      return result
    }
    let x = Double(velocity.x)*metrics.predictionSeconds/16
    let z = Double(velocity.z)*metrics.predictionSeconds/16
    let length = (x*x+z*z).squareRoot()
    let limit = Double(min(12,max(6,detailRadius)))
    let scale = length > limit ? limit/length : 1
    let lead = SIMD2<Double>(x*scale,z*scale)
    var offset = SIMD2<Int>(Int((lead.x/2).rounded())*2,Int((lead.y/2).rounded())*2)
    func squared(_ value: SIMD2<Int>) -> Int { value.x*value.x+value.y*value.y }
    // Component rounding must not exceed the radial admission limit.
    while Double(squared(offset)) > limit*limit {
      if abs(offset.x) >= abs(offset.y) { offset.x -= offset.x > 0 ? 2 : -2 }
      else { offset.y -= offset.y > 0 ? 2 : -2 }
    }
    let old = SIMD2<Double>(Double(previousOffset.x),Double(previousOffset.y))
    let proposed = SIMD2<Double>(Double(offset.x),Double(offset.y))
    let oldError = lead-old, newError = lead-proposed
    let sameDirection = lead.x*old.x+lead.y*old.y > 0
    if length > 0.5, sameDirection, Double(squared(previousOffset)) <= limit*limit,
      (oldError.x*oldError.x+oldError.y*oldError.y).squareRoot()
        <= (newError.x*newError.x+newError.y*newError.y).squareRoot()+0.5 {
      offset = previousOffset
    }
    previousOffset = offset
    metrics.requestedLeadChunks = length
    metrics.appliedLeadChunks = Double(squared(offset)).squareRoot()
    metrics.leadLimited = length > limit
    return .init(center.x+offset.x,center.z+offset.y)
  }
}
