import Foundation

public struct TerrainCoverageObservation: Sendable {
  public let world: UUID
  public let center: ChunkCoordinate
  public let radius, detailRadius: Int
  public let target, visible: Set<TerrainTile>
  public let direction: SIMD3<Float>
  public let time: Double
  public init(world: UUID, center: ChunkCoordinate, radius: Int, detailRadius: Int,
    target: Set<TerrainTile>, visible: Set<TerrainTile>, direction: SIMD3<Float>, time: Double) {
    self.world = world; self.center = center; self.radius = DrawDistance.clamp(radius)
    self.detailRadius = min(self.radius, max(1, detailRadius)); self.target = target; self.visible = visible
    self.direction = direction; self.time = time
  }
}

/// Sampled at most 4 Hz, off the scene executor. This is horizontal scene
/// ownership, not headset FOV, occlusion visibility or confirmed presentation.
public struct TerrainCoverageDiagnosticsMetrics: Sendable, Encodable {
  public struct Band: Sendable, Encodable {
    public let minimumMetres, maximumMetres, requestedChunks, coveredChunks: Int
    public var coveredPercent: Double { 100 * Double(coveredChunks) / Double(max(1, requestedChunks)) }
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(minimumMetres, forKey: .minimumMetres)
      try container.encode(maximumMetres, forKey: .maximumMetres)
      try container.encode(requestedChunks, forKey: .requestedChunks)
      try container.encode(coveredChunks, forKey: .coveredChunks)
      try container.encode(coveredPercent, forKey: .coveredPercent)
    }
    private enum CodingKeys: String, CodingKey { case minimumMetres, maximumMetres, requestedChunks, coveredChunks, coveredPercent }
  }
  public var bands: [Band] = []
  public var uncoveredChunks = 0
  public var forwardSectorPercent: Double?
  public var pendingCoverage = 0, pendingDetail = 0
  public var coverageLosses = 0, detailLosses = 0
  public var oldestCoverageMilliseconds: Double = 0, oldestDetailMilliseconds: Double = 0
  public var first95PercentMilliseconds: Double?
  public var wantedToCoverage = DurationTiming().snapshot
  public var wantedToDetail = DurationTiming().snapshot
  public var coverageToDetail = DurationTiming().snapshot
  public var sampledAt: Double = 0
  public var sampleAgeMilliseconds: Double = 0
  public var coalescedSamples = 0
  public var mainThreadViolations = 0
  public var workerCPU = DurationTiming().snapshot
}

struct TerrainCoverageHistory {
  private struct Demand { let wantedAt: Double; var coveredAt: Double?; var finished = false }
  private var world: UUID?
  private var startedAt: Double = 0
  private var demands: [TerrainTile: Demand] = [:]
  private var coverage = DurationTiming(), detail = DurationTiming(), refinement = DurationTiming()
  private var first95: Double?
  private var coverageLosses = 0, detailLosses = 0

  mutating func observe(_ input: TerrainCoverageObservation) -> TerrainCoverageDiagnosticsMetrics {
    if world != input.world { self = .init(); world = input.world; startedAt = input.time }
    demands = demands.filter { input.target.contains($0.key) }
    for tile in input.target where demands[tile] == nil { demands[tile] = .init(wantedAt: input.time) }
    let index = TerrainOverlapIndex(input.visible)
    func area(_ tile: TerrainTile, _ other: TerrainTile) -> Int {
      max(0, min(tile.x + tile.size, other.x + other.size) - max(tile.x, other.x))
        * max(0, min(tile.z + tile.size, other.z + other.size) - max(tile.z, other.z))
    }
    var result = Self.spatial(input)
    for (tile, var demand) in demands {
      let overlaps = index.overlapping(tile)
      let covered = overlaps.reduce(0) { $0 + area(tile, $1) } >= tile.size * tile.size
      let detailedArea = overlaps.filter { $0.size <= tile.size && (!tile.fullDetail || $0.fullDetail) }
        .reduce(0) { $0 + area(tile, $1) }
      let detailed = detailedArea >= tile.size * tile.size
      if (demand.coveredAt != nil && !covered) || (demand.finished && !detailed) {
        if demand.coveredAt != nil && !covered { coverageLosses += 1 }
        if demand.finished && !detailed { detailLosses += 1 }
        // A coverage regression starts another pending episode rather than
        // reporting historical readiness while a currently wanted region is blank.
        demand = .init(wantedAt: input.time, coveredAt: covered ? input.time : nil)
      }
      if demand.coveredAt == nil, covered {
        demand.coveredAt = input.time; coverage.record(seconds: input.time - demand.wantedAt)
      }
      if detailed && !demand.finished {
        demand.finished = true; detail.record(seconds: input.time - demand.wantedAt)
        if let began = demand.coveredAt { refinement.record(seconds: input.time - began) }
      }
      demands[tile] = demand
      if demand.coveredAt == nil {
        result.pendingCoverage += 1
        result.oldestCoverageMilliseconds = max(result.oldestCoverageMilliseconds, (input.time - demand.wantedAt) * 1_000)
      }
      if !demand.finished {
        result.pendingDetail += 1
        result.oldestDetailMilliseconds = max(result.oldestDetailMilliseconds, (input.time - demand.wantedAt) * 1_000)
      }
    }
    let requested = result.bands.reduce(0) { $0 + $1.requestedChunks }
    if first95 == nil, requested > 0, Double(result.uncoveredChunks) <= Double(requested) * 0.05 {
      first95 = (input.time - startedAt) * 1_000
    }
    result.first95PercentMilliseconds = first95
    result.coverageLosses = coverageLosses; result.detailLosses = detailLosses
    result.wantedToCoverage = coverage.snapshot; result.wantedToDetail = detail.snapshot
    result.coverageToDetail = refinement.snapshot; result.sampledAt = input.time
    return result
  }

  private static func spatial(_ input: TerrainCoverageObservation) -> TerrainCoverageDiagnosticsMetrics {
    let radius = input.radius, side = radius * 2 + 1
    let cuts = Array(Set([input.detailRadius, max(input.detailRadius, radius / 2), radius])).sorted()
    var requested = [Int](repeating: 0, count: cuts.count), covered = requested
    var cells = [UInt8](repeating: 0, count: side * side)
    for tile in input.visible {
      let x0 = max(-radius, tile.x - input.center.x), x1 = min(radius, tile.x + tile.size - 1 - input.center.x)
      let z0 = max(-radius, tile.z - input.center.z), z1 = min(radius, tile.z + tile.size - 1 - input.center.z)
      guard x0 <= x1, z0 <= z1 else { continue }
      for z in z0...z1 { for x in x0...x1 { cells[(z + radius) * side + x + radius] = 1 } }
    }
    let forward = SIMD2(input.direction.x, input.direction.z)
    let length = (forward.x * forward.x + forward.y * forward.y).squareRoot()
    let fullLength = (length * length + input.direction.y * input.direction.y).squareRoot()
    // Looking nearly straight up/down has no meaningful horizontal sector.
    let hasHeading = length.isFinite && fullLength.isFinite && length > max(0.001, fullLength * 0.15)
    var sectorTotal = 0, sectorCovered = 0
    for z in -radius...radius {
      let reach = Int(Double(radius * radius - z * z).squareRoot())
      for x in -reach...reach {
        let distance = x * x + z * z
        let band = cuts.firstIndex { distance <= $0 * $0 }!
        let present = Int(cells[(z + radius) * side + x + radius])
        requested[band] += 1; covered[band] += present
        if hasHeading, Float(x) * forward.x + Float(z) * forward.y >= 0.5 * length * Float(distance).squareRoot() {
          sectorTotal += 1; sectorCovered += present
        }
      }
    }
    var result = TerrainCoverageDiagnosticsMetrics()
    result.bands = cuts.indices.map { .init(minimumMetres: ($0 == 0 ? 0 : cuts[$0 - 1]) * 8,
      maximumMetres: cuts[$0] * 8, requestedChunks: requested[$0], coveredChunks: covered[$0]) }
    result.uncoveredChunks = requested.reduce(0, +) - covered.reduce(0, +)
    result.forwardSectorPercent = hasHeading ? 100 * Double(sectorCovered) / Double(max(1, sectorTotal)) : nil
    return result
  }
}

/// Only the latest observation can wait behind a running calculation. No actor
/// task is created per frame, and a planet change rejects late old-world metrics.
public final class TerrainCoverageDiagnostics: @unchecked Sendable {
  private let lock = NSLock()
  private let worker = TerrainCoverageDiagnosticsWorker()
  private var pending: TerrainCoverageObservation?
  private var scheduled = false, coalesced = 0
  private var world: UUID?
  private var value = TerrainCoverageDiagnosticsMetrics()
  public init() {}
  public func submit(_ input: TerrainCoverageObservation) {
    let wake = lock.withLock {
      if world != input.world { value = .init(); world = input.world; coalesced = 0 }
      if pending != nil { coalesced += 1 }
      pending = input
      guard !scheduled else { return false }
      scheduled = true; return true
    }
    if wake { Task { await worker.process(self) } }
  }
  public var snapshot: TerrainCoverageDiagnosticsMetrics {
    lock.withLock {
      var result = value
      result.coalescedSamples = coalesced
      result.sampleAgeMilliseconds = value.sampledAt > 0 ? max(0, ProcessInfo.processInfo.systemUptime - value.sampledAt) * 1_000 : 0
      return result
    }
  }
  fileprivate func take() -> TerrainCoverageObservation? {
    lock.withLock {
      guard let input = pending else { scheduled = false; return nil }
      pending = nil; return input
    }
  }
  fileprivate func publish(_ result: TerrainCoverageDiagnosticsMetrics, world: UUID) {
    lock.withLock { if self.world == world { value = result } }
  }
}

private actor TerrainCoverageDiagnosticsWorker {
  private let executor = CoverageExecutor()
  nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
  private var history = TerrainCoverageHistory(), timing = DurationTiming()
  func process(_ mailbox: TerrainCoverageDiagnostics) {
    while let input = mailbox.take() {
      let began = ProcessInfo.processInfo.systemUptime
      var value = history.observe(input)
      timing.record(seconds: ProcessInfo.processInfo.systemUptime - began)
      value.workerCPU = timing.snapshot
      value.mainThreadViolations = Thread.isMainThread ? 1 : 0
      mailbox.publish(value, world: input.world)
    }
  }
}
private final class CoverageExecutor: SerialExecutor {
  private let queue = DispatchQueue(label: "com.worldcraft.terrain-metrics", qos: .utility)
  func enqueue(_ job: consuming ExecutorJob) {
    let work = UnownedJob(job)
    queue.async { work.runSynchronously(on: self.asUnownedSerialExecutor()) }
  }
}
