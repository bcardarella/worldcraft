import Foundation

/// Immutable inputs for one boundary-inspection wave. The caller separately
/// validates voxel/edit/view/fluid lifetimes before using its diagnostics.
public struct TerrainFeatureInspectionRequest: Sendable {
  public let world: UUID
  public let revision, sequence: UInt64
  public let terrain: TerrainGenerator
  public let ground: TerrainSurfaceSources.Snapshot
  public let domain: [ChunkCoordinate: VoxelColumnMask]
  public let sources: [ChunkCoordinate: TerrainSurfaceSeam.Source]
  public let fluids: TerrainSurfaceSeam.FluidOwnership
  public let byteCount: Int
  public init(world: UUID, revision: UInt64, sequence: UInt64, terrain: TerrainGenerator,
    ground: TerrainSurfaceSources.Snapshot, domain: [ChunkCoordinate: VoxelColumnMask],
    sources: [ChunkCoordinate: TerrainSurfaceSeam.Source], fluids: TerrainSurfaceSeam.FluidOwnership) {
    self.world = world; self.revision = revision; self.sequence = sequence; self.terrain = terrain
    self.ground = ground; self.domain = domain; self.sources = sources; self.fluids = fluids
    byteCount = ground.byteCount + ground.visible.count * MemoryLayout<TerrainTile>.stride
      + sources.count * (18 * 18 * (ChunkData.height - ChunkData.minimumY) + 96)
      + domain.count * (MemoryLayout<VoxelColumnMask>.stride + MemoryLayout<ChunkCoordinate>.stride)
  }
}

/// Metadata only. Ready means every requested edge was inspected, never that
/// a cave cap, fluid boundary or feature mesh is safe to publish.
public struct TerrainFeatureInspectionResult: Sendable {
  public enum Status: String, Sendable { case ready, cancelled, invalidInput, inputLimit, outputLimit, missingChunk, missingGround }
  public let world: UUID
  public let revision, sequence: UInt64
  public let status: Status
  public let inspections: [ChunkCoordinate: TerrainSurfaceSeam.Inspection]
  public let exterior: [BlockPosition: Float]
  public let groundLease: TerrainSurfaceSources.Lease
  public let byteCount: Int
}

public struct TerrainFeatureInspectionLimits: Sendable {
  public let inputBytes, outputBytes, chunks, columns: Int
  public init(inputBytes: Int = 64 * 1_024 * 1_024, outputBytes: Int = 16 * 1_024 * 1_024,
    chunks: Int = 512, columns: Int = 32_768) {
    precondition(inputBytes >= 0 && outputBytes >= 0 && chunks >= 0 && columns >= 0)
    self.inputBytes = inputBytes; self.outputBytes = outputBytes; self.chunks = chunks; self.columns = columns
  }
  func accepts(_ request: TerrainFeatureInspectionRequest) -> Bool {
    request.byteCount <= inputBytes && request.sources.count <= chunks && request.domain.count <= chunks
      && request.domain.values.reduce(0, { $0 + $1.count }) <= columns
  }
}

/// Pure preparation, also usable synchronously by offline tools. The service
/// below provides nonblocking submission for the future feature publisher.
public enum TerrainFeatureInspection {
  public static func prepare(_ input: TerrainFeatureInspectionRequest,
    limits: TerrainFeatureInspectionLimits = .init(), cache: inout TerrainSurfaceSeam.InspectionCache,
    isCancelled: () -> Bool = { Task.isCancelled }) -> TerrainFeatureInspectionResult {
    var inspections: [ChunkCoordinate: TerrainSurfaceSeam.Inspection] = [:]
    var exterior: [BlockPosition: Float] = [:], reads = Set<ChunkCoordinate>()
    var bytes = 0
    func result(_ status: TerrainFeatureInspectionResult.Status) -> TerrainFeatureInspectionResult {
      let ready = status == .ready
      let lease = input.ground.dependencies(for: ready ? reads : [])
      return .init(world: input.world, revision: input.revision, sequence: input.sequence, status: status,
        inspections: ready ? inspections : [:], exterior: ready ? exterior : [:], groundLease: lease,
        byteCount: (ready ? bytes : 0) + lease.byteCount)
    }
    guard limits.accepts(input) else { return result(.inputLimit) }
    guard input.ground.world == nil || input.ground.world == input.world else { return result(.invalidInput) }
    if isCancelled() { return result(.cancelled) }
    let near = Set(input.ground.visible.filter(\.fullDetail).map(\.coordinate))
    guard input.domain.keys.allSatisfy({ !near.contains($0) }) else { return result(.invalidInput) }
    reads.formUnion(input.domain.keys)
    guard input.domain.keys.allSatisfy({ input.ground.source(containing: $0) != nil }) else { return result(.missingGround) }
    func owns(_ x: Int, _ z: Int) -> Bool {
      let key = ChunkCoordinate(floorDivide(x, by: 16), floorDivide(z, by: 16))
      // Ownership reads that suppress an edge matter too: a near/coarse LOD
      // exchange may change the boundary without changing any queried segment.
      reads.insert(key)
      return near.contains(key) || (input.domain[key]?.contains(x: x-key.x*16, z: z-key.z*16) ?? false)
    }
    var samplers: [TerrainTile: TerrainSurface.Sampler] = [:]
    for key in input.domain.keys.sorted(by: { ($0.z,$0.x) < ($1.z,$1.x) }) {
      if isCancelled() { return result(.cancelled) }
      guard let source = input.sources[key] else { return result(.missingChunk) }
      guard source.chunk.coordinate == key else { return result(.invalidInput) }
      let boundary = VoxelColumnBoundary(columns: input.domain[key]!) { owns(key.x*16+$0, key.z*16+$1) }
      var profiles: [VoxelColumnBoundary.Edge: [TerrainSurfaceSeam.Segment]] = [:]
      for edge in boundary.edges {
        if isCancelled() { return result(.cancelled) }
        let neighbor = edge.neighbor, x = key.x*16+neighbor.x, z = key.z*16+neighbor.z
        let coordinate = ChunkCoordinate(floorDivide(x, by: 16), floorDivide(z, by: 16))
        reads.insert(coordinate)
        guard let outside = input.ground.source(containing: coordinate) else { return result(.missingGround) }
        let tile = outside.id.tile
        let sampler: TerrainSurface.Sampler
        if let held = samplers[tile] { sampler = held }
        else { sampler = .init(tile: tile, terrain: input.terrain); samplers[tile] = sampler }
        guard let segments = outside.grid.segments(atLocalX: x-tile.x*16, z: z-tile.z*16,
          face: edge.face ^ 1, referenceHeight: sampler.column(x,z).height) else { return result(.missingGround) }
        profiles[edge] = segments
        let position = BlockPosition(key.x*16+edge.x, 0, key.z*16+edge.z)
        if exterior[position] == nil { bytes += MemoryLayout<BlockPosition>.stride + MemoryLayout<Float>.stride }
        exterior[position] = min(exterior[position] ?? .infinity, segments.map { min($0.firstHeight,$0.lastHeight) }.min()!)
      }
      guard let inspection = cache.inspect(source, boundary: boundary, fluids: input.fluids, surface: { profiles[$0]! }),
        !isCancelled() else { return result(.cancelled) }
      bytes += (inspection.cavityCells.count + inspection.unsupportedCells.count + inspection.fluidBoundaryCells.count)
        * MemoryLayout<BlockPosition>.stride + inspection.cavityFaces.count * MemoryLayout<TerrainSurfaceSeam.CavityFace>.stride
        + MemoryLayout<ChunkCoordinate>.stride
      guard bytes <= limits.outputBytes else { return result(.outputLimit) }
      inspections[key] = inspection
    }
    if isCancelled() { return result(.cancelled) }
    guard bytes + input.ground.dependencies(for: reads).byteCount <= limits.outputBytes else { return result(.outputLimit) }
    return result(.ready)
  }
}

/// One running wave, one replaceable pending wave, one ready result and a 4 MiB
/// metadata cache. Inputs/results are charged as logical arrays, excluding
/// allocator/dictionary overhead and copies still owned by the caller.
public final class TerrainFeatureInspectionService: @unchecked Sendable {
  public struct Metrics: Sendable, Encodable {
    public var running = false, pending = false
    public var runningBytes = 0, pendingBytes = 0, readyBytes = 0
    public var submitted = 0, coalesced = 0, refused = 0, completed = 0, discarded = 0
    public var cacheEntries = 0, cacheBytes = 0, cacheHits = 0, cacheMisses = 0
    public var mainThreadViolations = 0
    public var workerCPU = DurationTiming().snapshot
  }
  public enum Admission: Sendable { case accepted, stale, inputLimit }
  typealias Builder = @Sendable (TerrainFeatureInspectionRequest, TerrainFeatureInspectionLimits,
    inout TerrainSurfaceSeam.InspectionCache, @Sendable () -> Bool) -> TerrainFeatureInspectionResult
  struct Envelope: Sendable { let input: TerrainFeatureInspectionRequest; let lifetime: UUID }
  private let lock = NSLock()
  private let worker: TerrainFeatureInspectionWorker
  private let limits: TerrainFeatureInspectionLimits
  private var world: UUID?, revision: UInt64 = 0, sequence: UInt64 = 0, lifetime = UUID()
  private var pending: Envelope?, value: TerrainFeatureInspectionResult?
  private var scheduled = false
  private var statistics = Metrics(), timing = DurationTiming()
  public convenience init(limits: TerrainFeatureInspectionLimits = .init()) {
    self.init(limits: limits, builder: { input, limits, cache, cancelled in
      TerrainFeatureInspection.prepare(input, limits: limits, cache: &cache, isCancelled: cancelled)
    })
  }
  init(limits: TerrainFeatureInspectionLimits, builder: @escaping Builder) {
    self.limits = limits; worker = .init(limits: limits, builder: builder)
  }
  public func expect(world: UUID, revision: UInt64) {
    lock.withLock {
      self.world = world; self.revision = revision; sequence = 0; lifetime = UUID()
      pending = nil; value = nil; statistics.pending = false; statistics.pendingBytes = 0; statistics.readyBytes = 0
    }
  }
  @discardableResult public func submit(_ input: TerrainFeatureInspectionRequest) -> Admission {
    let admitted = limits.accepts(input)
    let outcome: (Admission, Bool) = lock.withLock {
      guard input.world == world, input.revision == revision, input.sequence > sequence else { return (.stale, false) }
      sequence = input.sequence; value = nil; statistics.readyBytes = 0
      if pending != nil { statistics.coalesced += 1 }
      pending = nil; statistics.pending = false; statistics.pendingBytes = 0
      // Even refused newer demand invalidates obsolete running/ready work.
      guard admitted else { statistics.refused += 1; return (.inputLimit, false) }
      pending = .init(input: input, lifetime: lifetime); statistics.submitted += 1
      statistics.pending = true; statistics.pendingBytes = input.byteCount
      guard !scheduled else { return (.accepted, false) }
      scheduled = true; return (.accepted, true)
    }
    if outcome.1 { Task { await worker.process(self) } }
    return outcome.0
  }
  public var latest: TerrainFeatureInspectionResult? { lock.withLock { value } }
  public var metrics: Metrics { lock.withLock { statistics } }
  fileprivate func take() -> Envelope? {
    lock.withLock {
      guard let next = pending else { scheduled = false; return nil }
      pending = nil; statistics.pending = false; statistics.pendingBytes = 0
      statistics.running = true; statistics.runningBytes = next.input.byteCount
      return next
    }
  }
  fileprivate func isCurrent(_ job: Envelope) -> Bool {
    lock.withLock { job.lifetime == lifetime && job.input.sequence == sequence }
  }
  fileprivate func finish(_ result: TerrainFeatureInspectionResult, job: Envelope, seconds: Double,
    cache: TerrainSurfaceSeam.InspectionCache.Metrics, onMainThread: Bool) {
    lock.withLock {
      statistics.running = false; statistics.runningBytes = 0
      timing.record(seconds: seconds); statistics.workerCPU = timing.snapshot
      if onMainThread { statistics.mainThreadViolations += 1 }
      statistics.cacheEntries = cache.entries; statistics.cacheBytes = cache.bytes
      statistics.cacheHits = cache.hits; statistics.cacheMisses = cache.misses
      guard job.lifetime == lifetime, job.input.sequence == sequence, result.status != .cancelled,
        result.world == job.input.world, result.revision == job.input.revision, result.sequence == job.input.sequence,
        result.byteCount <= limits.outputBytes else {
        statistics.discarded += 1; return
      }
      value = result; statistics.readyBytes = result.byteCount; statistics.completed += 1
    }
  }
}

private actor TerrainFeatureInspectionWorker {
  private let executor = FeatureInspectionExecutor()
  nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
  private let limits: TerrainFeatureInspectionLimits
  private let builder: TerrainFeatureInspectionService.Builder
  private var cache = TerrainSurfaceSeam.InspectionCache()
  private var lifetime: UUID?
  init(limits: TerrainFeatureInspectionLimits, builder: @escaping TerrainFeatureInspectionService.Builder) {
    self.limits = limits; self.builder = builder
  }
  func process(_ mailbox: TerrainFeatureInspectionService) {
    while let job = mailbox.take() {
      if lifetime != job.lifetime { cache = .init(); lifetime = job.lifetime }
      let began = ProcessInfo.processInfo.systemUptime
      let result = builder(job.input, limits, &cache) { !mailbox.isCurrent(job) || Task.isCancelled }
      mailbox.finish(result, job: job, seconds: ProcessInfo.processInfo.systemUptime-began,
        cache: cache.metrics, onMainThread: Thread.isMainThread)
    }
  }
}
private final class FeatureInspectionExecutor: SerialExecutor {
  private let queue = DispatchQueue(label: "com.worldcraft.feature-inspection", qos: .utility)
  func enqueue(_ job: consuming ExecutorJob) {
    let work = UnownedJob(job)
    queue.async { work.runSynchronously(on: self.asUnownedSerialExecutor()) }
  }
}
