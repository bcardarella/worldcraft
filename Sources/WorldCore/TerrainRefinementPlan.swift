import Foundation

/// Additive refinement outside the guaranteed near region. The existing plan
/// remains the minimum quality and coverage contract, even far above ground.
/// Height residual/canopy support extent over nearest 3D bound distance is an
/// angular proxy, not pixels. The canopy support is deliberately conservative.
public struct TerrainRefinementPlan: Sendable {
  public let tiles, splits: Set<TerrainTile>
  public let profiledLeaves: Int
  public let maximumRemainingError: Float
  public let unresolvedLeaves: Int
  /// Carry already selected refinements across a base-plan change while the
  /// actor calculates new scores. Never retain tiles outside the new footprint.
  public static func retaining(_ splits: Set<TerrainTile>, in base: Set<TerrainTile>) -> Set<TerrainTile> {
    var result = Set<TerrainTile>()
    func visit(_ tile: TerrainTile) {
      guard !tile.fullDetail, tile.sampleStride > 1, splits.contains(tile) else {
        result.insert(tile); return
      }
      let half = tile.size / 2
      for dz in [0, half] { for dx in [0, half] {
        visit(.init(x: tile.x + dx, z: tile.z + dz, size: half))
      } }
    }
    for tile in base { visit(tile) }
    return result
  }
  public init(base: Set<TerrainTile>, profiles: [TerrainTile: TerrainSurfaceProfile],
    eye: SIMD3<Float>, previousSplits: Set<TerrainTile> = [], maximumExtraTiles: Int = 96,
    errorThreshold: Float = 0.01, retentionFraction: Float = 0.75) {
    precondition(errorThreshold > 0 && errorThreshold.isFinite)
    precondition(retentionFraction > 0 && retentionFraction <= 1)
    // Bound both traversal and the extra scene work, independent of input data.
    let splitLimit = min(128, max(0, maximumExtraTiles) / 3)
    var leaves = base, selected = Set<TerrainTile>(), queue: [Candidate] = []
    func candidate(_ tile: TerrainTile) -> Candidate? {
      guard !tile.fullDetail, tile.sampleStride > 1 else { return nil }
      let retained = previousSplits.contains(tile)
      let score: Float
      if let profile = profiles[tile], profile.isValid {
        score = profile.projectedError(for: tile, eye: eye)
      } else if retained {
        // An edited/evicted parent must not discard already selected detail
        // solely because its replacement measurement has not arrived yet.
        score = errorThreshold
      } else { return nil }
      let priority = score / (retained ? retentionFraction : 1)
      return priority >= errorThreshold ? .init(tile: tile, priority: priority) : nil
    }
    for tile in base { if let item = candidate(tile) { Self.push(item, into: &queue) } }
    while selected.count < splitLimit, let item = Self.pop(&queue) {
      let tile = item.tile
      // Size-eight smooth terrain transitions through size-four two-block
      // steps. Do not spend the final fidelity budget on that approximation:
      // reserve its complete size-two, one-block surface replacement together.
      let cost = tile.size == 8 ? 5 : 1
      guard selected.count + cost <= splitLimit, leaves.remove(tile) != nil else { continue }
      func split(_ parent: TerrainTile) {
        selected.insert(parent)
        let half = parent.size / 2
        for dz in [0, half] { for dx in [0, half] {
          let child = TerrainTile(x: parent.x + dx, z: parent.z + dz, size: half)
          if tile.size == 8 && child.size == 4 { split(child) }
          else {
            leaves.insert(child)
            if let next = candidate(child) { Self.push(next, into: &queue) }
          }
        } }
      }
      split(tile)
    }
    var measured = 0, unresolved = 0, maximum: Float = 0
    for tile in leaves where !tile.fullDetail {
      if let profile = profiles[tile], profile.isValid {
        measured += 1
        maximum = max(maximum, profile.projectedError(for: tile, eye: eye))
      } else { unresolved += 1 }
    }
    tiles = leaves; splits = selected; profiledLeaves = measured
    maximumRemainingError = maximum; unresolvedLeaves = unresolved
  }
  private struct Candidate {
    let tile: TerrainTile
    let priority: Float
    func precedes(_ other: Self) -> Bool {
      if priority != other.priority { return priority > other.priority }
      // Deterministic across Dictionary/Set iteration and worker completion.
      return (tile.size, tile.x, tile.z) < (other.tile.size, other.tile.x, other.tile.z)
    }
  }
  private static func push(_ item: Candidate, into heap: inout [Candidate]) {
    heap.append(item); var index = heap.count - 1
    while index > 0 {
      let parent = (index - 1) / 2
      guard heap[index].precedes(heap[parent]) else { break }
      heap.swapAt(index, parent); index = parent
    }
  }
  private static func pop(_ heap: inout [Candidate]) -> Candidate? {
    guard let first = heap.first else { return nil }
    let last = heap.removeLast()
    guard !heap.isEmpty else { return first }
    heap[0] = last; var index = 0
    while index * 2 + 1 < heap.count {
      var child = index * 2 + 1
      if child + 1 < heap.count, heap[child + 1].precedes(heap[child]) { child += 1 }
      guard heap[child].precedes(heap[index]) else { break }
      heap.swapAt(index, child); index = child
    }
    return first
  }
}

public struct TerrainRefinementObservation: Sendable {
  public let world: UUID
  public let revision, sequence: UInt64
  public let base, previousSplits: Set<TerrainTile>
  public let profiles: [TerrainTile: TerrainSurfaceProfile]
  public let eye: SIMD3<Float>
  public init(world: UUID, revision: UInt64, sequence: UInt64, base: Set<TerrainTile>,
    previousSplits: Set<TerrainTile>, profiles: [TerrainTile: TerrainSurfaceProfile], eye: SIMD3<Float>) {
    self.world = world; self.revision = revision; self.sequence = sequence; self.base = base
    self.previousSplits = previousSplits; self.profiles = profiles; self.eye = eye
  }
}

public struct TerrainRefinementMetrics: Sendable, Encodable {
  public var enabled = false
  public var profileCount = 0, profiledLeaves = 0, unresolvedLeaves = 0
  public var extraTiles = 0, splits = 0, coalesced = 0, mainThreadViolations = 0
  public var maximumProjectedErrorRatio: Float = 0
  public var workerCPU = DurationTiming().snapshot
  public var ageMilliseconds: Double = 0
  public init() {}
}

public struct TerrainRefinementResult: Sendable {
  public let input: TerrainRefinementObservation
  public let plan: TerrainRefinementPlan
  public let metrics: TerrainRefinementMetrics
  public let completedAt: Double
}

/// One running calculation and one latest immutable observation. No renderer,
/// AI work, synchronous waits or per-frame actor tasks run on this executor.
public final class TerrainRefinementService: @unchecked Sendable {
  private let lock = NSLock()
  private let worker = TerrainRefinementWorker()
  private var world: UUID?
  private var revision: UInt64 = 0, sequence: UInt64 = 0
  private var pending: TerrainRefinementObservation?
  private var scheduled = false, coalesced = 0
  private var result: TerrainRefinementResult?
  public init() {}
  public func expect(world: UUID, revision: UInt64) {
    lock.withLock {
      self.world = world; self.revision = revision
      pending = nil; result = nil; sequence = 0
    }
  }
  public func submit(_ input: TerrainRefinementObservation) {
    let wake = lock.withLock {
      guard input.world == world, input.revision == revision, input.sequence > sequence else { return false }
      sequence = input.sequence
      if pending != nil { coalesced += 1 }
      pending = input
      guard !scheduled else { return false }
      scheduled = true; return true
    }
    if wake { Task { await worker.process(self) } }
  }
  public var latest: TerrainRefinementResult? { lock.withLock { result } }
  public var metrics: TerrainRefinementMetrics {
    lock.withLock {
      var value = result?.metrics ?? .init(); value.enabled = true; value.coalesced = coalesced
      if let result { value.ageMilliseconds = max(0, ProcessInfo.processInfo.systemUptime - result.completedAt) * 1_000 }
      return value
    }
  }
  // Internal access also permits deterministic late-completion regression tests.
  func take() -> TerrainRefinementObservation? {
    lock.withLock {
      guard let input = pending else { scheduled = false; return nil }
      pending = nil; return input
    }
  }
  func publish(_ value: TerrainRefinementResult) {
    lock.withLock {
      guard value.input.world == world, value.input.revision == revision,
        value.input.sequence == sequence else { return }
      result = value
    }
  }
}

private actor TerrainRefinementWorker {
  private let executor = RefinementExecutor()
  nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
  private var timing = DurationTiming()
  private var world: UUID?
  func process(_ mailbox: TerrainRefinementService) {
    while let input = mailbox.take() {
      if world != input.world { timing.reset(); world = input.world }
      let began = ProcessInfo.processInfo.systemUptime
      let plan = TerrainRefinementPlan(base: input.base, profiles: input.profiles, eye: input.eye,
        previousSplits: input.previousSplits)
      timing.record(seconds: ProcessInfo.processInfo.systemUptime - began)
      var metrics = TerrainRefinementMetrics()
      metrics.enabled = true; metrics.profileCount = input.profiles.count
      metrics.profiledLeaves = plan.profiledLeaves; metrics.unresolvedLeaves = plan.unresolvedLeaves
      metrics.extraTiles = plan.tiles.count - input.base.count; metrics.splits = plan.splits.count
      metrics.maximumProjectedErrorRatio = plan.maximumRemainingError; metrics.workerCPU = timing.snapshot
      metrics.mainThreadViolations = Thread.isMainThread ? 1 : 0
      mailbox.publish(.init(input: input, plan: plan, metrics: metrics,
        completedAt: ProcessInfo.processInfo.systemUptime))
    }
  }
}
private final class RefinementExecutor: SerialExecutor {
  private let queue = DispatchQueue(label: "com.worldcraft.terrain-refinement", qos: .utility)
  func enqueue(_ job: consuming ExecutorJob) {
    let work = UnownedJob(job)
    queue.async { work.runSynchronously(on: self.asUnownedSerialExecutor()) }
  }
}
