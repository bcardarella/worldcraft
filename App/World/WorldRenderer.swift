import Metal
import QuartzCore
import RealityKit
import UIKit
import WorldCore

@MainActor
final class WorldRenderer {
  let root = Entity()
  let atmosphere = SkyRenderer()
  var sky: Entity { atmosphere.root }
  let ocean = WaterRenderer()
  let wind = WindRenderer()
  let wildlife = WildlifeRenderer()
  let dinosaurs = DinosaurRenderer()
  let life = LifeCoordinator()
  lazy var settlementLife = SettlementLife(presentation: life.presentation)
  var deliberation: DeliberationPresentation { life.deliberation }
  var fauna: FaunaLife { life.fauna }
  let precipitation = PrecipitationRenderer()
  let fire = FireRenderer()
  let lamps = LampRenderer()
  let doors = DoorRenderer()
  let vehicles = VehicleRenderer()
  let boats = BoatRenderer()
  let sports = SportsRenderer()
  var mount: MountedRide?
  var hayHayIDs: [UInt64] = []
  var hiddenCastleHayHay: UInt64?
  let selection = Entity()
  let pickups = ItemDropRenderer()
  private let fractures = Entity()
  private var fractureModels: [Int: Entity] = [:]
  private var fractureStage = -1
  private var plants: [ChunkCoordinate: [PlantInstance]] = [:]
  private var plantChanges: [ChunkCoordinate: [BlockPosition: PlantEdit]] = [:]
  var entityObstacle: ((BlockPosition) -> Bool)?
  private var previousGiantPosition:SIMD3<Float>?
  var entityObstacleSnapshot: (() -> RocketPort?)?
  private(set) var worldRevision: UInt64 = 0
  func actorBlock(at p: BlockPosition) -> Block { entityObstacle?(p) == true ? .basalt : doors.block(p) ?? block(at: p) }
  private(set) var chunks: [ChunkCoordinate: ChunkData] = [:]
  // Voxel collision data can arrive before meshing and GPU upload. These entries
  // belong to bounded streaming jobs/pending tiles and retire at mesh install.
  private var collisionChunks: [ChunkCoordinate: ChunkData] = [:]
  private var playerCollision = PlayerTerrainCollision()
  private var entryReadiness = TerrainEntryReadiness()
  var preparedCollisionChunkCount: Int { collisionChunks.count }
  var collisionCachedBlockCount: Int { playerCollision.count }
  var collisionProceduralSamples: Int { playerCollision.proceduralSamples }
  var collisionCacheHits: Int { playerCollision.cacheHits }
  private var entities: [TerrainTile: Entity] = [:]
  // Separating terrain ownership lets a planet switch detach one subtree while
  // the retirement service releases its children within a measured budget.
  private var terrainRoot = Entity()
  private let terrainResources = TerrainRenderResources()
  let asynchronousTerrainPublication = !ProcessInfo.processInfo.arguments.contains("--synchronous-terrain-publication")
  private lazy var nativePublication = TerrainPublicationQueue<TerrainPreparedMeshes>(
    maximumRunning: 4, maximumEntries: 8,
    prepare: { [terrainResources] in try await terrainResources.prepare($0) },
    discard: { [terrainResources] in terrainResources.discard($0) })
  var nativePublicationMetrics: TerrainPublicationMetrics { nativePublication.metrics }
  private lazy var nativeFeeder = makeNativeFeeder()
  var nativeAdmissionMetrics: TerrainPublicationFeederMetrics { nativeFeeder.metrics }
  private func makeNativeFeeder() -> TerrainPublicationFeeder<TerrainPreparedMeshes> {
    let coordinator = terrainCoordinator
    let feeder = TerrainPublicationFeeder(exchange: terrainExchange, queue: nativePublication,
      independent: asynchronousTerrainPublication
        && !ProcessInfo.processInfo.arguments.contains("--frame-driven-terrain-preparation"),
      reuseMeshes: terrainResources.reuseEnabled,
      permits: { [weak self] in self?.terrainResources.permitsPublication == true },
      current: { [weak self] in self?.isCurrent($0) == true },
      retry: { [weak self] id in
        self?.cancelPreparation(id.tile); self?.queueNeedsRebuild = true
      },
      resumeWorkers: { coordinator.wake() })
    terrainResources.onAdmissionAvailable = { [weak feeder] in feeder?.wake() }
    return feeder
  }
  private let dryRegionsEnabled = !ProcessInfo.processInfo.arguments.contains("--no-dry-region-refinement")
  private let dryRegionWorker = TerrainDryRegionWorker()
  private lazy var dryRegionTransaction = makeDryRegionTransaction()
  private func makeDryRegionTransaction() -> TerrainRegionTransaction<TerrainPreparedMeshes> {
    let worker = dryRegionWorker
    return .init(build: { request in await worker.build(request) },
      prepare: { [terrainResources] in try await terrainResources.prepare($0) },
      discard: { [terrainResources] in terrainResources.discard($0) },
      valid: { [weak self] in self?.isCurrentDryRegion($0) == true })
  }
  private struct DryRegion {
    let candidate: TerrainDryRegion.Candidate
    let entity: Entity
    let resource: TerrainPreparedMeshes
    var band: Int
    var hazeVersion: Int
    var charge: Int {
      candidate.prepared.publicationByteCount(reuseMeshes: true)
        + candidate.ground.byteCount + candidate.water.byteCount
    }
  }
  private struct DryRegionAttempt {
    let source: TerrainWorkID
    let revision: UInt64
    let ground: TerrainSurfaceSources.Lease
    let water: WaterSurfaceSources.Lease
  }
  private var dryRegions: [TerrainTile: DryRegion] = [:]
  private var dryRegionAttempts: [TerrainTile: DryRegionAttempt] = [:]
  private var lastDryRegionSurvey: Double = -.infinity
  private var dryRegionsPublished = 0, dryRegionsRestored = 0
  var dryRegionMetrics: PerformanceTrace.DryRegions {
    .init(enabled: dryRegionsEnabled, transaction: dryRegionTransaction.metrics,
      active: dryRegions.count, published: dryRegionsPublished, restored: dryRegionsRestored,
      logicalBytes: dryRegions.values.reduce(0) { $0+$1.charge },
      activeTriangles: dryRegions.values.reduce(0) { $0+$1.candidate.prepared.mesh.indices.count/3 },
      retainedFallbackTriangles: dryRegions.keys.reduce(0) { $0+(triangleCounts[$1] ?? 0) })
  }
  // Loaded scene geometry, not GPU-visible primitives or presented-frame data.
  var terrainGeometryTriangles: Int {
    terrainTriangles + dryRegions.values.reduce(0) {
      $0 + $1.candidate.prepared.mesh.indices.count/3 - (triangleCounts[$1.candidate.tile] ?? 0)
    }
  }
  var terrainGeometryParts: Int {
    terrainDrawParts + dryRegions.values.reduce(0) {
      $0 + $1.candidate.prepared.mesh.parts.count - (renderParts[$1.candidate.tile] ?? 0)
    }
  }
  private var terrainAllocations: [TerrainTile: TerrainMeshAllocation] = [:]
  private var capacityBytes: [TerrainTile: Int] = [:]
  private(set) var residentMeshCapacityBytes = 0
  private var animatedEntities: [TerrainTile: Entity] = [:]
  private let stadiumSeats = StadiumSeatRenderer()
  private var seatEntities: [TerrainTile: [Entity]] = [:]
  private var seatCounts: [TerrainTile: Int] = [:]
  private var seatInstanceCount = 0, seatGroupCount = 0
  var seatInstancingMetrics: StadiumSeatRenderer.Metrics {
    stadiumSeats.metrics(instances: seatInstanceCount, groups: seatGroupCount)
  }
  private var triangleCounts: [TerrainTile: Int] = [:]
  private var renderParts: [TerrainTile: Int] = [:]
  private var meshBytes: [TerrainTile: Int] = [:]
  private(set) var residentMeshBytes = 0
  var replacementVisibilityMetrics: PerformanceTrace.TerrainReplacementVisibility {
    var hiddenTiles = 0, hiddenBytes = 0, parents = 0, parentBytes = 0
    // Called only by the five-second trace, never in the frame update loop.
    for (tile, bytes) in meshBytes {
      if !visibleTiles.contains(tile) { hiddenTiles += 1; hiddenBytes += bytes }
      else if !desired.contains(tile) { parents += 1; parentBytes += bytes }
    }
    return .init(hiddenTiles: hiddenTiles, hiddenMeshBytes: hiddenBytes,
      retainedParents: parents, retainedParentMeshBytes: parentBytes)
  }
  var residentVoxelBytes: Int { (chunks.count + collisionChunks.count) * 18 * 18 * (ChunkData.height - ChunkData.minimumY) }
  private var removalTiming = DurationTiming()
  private(set) var materials: [any Material] = []
  private var repeatingAtlas: TerrainAtlasMaterial?
  private var repeatingAtlasTask: Task<Void, Never>?
  var terrainMesherBackend: String { repeatingAtlas == nil ? "individual_faces" : "greedy_opaque" }
  private(set) var environment = WorldEnvironment()
  private let terrainExchange = TerrainStreamingExchange(
    agingReadyResults: !ProcessInfo.processInfo.arguments.contains("--no-terrain-ready-aging"))
  private lazy var terrainCoordinator = TerrainStreamingCoordinator(exchange: terrainExchange,
    indexedWorkQueue: !ProcessInfo.processInfo.arguments.contains("--scan-terrain-work-queue"))
  private var requestSequence: UInt64 = 0
  private var requestIncarnation: UInt64 = 0
  private var activeRequests: [TerrainTile: TerrainWorkID] = [:]
  private var demandCache = TerrainDemandCache(
    enabled: !ProcessInfo.processInfo.arguments.contains("--rebuild-terrain-demand"))
  var demandMetrics: TerrainDemandCache.Metrics { demandCache.metrics }
  private var queueNeedsRebuild = false
  private var visibleTiles: Set<TerrainTile> = []
  let incrementalTerrainCoverage = !ProcessInfo.processInfo.arguments.contains("--full-scan-terrain-coverage")
  private var coverageTracker = TerrainCoverageTracker()
  var coverageTrackerMetrics: TerrainCoverageTracker.Metrics { coverageTracker.metrics }
  private var travelPrefetch = TerrainTravelPrefetch(
    enabled: ProcessInfo.processInfo.arguments.contains("--adaptive-terrain-prefetch")
      && !ProcessInfo.processInfo.arguments.contains("--fixed-terrain-prefetch"))
  var travelPrefetchMetrics: TerrainTravelPrefetch.Metrics { travelPrefetch.metrics }
  private var coverageDiagnostics = TerrainCoverageDiagnostics()
  private var lastCoverageSample: Double = -.infinity
  var measuresStreamingCoverage = false
  var coverageViewDirection = SIMD3<Float>.zero
  var coverageDetails: TerrainCoverageDiagnosticsMetrics { coverageDiagnostics.snapshot }
  func resetCoverageDiagnostics() {
    coverageDiagnostics = .init(); lastCoverageSample = -.infinity
    if !travelPrefetch.enabled { travelPrefetch.reset() }
  }
  func sampleCoverage(at time: Double) {
    guard measuresStreamingCoverage, time - lastCoverageSample >= 0.25,
      let center = lastViewerCenter else { return }
    lastCoverageSample = time
    coverageDiagnostics.submit(.init(world: lifecycle, center: center, radius: lastRadius,
      detailRadius: lastDetailRadius, target: finalDesired, visible: visibleTiles,
      direction: coverageViewDirection, time: time))
  }
  private var dirtyTiles: Set<TerrainTile> = []
  private var revisions: [TerrainTile: Int] = [:]
  private var desired: Set<TerrainTile> = []
  private var finalDesired: Set<TerrainTile> = []
  private var speculativeDetail: Set<TerrainTile> = []
  private var lastFixedLookAhead: ChunkCoordinate?
  private var frontierPlanner = ProgressiveTerrainPlanner(
    enabled: !ProcessInfo.processInfo.arguments.contains("--rebuild-terrain-frontier"),
    maximumReplacementTiles: ProcessInfo.processInfo.arguments.contains("--small-terrain-replacement-groups") ? 8 : 16)
  var frontierPlanningMetrics: ProgressiveTerrainPlanner.Metrics { frontierPlanner.metrics }
  private let projectedDetailEnabled = ProcessInfo.processInfo.arguments.contains("--projected-terrain-detail")
  private let refinementService = TerrainRefinementService()
  private var surfaceProfiles = TerrainSurfaceProfiles()
  private var surfaceSources = TerrainSurfaceSources()
  var surfaceSourceMetrics: TerrainSurfaceSources.Metrics { surfaceSources.metrics }
  // Background feature preparation must capture these published sources and
  // revalidate them alongside its separate voxel/world/view/water dependencies.
  func visibleSurfaceSources() -> TerrainSurfaceSources.Snapshot? {
    surfaceSources.snapshot(visible: visibleTiles, unavailable: Set(dryRegions.keys))
  }
  func isCurrentSurfaceSource(_ snapshot: TerrainSurfaceSources.Snapshot) -> Bool {
    surfaceSources.isCurrent(snapshot, visible: visibleTiles, unavailable: Set(dryRegions.keys))
  }
  func isCurrentSurfaceSource(_ lease: TerrainSurfaceSources.Lease) -> Bool {
    surfaceSources.isCurrent(lease, visible: visibleTiles, unavailable: Set(dryRegions.keys))
  }
  // Both snapshots are captured synchronously on MainActor. Their coverage
  // partitions can differ during LOD exchange; consumers must use each actual
  // owner rather than borrowing the terrain tile's water representation.
  func visibleFeatureSources() -> (ground: TerrainSurfaceSources.Snapshot, water: WaterSurfaceSources.Snapshot)? {
    guard let ground = visibleSurfaceSources(), let water = ocean.visibleSurfaceSources() else { return nil }
    return (ground, water)
  }
  func areCurrentFeatureSources(ground: TerrainSurfaceSources.Lease, water: WaterSurfaceSources.Lease) -> Bool {
    isCurrentSurfaceSource(ground) && ocean.isCurrentSurfaceSource(water)
  }
  private var baseDesired = Set<TerrainTile>(), refinementSplits = Set<TerrainTile>()
  private var refinementRevision: UInt64 = 0, refinementSequence: UInt64 = 0, appliedRefinement: UInt64 = 0
  private var refinementNeedsUpdate = true
  private var lastRefinementTime: Double = -.infinity
  private var lastRefinementEye = SIMD3<Float>(repeating: .infinity)
  var refinementMetrics: TerrainRefinementMetrics { projectedDetailEnabled ? refinementService.metrics : .init() }
  var caveSamplingName: String { generator.bulkCaves ? "bulk columns" : "scalar" }
  private var needsFrontier = false
  private var lushTiles: Set<TerrainTile> = []
  private(set) var loadedChunks: Set<ChunkCoordinate> = []
  private var lifecycle = UUID()
  private var uploadBudget: StreamingBudget = {
    let legacy = ProcessInfo.processInfo.arguments.contains("--legacy-terrain-publication-budget")
      || ProcessInfo.processInfo.arguments.contains("--synchronous-terrain-publication")
    return .init(maximumTiles: legacy ? 4 : 8, reservesCoverage: !legacy)
  }()
  var publicationBudgetMetrics: StreamingBudget.Metrics { uploadBudget.metrics }
  private(set) var lastUploadMilliseconds: Double = 0
  private var editRegions: [ChunkCoordinate: [BlockPosition: Block]] = [:]
  private var edits: [BlockPosition: Block] = [:]
  private var generator = TerrainGenerator(seed: 0)
  var terrain: TerrainGenerator { generator }
  private var lastCenter: ChunkCoordinate?
  private var lastRadius = 0
  private var lastDetailRadius = 0
  private var lastLookAhead: ChunkCoordinate?
  private var lastViewerCenter: ChunkCoordinate?
  private var hazeMaterials: [[any Material]] = []
  private var hazeBands: [TerrainTile: Int] = [:]
  private var distantMaterials: [[any Material]] = []
  private var distantTexture: MaterialParameters.Texture?
  private var hazeColor = SIMD3<Float>(repeating: -1)
  private var hazeEye = SIMD3<Float>.zero
  private var lastHazeUpdate: Double = -.infinity
  private var hazeRevision = 0
  private var hazeVersions: [TerrainTile: Int] = [:]
  private var hazeQueue: [TerrainTile] = []
  private var hazeCursor = 0
  private var pendingHazeColor: SIMD3<Float>?
  private var nextHazeMaterials: [[any Material]] = []
  private var nextDistantMaterials: [[any Material]] = []
  private var hazeTiming = DurationTiming()
  private var uploadTiming = DurationTiming()
  private var lifeActive = false
  var onError: ((String) -> Void)?
  private(set) var renderedChunkCount = 0
  var terrainTileCount: Int { entities.count }
  private(set) var terrainTriangles = 0
  private(set) var terrainDrawParts = 0
  var streamingJobCount: Int {
    let count = terrainExchange.counts, native = nativePublication.counts
    return count.workers + count.ready + native.running + native.ready
  }
  var terrainWorkerCount: Int { terrainExchange.counts.workers }
  var readyTerrainTileCount: Int { terrainExchange.counts.ready + nativePublication.counts.ready }
  var queuedTerrainTileCount: Int { terrainExchange.counts.queued }
  var streamingMetrics: TerrainStreamingExchange.Metrics { terrainExchange.metrics }
  var coverageMetrics: TerrainCoverageMetrics {
    .init(center: lastViewerCenter ?? .init(0, 0), radius: max(1, lastRadius),
      target: finalDesired, visible: visibleTiles)
  }

  init() {
    root.addChild(terrainRoot)
    wildlife.life = fauna; dinosaurs.life = fauna
    life.currentWorldRevision = { [weak self] in self?.worldRevision ?? 0 }
    life.onApplied = { [weak self] in
      self?.wildlife.applySimulation($0.wildlife)
      self?.dinosaurs.applySimulation($0.dinosaurs, bites: $0.bites)
    }
  }

  func suspendLife() {
    vehicles.suspendDecisions()
    life.suspend()
    lifeActive = false
  }

  func configure(
    seed: UInt64, style: PlanetStyle = .verdant, edits: [BlockPosition: Block],
    environment: WorldEnvironment
  ) throws {
    clear()
    self.edits = edits
    editRegions = Dictionary(grouping: edits.keys, by: \.chunk).mapValues { positions in
      Dictionary(uniqueKeysWithValues: positions.map { ($0, edits[$0]!) })
    }
    generator = .init(seed: seed, style: style,
      bulkCaves: !ProcessInfo.processInfo.arguments.contains("--scalar-terrain-caves"))
    self.environment = environment
    root.isEnabled = false
    root.scale = .init(repeating: WorldScale.metresPerBlock)
    let atlas = try TextureResource.load(
      named: "BlockAtlas\(style.assetSuffix).png", options: .init(semantic: .color))
    guard atlas.width == 1024 && atlas.height == 512 else { throw CocoaError(.fileReadCorruptFile) }
    let descriptor = MTLSamplerDescriptor()
    descriptor.minFilter = .nearest
    descriptor.magFilter = .nearest
    // Keep close pixels crisp while blending mip levels to reduce VR shimmer.
    descriptor.mipFilter = .linear
    descriptor.lodMaxClamp = 3
    descriptor.maxAnisotropy = 4
    let texture = MaterialParameters.Texture(atlas, sampler: .init(descriptor))
    let farSampler = MTLSamplerDescriptor()
    farSampler.minFilter = .linear
    farSampler.magFilter = .linear
    farSampler.mipFilter = .linear
    farSampler.lodMaxClamp = 3
    farSampler.maxAnisotropy = 1
    distantTexture = .init(atlas, sampler: .init(farSampler))
    var ground = PhysicallyBasedMaterial()
    ground.baseColor = .init(tint: .white, texture: texture)
    ground.roughness = .init(floatLiteral: 0.82)
    let normal = try TextureResource.load(
      named: "BlockNormals.png", options: .init(semantic: .normal))
    ground.normal = .init(texture: .init(normal, sampler: .init(descriptor)))
    let occlusion = try TextureResource.load(
      named: "BlockOcclusion.png", options: .init(semantic: .raw))
    ground.ambientOcclusion = .init(texture: .init(occlusion, sampler: .init(descriptor)))
    var water = PhysicallyBasedMaterial()
    water.baseColor = .init(tint: .cyan)
    var glass = PhysicallyBasedMaterial()
    glass.baseColor = .init(
      tint: UIColor(red: 0.73, green: 0.91, blue: 0.96, alpha: 1), texture: texture)
    glass.roughness = .init(floatLiteral: 0.10)
    glass.specular = .init(floatLiteral: 0.9)
    glass.blending = .transparent(opacity: .init(floatLiteral: 0.22))
    glass.faceCulling = .none
    var lamp = ground
    lamp.emissiveColor = .init(color: UIColor(red: 1, green: 0.72, blue: 0.30, alpha: 1))
    lamp.emissiveIntensity = 1.3
    var foliage = ground
    foliage.roughness = .init(floatLiteral: 0.9)
    var lava = ground
    lava.emissiveColor = .init(color: .white, texture: texture)
    lava.emissiveIntensity = 2
    lava.roughness = .init(floatLiteral: 0.55)
    materials = [ground, water, glass, lamp, foliage, lava]
    rebuildHazeMaterials()
    loadRepeatingAtlas(atlas)
    buildSelection()
    try atmosphere.configure(seed: seed, style: style, world: root)
    try ocean.configure(style: style)
    wind.configure()
    wildlife.configure(terrain: generator)
    try dinosaurs.configure()
    precipitation.configure(root: root, snow: style == .frost)
    root.addChild(selection)
    root.addChild(fractures)
    selection.isEnabled = false
  }

  func clear() {
    dryRegionTransaction.invalidate()
    for tile in Array(dryRegions.keys) { restoreDryRegion(tile) }
    dryRegionAttempts.removeAll(); lastDryRegionSurvey = -.infinity
    dryRegionsPublished = 0; dryRegionsRestored = 0
    repeatingAtlasTask?.cancel(); repeatingAtlasTask = nil; repeatingAtlas = nil
    wind.clear()
    worldRevision &+= 1; life.reset()
    lifecycle = UUID()
    nativePublication.retain { _ in false }
    requestSequence &+= 1
    terrainExchange.expect([], sequence: requestSequence)
    terrainCoordinator.wake()
    activeRequests.removeAll()
    demandCache.reset()
    queueNeedsRebuild = false
    visibleTiles.removeAll()
    coverageTracker.reset()
    travelPrefetch.reset()
    speculativeDetail.removeAll(); lastFixedLookAhead = nil
    coverageDiagnostics = .init(); lastCoverageSample = -.infinity; coverageViewDirection = .zero
    revisions.removeAll()
    dirtyTiles.removeAll()
    terrainRoot.isEnabled = false
    terrainRoot.removeFromParent()
    for (tile, entity) in entities {
      terrainResources.retire(entity, allocation: terrainAllocations[tile], bytes: capacityBytes[tile] ?? 0)
    }
    entities.removeAll()
    terrainAllocations.removeAll(); capacityBytes.removeAll(); residentMeshCapacityBytes = 0
    animatedEntities.removeAll()
    seatEntities.removeAll(); seatCounts.removeAll(); seatInstanceCount = 0; seatGroupCount = 0
    chunks.removeAll()
    collisionChunks.removeAll(); playerCollision.clear(); entryReadiness.reset()
    plants.removeAll(); plantChanges.removeAll(); pickups.clear()
    fractures.children.removeAll(); fractureStage = -1
    desired.removeAll()
    finalDesired.removeAll(); needsFrontier = false; frontierPlanner.reset()
    baseDesired.removeAll(); refinementSplits.removeAll(); surfaceProfiles = .init()
    surfaceSources.reset()
    invalidateRefinementPlan()
    lastRefinementTime = -.infinity; lastRefinementEye = .init(repeating: .infinity)
    root.children.removeAll()
    atmosphere.clear()
    ocean.clear()
    wildlife.clear()
    dinosaurs.clear()
    settlementLife.clear()
    precipitation.clear()
    fire.clear(); lamps.clear(); doors.clear()
    vehicles.clear()
    boats.clear();sports.clear();previousGiantPosition=nil
    terrainRoot = Entity()
    root.addChild(terrainRoot)
    lastCenter = nil
    uploadBudget.reset()
    lastUploadMilliseconds = 0
    triangleCounts.removeAll()
    renderParts.removeAll()
    meshBytes.removeAll(); residentMeshBytes = 0; removalTiming.reset()
    editRegions.removeAll()
    distantMaterials.removeAll()
    lushTiles.removeAll()
    lastLookAhead = nil
    lastViewerCenter = nil
    loadedChunks.removeAll()
    hazeMaterials.removeAll()
    hazeBands.removeAll()
    hazeColor = .init(repeating: -1)
    lastHazeUpdate = -.infinity
    renderedChunkCount = 0; terrainTriangles = 0; terrainDrawParts = 0
    hazeVersions = [:]; hazeQueue = []; hazeCursor = 0; hazeRevision = 0
    pendingHazeColor = nil; nextHazeMaterials = []; nextDistantMaterials = []
  }

  private func loadRepeatingAtlas(_ atlas: TextureResource) {
    // Matched on-device A/B captures can keep every distance and quality
    // setting identical while disabling only this representation change.
    guard !ProcessInfo.processInfo.arguments.contains("--legacy-terrain-mesher") else {
      print("WORLDCRAFT_TERRAIN material=standard_atlas mesher=individual_faces reason=launch_argument")
      return
    }
    let world = lifecycle
    repeatingAtlasTask = Task(priority: .utility) { [weak self] in
      do {
        let loaded = try await TerrainAtlasMaterial.load(atlas: atlas)
        guard !Task.isCancelled, let self, self.lifecycle == world else { return }
        self.repeatingAtlas = loaded
        self.materials.append(loaded.surface)
        self.nextHazeMaterials = []; self.nextDistantMaterials = []; self.pendingHazeColor = nil
        self.rebuildHazeMaterials(); self.hazeRevision += 1
        // Existing geometry stays visible. Upgrades use the same bounded
        // preparation/publication path and cannot form a second scene backlog.
        for tile in self.desired where tile.fullDetail {
          self.revisions[tile, default: 0] += 1
          if self.entities[tile] != nil { self.dirtyTiles.insert(tile) }
          self.cancelPreparation(tile)
        }
        self.queueNeedsRebuild = true
        print("WORLDCRAFT_TERRAIN material=repeating_atlas mesher=greedy_opaque")
      } catch {
        guard !Task.isCancelled, let self, self.lifecycle == world else { return }
        print("WORLDCRAFT_TERRAIN material=standard_atlas mesher=individual_faces reason=\(error)")
      }
    }
  }

  func block(at p: BlockPosition) -> Block {
    if let block = edits[p] { return generator.waterSafeMaterial(block, at: p) }
    if let chunk = chunks[p.chunk] { return chunk[p.x - p.chunk.x * 16, p.y, p.z - p.chunk.z * 16] }
    return generator.block(at: p)
  }

  func playerBlock(at p: BlockPosition) -> Block {
    playerCollision.block(at: p, terrain: generator,
      chunk: collisionChunks[p.chunk] ?? chunks[p.chunk], edit: edits[p])
  }

  func playerCameraBlock(at p: BlockPosition) -> Block {
    entityObstacle?(p) == true ? .basalt : doors.block(p) ?? playerBlock(at: p)
  }

  func waitingForInitialTerrain(at position: SIMD3<Float>) -> Bool {
    entryReadiness.observe(chunkReady: chunks[BlockPosition(position).chunk] != nil)
    return entryReadiness.isWaiting
  }

  func stream(
    around position: SIMD3<Float>, radius: Int, detailRadius: Int = DrawDistance.detailedRadius,
    velocity: SIMD3<Float> = .zero, frameInterval: Double = 0
  ) {
    let center = BlockPosition(position).chunk
    let radius = DrawDistance.clamp(radius)
    let detailRadius = DrawDistance.clampDetail(detailRadius)
    hazeEye = position
    let anchor = TerrainStreamingPlan.anchor(
      for: center, radius: radius,
      previous: radius == lastRadius ? lastCenter : nil)
    let ahead = travelPrefetch.lookAhead(from: anchor, velocity: velocity, detailRadius: detailRadius)
    let fixedAhead = TerrainStreamingPlan.lookAhead(from: anchor, velocity: velocity)
    var needsQueue = queueNeedsRebuild
    queueNeedsRebuild = false
    if anchor != lastCenter || radius != lastRadius || detailRadius != lastDetailRadius
      || ahead != lastLookAhead || fixedAhead != lastFixedLookAhead {
      let trace = PerformanceTrace.begin("Plan terrain tiles")
      lastCenter = anchor
      lastRadius = radius
      lastDetailRadius = detailRadius
      lastLookAhead = ahead
      lastFixedLookAhead = fixedAhead
      baseDesired = TerrainStreamingPlan(center: anchor, radius: radius,
        detailRadius: detailRadius, lookAhead: ahead).tiles
      if travelPrefetch.enabled {
        let fixed = TerrainStreamingPlan(center: anchor, radius: radius,
          detailRadius: detailRadius, lookAhead: fixedAhead).tiles
        speculativeDetail = Set(baseDesired.subtracting(fixed).filter(\.fullDetail))
      } else { speculativeDetail.removeAll(keepingCapacity: true) }
      finalDesired = projectedDetailEnabled
        ? TerrainRefinementPlan.retaining(refinementSplits, in: baseDesired) : baseDesired
      invalidateRefinementPlan()
      needsFrontier = true
      PerformanceTrace.end("Plan terrain tiles", trace)
    }
    if lastViewerCenter != center {
      lastViewerCenter = center
      needsFrontier = true
      needsQueue = true
      // Plant detail must be upgraded after approaching an already loaded chunk.
      // Hysteresis prevents remeshing it repeatedly at the quality boundary.
      for tile in desired where tile.fullDetail && entities[tile] != nil {
        let lush = VegetationDetail.isLush(tile.coordinate, center: center,
          previouslyLush: lushTiles.contains(tile))
        if lush != lushTiles.contains(tile), !dirtyTiles.contains(tile) {
          // Let an in-flight upgrade finish. install() rechecks the final target;
          // restarting it on every crossed chunk starved detail during flight.
          dirtyTiles.insert(tile)
          needsQueue = true
        }
      }
    }
    if projectedDetailEnabled { updateRefinement(eye: position, time: CACurrentMediaTime()) }
    if needsFrontier {
      needsFrontier = false
      let frontier = PerformanceTrace.measure(.terrainFrontier) {
        frontierPlanner.plan(target: finalDesired, visible: visibleTiles, center: center).tiles
      }
      if desired != frontier {
        for tile in desired.subtracting(frontier) { cancelPreparation(tile) }
        desired = frontier
        if incrementalTerrainCoverage { coverageTracker.setDesired(desired) }
        revisions = revisions.filter { desired.contains($0.key) }
        dirtyTiles.formIntersection(desired)
        refreshCoverage()
        needsQueue = true
      }
    }
    if needsQueue { rebuildWorkQueue(center: center) }
    // Workers publish collision data directly into a bounded value mailbox.
    // They never await the render actor before starting meshing or their next job.
    for (id, chunk) in terrainExchange.takeCollisions() where isCurrent(id) {
      collisionChunks[id.tile.coordinate] = chunk
    }
    let now = CACurrentMediaTime()
    let urgent = chunks[center] == nil
    var published = 0, bytes = 0, consumed = 0
    if uploadBudget.beginFrame(interval: frameInterval, time: now, urgent: urgent) {
      while uploadBudget.allowsNextTile(elapsed: CACurrentMediaTime() - now,
        published: published, bytes: bytes, urgent: urgent) {
        // Collision/input and worker coordination continue while old resources
        // drain. The bounded ready mailbox backpressures only visual uploads.
        guard terrainResources.permitsPublication else { break }
        let limit = published == 0 ? Int.max : StreamingBudget.maximumFrameBytes - bytes
        let began = CACurrentMediaTime()
        let result: PreparedTerrainTile
        if asynchronousTerrainPublication {
          guard let prepared = nativePublication.takeReady(maximumBytes: limit) else { break }
          result = prepared.input
          switch prepared.result {
          case let .success(meshes): install(result, prepared: meshes)
          case let .failure(error):
            if isCurrent(result.id) {
              cancelPreparation(result.tile)
              handleTerrainFailure(error)
            }
          }
        } else {
          guard let ready = terrainExchange.takeReady(maximumBytes: limit) else { break }
          result = ready; consumed += 1
          install(result)
        }
        uploadBudget.recordTile(seconds: CACurrentMediaTime() - began)
        published += 1; bytes += result.byteCount
      }
      if published > 0 {
        let coverageBegan = CACurrentMediaTime()
        refreshCoverage()
        uploadBudget.recordCoverage(seconds: CACurrentMediaTime() - coverageBegan)
        let cost = CACurrentMediaTime() - now
        lastUploadMilliseconds = cost * 1_000
        uploadTiming.record(seconds: cost)
        uploadBudget.published(cpuTime: cost, time: now)
      }
    }
    uploadBudget.recordFrame(published: published, bytes: bytes, remainingReady:
      asynchronousTerrainPublication ? nativePublication.counts.ready : terrainExchange.occupancy.tiles)
    // CPU completions and native capacity changes also refill this stage through
    // one coalesced event consumer. Scene adoption stays in the budget above.
    if asynchronousTerrainPublication {
      nativeFeeder.refill()
    }
    if published > 0 || consumed > 0 {
      terrainCoordinator.wake()
    }
    updateDryRegions(time: now, mayPublish: published == 0 && terrainResources.permitsPublication)
    if travelPrefetch.enabled || measuresStreamingCoverage {
      PerformanceTrace.measure(.terrainPrefetch) {
        travelPrefetch.observe(world: lifecycle, target: finalDesired, visible: visibleTiles, time: now)
      }
    }
  }

  private func isCurrentDryRegion(_ candidate: TerrainDryRegion.Candidate) -> Bool {
    dryRegionsEnabled && candidate.source.world == lifecycle && candidate.revision == worldRevision
      && repeatingAtlas != nil && visibleTiles.contains(candidate.tile) && desired.contains(candidate.tile)
      && !dirtyTiles.contains(candidate.tile) && activeRequests[candidate.tile] == nil
      && candidate.permits(eye: hazeEye)
      && surfaceSources.isCurrent(candidate.ground, visible: visibleTiles)
      && ocean.isCurrentSurfaceSource(candidate.water)
  }

  private func restoreDryRegion(_ tile: TerrainTile) {
    guard let region = dryRegions.removeValue(forKey: tile) else { return }
    region.entity.isEnabled = false
    terrainResources.retire(region.entity, allocation: region.resource.allocation,
      bytes: region.resource.allocation?.capacity.bytes ?? 0)
    entities[tile]?.isEnabled = visibleTiles.contains(tile)
    dryRegionsRestored += 1
  }

  private func validateDryRegions() {
    // Any ownership/edit/view change restores fallback in this same synchronous
    // scene update. Mixed surface/volume regions are unavailable to heightfield
    // consumers while visible, never substituted with their hidden fallback.
    for tile in Array(dryRegions.keys) {
      guard var region = dryRegions[tile] else { continue }
      guard isCurrentDryRegion(region.candidate) else { restoreDryRegion(tile); continue }
      let band = hazeBand(tile, eye: hazeEye)
      if region.band != band || region.hazeVersion != hazeRevision {
        if var model = region.entity.components[ModelComponent.self] {
          model.materials = hazeMaterials[band]; region.entity.components.set(model)
        }
        region.band = band; region.hazeVersion = hazeRevision; dryRegions[tile] = region
      }
      entities[tile]?.isEnabled = false
    }
  }

  private func updateDryRegions(time: Double, mayPublish: Bool) {
    validateDryRegions()
    if mayPublish, let ready = dryRegionTransaction.takeReady() {
      let candidate = ready.candidate, tile = candidate.tile
      let charge = candidate.prepared.publicationByteCount(reuseMeshes: true)
        + candidate.ground.byteCount + candidate.water.byteCount
      let occupied = dryRegions.values.reduce(0) { $0+$1.charge }
      if dryRegions.count < 4, charge <= 32*1_024*1_024-occupied,
        !dryRegions.keys.contains(where: { dryRegionsTouch($0,tile) }) {
        // No throwing operation or await separates enabling the complete new
        // mesh from hiding its retained parent. Water is certified unchanged/dry.
        let entity = Entity(), band = hazeBand(tile, eye: hazeEye)
        if let allocation = ready.resource.allocation {
          entity.components.set(ModelComponent(mesh: allocation.resource, materials: hazeMaterials[band]))
        }
        entity.components.set(DynamicLightShadowComponent(castsShadow: false))
        entity.name = "Dry voxel region"; entity.position = tile.origin
        terrainRoot.addChild(entity)
        entities[tile]?.isEnabled = false
        dryRegions[tile] = .init(candidate: candidate, entity: entity, resource: ready.resource,
          band: band, hazeVersion: hazeRevision)
        dryRegionsPublished += 1
      } else { terrainResources.discard(ready.resource) }
    }
    guard dryRegionsEnabled, repeatingAtlas != nil, !editRegions.isEmpty,
      dryRegions.count < 4, dryRegionTransaction.hasCapacity,
      time-lastDryRegionSurvey >= 0.5 else { return }
    lastDryRegionSurvey = time
    // Urgent coverage and the existing two preparation workers get priority.
    let count = terrainExchange.counts
    guard count.workers < 2, count.queued < 32, terrainResources.permitsPublication else { return }
    dryRegionAttempts = dryRegionAttempts.filter { visibleTiles.contains($0.key) }
    let center = lastViewerCenter ?? .init(0,0)
    var editedOwners = Set<TerrainTile>()
    for key in editRegions.keys {
      for size in [1,2] {
        let tile = TerrainTile(x: floorDivide(key.x,by:size)*size, z: floorDivide(key.z,by:size)*size, size:size)
        if visibleTiles.contains(tile) { editedOwners.insert(tile) }
      }
    }
    let choices = editedOwners.filter { tile in
      !tile.fullDetail && tile.size <= 2 && desired.contains(tile)
        && !dirtyTiles.contains(tile) && activeRequests[tile] == nil
        && TerrainDryRegion.permits(eye: hazeEye, outside: tile)
        && !dryRegions.keys.contains(where: { dryRegionsTouch($0,tile) })
    }.sorted {
      let a = ($0.distanceSquared(to: center),$0.z,$0.x,$0.size)
      let b = ($1.distanceSquared(to: center),$1.z,$1.x,$1.size)
      return a < b
    }
    guard !choices.isEmpty, let ground = surfaceSources.snapshot(visible: visibleTiles),
      let water = ocean.visibleSurfaceSources() else { return }
    for tile in choices {
      guard let source = ground.sources[tile] else { continue }
      if let attempt = dryRegionAttempts[tile], attempt.source == source.id,
        attempt.revision == worldRevision,
        surfaceSources.isCurrent(attempt.ground, visible: visibleTiles),
        ocean.isCurrentSurfaceSource(attempt.water) { continue }
      var edits: [BlockPosition: Block] = [:], plants: [BlockPosition: PlantEdit] = [:]
      var reads = Set<ChunkCoordinate>()
      for z in (tile.z-1)...(tile.z+tile.size) { for x in (tile.x-1)...(tile.x+tile.size) {
        let key = ChunkCoordinate(x,z); reads.insert(key)
        edits.merge(editRegions[key] ?? [:], uniquingKeysWith: { _,new in new })
        plants.merge(plantChanges[key] ?? [:], uniquingKeysWith: { _,new in new })
      } }
      let request = TerrainDryRegion.Request(source: source.id, revision: worldRevision,
        terrain: generator, ground: ground, water: water, edits: edits, plants: plants)
      dryRegionAttempts[tile] = .init(source: source.id, revision: worldRevision,
        ground: ground.dependencies(for: reads), water: water.dependencies(for: reads))
      if dryRegionTransaction.admit(request) { break }
    }
  }

  private func dryRegionsTouch(_ a: TerrainTile, _ b: TerrainTile) -> Bool {
    // Adjacent independent transactions would change one another's interfaces.
    // Join them in a future multi-region transaction; retain the fallback now.
    a.x <= b.x+b.size && a.x+a.size >= b.x && a.z <= b.z+b.size && a.z+a.size >= b.z
  }

  private func invalidateRefinementPlan() {
    guard projectedDetailEnabled else { return }
    refinementRevision &+= 1; appliedRefinement = 0; refinementNeedsUpdate = true
    refinementService.expect(world: lifecycle, revision: refinementRevision)
  }

  private func updateRefinement(eye: SIMD3<Float>, time: Double) {
    guard projectedDetailEnabled else { return }
    // Read a completed value; scene updates never await the planning actor.
    if let result = refinementService.latest, result.input.world == lifecycle,
      result.input.revision == refinementRevision, result.input.sequence > appliedRefinement {
      appliedRefinement = result.input.sequence; refinementSplits = result.plan.splits
      if finalDesired != result.plan.tiles { finalDesired = result.plan.tiles; needsFrontier = true }
    }
    guard time - lastRefinementTime >= 0.25 else { return }
    // Eight-block cells and an eight-block dead band suppress small pose jitter.
    let delta = eye - lastRefinementEye
    let moved = max(abs(delta.x), abs(delta.y), abs(delta.z)) > 8
    guard refinementNeedsUpdate || moved else { return }
    if moved { lastRefinementEye = .init((eye.x / 8).rounded() * 8, (eye.y / 8).rounded() * 8, (eye.z / 8).rounded() * 8) }
    refinementNeedsUpdate = false; lastRefinementTime = time; refinementSequence &+= 1
    refinementService.submit(.init(world: lifecycle, revision: refinementRevision,
      sequence: refinementSequence, base: baseDesired, previousSplits: refinementSplits,
      profiles: surfaceProfiles.values, eye: lastRefinementEye))
  }

  private func isCurrent(_ id: TerrainWorkID) -> Bool {
    id.world == lifecycle && activeRequests[id.tile] == id && desired.contains(id.tile)
      && revisions[id.tile, default: 0] == id.revision
  }

  private func rebuildWorkQueue(center: ChunkCoordinate) {
    let began = PerformanceTrace.measuresPhases ? CACurrentMediaTime() : 0
    defer { PerformanceTrace.record(.terrainDemand, since: began) }
    let available = Set(entities.keys)
    let ordering = TerrainWorkPriority.streaming(desired: desired, available: available,
      center: center, lookAhead: lastLookAhead ?? center, speculative: speculativeDetail)
    let waiting = desired.filter { entities[$0] == nil || dirtyTiles.contains($0) }
    activeRequests = activeRequests.filter { waiting.contains($0.key) }
    demandCache.retain(activeRequests)
    let hasBlockEdits = !editRegions.isEmpty
    let requests: [TerrainPreparationRequest] = waiting.map { tile in
      let revision = revisions[tile, default: 0]
      let id: TerrainWorkID
      if let active = activeRequests[tile], active.revision == revision {
        id = active // Finish an admitted vegetation upgrade even while moving.
      } else {
        requestIncarnation &+= 1
        id = .init(world: lifecycle, tile: tile, revision: revision,
          lush: tile.fullDetail && VegetationDetail.isLush(tile.coordinate, center: center,
            previouslyLush: lushTiles.contains(tile)), incarnation: requestIncarnation,
          repeatAtlas: tile.fullDetail && repeatingAtlas != nil, instanceSeats: stadiumSeats.enabled,
          profileSurface: projectedDetailEnabled)
        activeRequests[tile] = id
      }
      let service = ordering.services[tile] ?? .refinement, priority = ordering.ranks[tile] ?? 0
      return demandCache.request(id: id, service: service, priority: priority, cacheInputs: hasBlockEdits) {
        .init(id: id, terrain: generator, edits: hasBlockEdits ? edits(for: tile) : [:],
          plantEdits: plantChanges[tile.coordinate] ?? [:],
          cachedChunk: tile.fullDetail ? chunks[tile.coordinate] : nil,
          service: service, priority: priority)
      }
    }
    requestSequence &+= 1
    nativePublication.retain { isCurrent($0) }
    terrainExchange.expect(requests, sequence: requestSequence)
    terrainCoordinator.wake()
  }

  /// Keep the old coverage until all its replacements are ready. Children stay
  /// hidden behind an old parent, so movement never opens holes or z-fights.
  private func refreshCoverage() {
    PerformanceTrace.measure(.terrainCoverage) { resolveCoverage() }
  }

  private func resolveCoverage() {
    if incrementalTerrainCoverage {
      let changes = coverageTracker.resolve()
      for tile in changes.retired { remove(tile) }
      // remove() already consumes the visibility of retired resources. Only
      // surviving visibility changes need water toggles and frontier replanning.
      let hidden = changes.becameHidden.subtracting(changes.retired)
      for tile in hidden {
        entities[tile]?.isEnabled = false
        ocean.setVisible(tile, false)
      }
      for tile in changes.becameVisible {
        entities[tile]?.isEnabled = true
        ocean.setVisible(tile, true)
      }
      visibleTiles.subtract(hidden)
      visibleTiles.formUnion(changes.becameVisible)
      if !hidden.isEmpty || !changes.becameVisible.isEmpty { needsFrontier = true }
      return
    }
    let coverage = TerrainCoverage(desired: desired, available: Set(entities.keys))
    for tile in coverage.retired { remove(tile) }
    for tile in visibleTiles.symmetricDifference(coverage.visible) {
      let visible = coverage.visible.contains(tile)
      entities[tile]?.isEnabled = visible
      ocean.setVisible(tile, visible)
    }
    if visibleTiles != coverage.visible { needsFrontier = true }
    visibleTiles = coverage.visible
  }

  private func remove(_ tile: TerrainTile) {
    restoreDryRegion(tile)
    let began = CACurrentMediaTime()
    defer { removalTiming.record(seconds: CACurrentMediaTime() - began) }
    animatedEntities[tile] = nil
    seatInstanceCount -= seatCounts.removeValue(forKey: tile) ?? 0
    seatGroupCount -= seatEntities.removeValue(forKey: tile)?.count ?? 0
    visibleTiles.remove(tile)
    surfaceSources.remove(tile)
    dirtyTiles.remove(tile)
    wind.remove(tile)
    let allocation = terrainAllocations.removeValue(forKey: tile)
    let capacity = capacityBytes.removeValue(forKey: tile) ?? 0
    residentMeshCapacityBytes -= capacity
    if let entity = entities.removeValue(forKey: tile) {
      terrainResources.retire(entity, allocation: allocation, bytes: capacity)
      renderedChunkCount -= tile.size * tile.size
    }
    terrainTriangles -= triangleCounts.removeValue(forKey: tile) ?? 0
    terrainDrawParts -= renderParts.removeValue(forKey: tile) ?? 0
    residentMeshBytes -= meshBytes.removeValue(forKey: tile) ?? 0
    hazeVersions[tile] = nil
    hazeBands[tile] = nil
    lushTiles.remove(tile)
    ocean.remove(tile)
    fire.remove(tile); lamps.remove(tile)
    if tile.fullDetail {
      collisionChunks[tile.coordinate] = nil
      chunks[tile.coordinate] = nil
      plants[tile.coordinate] = nil
      loadedChunks.remove(tile.coordinate)
    }
  }

  func edit(_ p: BlockPosition, to block: Block) {
    let block = generator.waterSafeMaterial(block, at: p)
    worldRevision &+= 1
    edits[p] = block
    editRegions[p.chunk, default: [:]][p] = block
    if block.isLiquid {
      for offset in VoxelMesher.offsets {
        let adjacent = p + offset
        if self.block(at: adjacent) == .snow { edit(adjacent, to: .sand) }
      }
    }
    let affected = Set([
      p.chunk, (p + .init(-1, 0, 0)).chunk, (p + .init(1, 0, 0)).chunk,
      (p + .init(0, 0, -1)).chunk, (p + .init(0, 0, 1)).chunk,
    ])
    if projectedDetailEnabled { surfaceProfiles.invalidate(affected); invalidateRefinementPlan() }
    for tile in desired where affected.contains(where: { tile.contains($0) }) {
      cancelPreparation(tile)
      revisions[tile, default: 0] += 1
      if var chunk = chunks[tile.coordinate], tile.fullDetail {
        chunk[p.x - tile.x * 16, p.y, p.z - tile.z * 16] = block
        chunks[tile.coordinate] = chunk
      }
      // The old mesh stays visible while this revision is built.
      dirtyTiles.insert(tile)
    }
    if let lastCenter { rebuildWorkQueue(center: lastCenter) }
  }

  /// One revision and one queue rebuild per crush batch, one COW chunk copy per
  /// affected chunk. Never launch hundreds of remesh jobs for a single stride.
  func trample(_ blocks:[CrushedBlock],plants removed:[PlantEdit]) {
    guard !blocks.isEmpty || !removed.isEmpty else { return }
    worldRevision &+= 1
    var affected=Set<ChunkCoordinate>()
    var updates:[ChunkCoordinate:Set<BlockPosition>] = [:]
    for crushed in blocks {
      let p=crushed.position
      edits[p] = .air; editRegions[p.chunk,default:[:]][p] = .air
      for d in [BlockPosition(0,0,0),.init(-1,0,0),.init(1,0,0),.init(0,0,-1),.init(0,0,1)] {
        let chunk=(p+d).chunk
        updates[chunk,default:[]].insert(p)
        affected.insert(chunk)
      }
    }
    for (coordinate,points) in updates {
      if var chunk=chunks.removeValue(forKey:coordinate) {
        for p in points { chunk[p.x-coordinate.x*16,p.y,p.z-coordinate.z*16] = .air }
        chunks[coordinate]=chunk
      }
      if var chunk=collisionChunks.removeValue(forKey:coordinate) {
        for p in points { chunk[p.x-coordinate.x*16,p.y,p.z-coordinate.z*16] = .air }
        collisionChunks[coordinate]=chunk
      }
    }
    for edit in removed {
      plantChanges[edit.position.chunk,default:[:]][edit.position]=edit
      plants[edit.position.chunk]?.removeAll { $0.position == edit.position }
      affected.insert(edit.position.chunk)
    }
    if projectedDetailEnabled { surfaceProfiles.invalidate(affected); invalidateRefinementPlan() }
    for tile in desired where affected.contains(where:{tile.contains($0)}) {
      cancelPreparation(tile)
      revisions[tile,default:0] += 1; dirtyTiles.insert(tile)
    }
    if let lastCenter { rebuildWorkQueue(center:lastCenter) }
  }

  private func edits(for tile: TerrainTile) -> [BlockPosition: Block] {
    if tile.fullDetail {
      var result: [BlockPosition: Block] = [:]
      for z in (tile.z - 1)...(tile.z + 1) {
        for x in (tile.x - 1)...(tile.x + 1) {
          for (p, block) in editRegions[.init(x, z)] ?? [:] { result[p] = block }
        }
      }
      return result
    }
    var result: [BlockPosition: Block] = [:]
    for (coordinate, edits) in editRegions where tile.contains(coordinate) {
      for (p, block) in edits { result[p] = block }
    }
    return result
  }

  private func cancelPreparation(_ tile: TerrainTile) {
    if tile.fullDetail { collisionChunks[tile.coordinate] = nil }
    terrainExchange.invalidate(tile)
    activeRequests[tile] = nil
    nativePublication.retain { $0.tile != tile }
    demandCache.invalidate(tile)
  }

  private func install(_ result: PreparedTerrainTile, prepared: TerrainPreparedMeshes? = nil) {
    let trace = PerformanceTrace.begin("Install terrain tile")
    defer { PerformanceTrace.end("Install terrain tile", trace) }
    let tile = result.tile
    guard isCurrent(result.id) else {
      if let prepared { terrainResources.discard(prepared) }
      return
    }
    defer { cancelPreparation(tile) }
    let entity = Entity()
    var allocation = prepared?.allocation
    var installed = false
    let instanceBytes = result.stadiumSeats.count * StadiumSeatInstance.transformBytes
    defer {
      if !installed {
        terrainResources.retire(entity, allocation: allocation,
          bytes: (allocation?.capacity.bytes ?? 0) + (result.animated?.byteCount ?? 0) + instanceBytes)
      }
    }
    do {
      entity.isEnabled = visibleTiles.contains(tile)
      let band = hazeBand(tile, eye: hazeEye)
      if !result.mesh.vertices.isEmpty {
        let acquired = try prepared?.allocation ?? terrainResources.acquire(result.mesh)
        allocation = acquired
        entity.components.set(
          ModelComponent(
            mesh: acquired.resource,
            materials: tile.fullDetail || tile.retainsBlockSurface ? hazeMaterials[band] : distantMaterials[band]))
      }
      var animation: (entity: Entity, mesh: LowLevelMesh, count: Int)?
      if let animated = result.animated, !animated.vertices.isEmpty {
        let moving = Entity()
        let mesh: LowLevelMesh, resource: MeshResource
        if let native = prepared?.animation {
          mesh = native.mesh; resource = native.resource
        } else {
          mesh = try TerrainMeshResource.makeLowLevel(animated)
          resource = try MeshResource(from: mesh)
        }
        moving.components.set(ModelComponent(mesh: resource, materials: hazeMaterials[band]))
        entity.addChild(moving)
        animation = (moving, mesh, animated.vertices.count)
      }
      let seats = try stadiumSeats.attach(result.stadiumSeats, repeatAtlas: result.id.repeatAtlas,
        materials: hazeMaterials[band], to: entity)
      // Water packs on its actor and retains its previous LOD coverage until
      // all replacement batches are ready, independently of terrain uploads.
      try ocean.install(result.water, tile: tile, root: root, environment: environment)
      // Commit only after throwing work succeeds, retaining the old animation
      // and visible tile if resource creation fails. Wind meshes are never pooled.
      restoreDryRegion(tile)
      wind.remove(tile)
      animatedEntities[tile] = animation?.entity
      if !seats.isEmpty || seatCounts[tile] != nil {
        seatInstanceCount += result.stadiumSeats.count - (seatCounts[tile] ?? 0)
        seatGroupCount += seats.count - (seatEntities[tile]?.count ?? 0)
        seatCounts[tile] = seats.isEmpty ? nil : result.stadiumSeats.count
        seatEntities[tile] = seats.isEmpty ? nil : seats
      }
      if let animation {
        wind.register(tile, mesh: animation.mesh, count: animation.count,
          admissionVertexCount: result.windAdmissionVertexCount, entity: entity)
      }
      fire.install(tile, positions: result.fires)
      lamps.install(tile, positions: result.lamps)
      entity.position = tile.origin
      entity.name = tile.fullDetail ? "Voxel chunk" : "Horizon tile \(tile.size)"
      if let previous = entities.removeValue(forKey: tile) {
        terrainResources.retire(previous, allocation: terrainAllocations[tile], bytes: capacityBytes[tile] ?? 0)
      }
      else { renderedChunkCount += tile.size * tile.size }
      entities[tile] = entity
      terrainAllocations[tile] = allocation
      let capacity = (allocation?.capacity.bytes ?? 0) + (result.animated?.byteCount ?? 0) + instanceBytes
      residentMeshCapacityBytes += capacity - (capacityBytes[tile] ?? 0)
      capacityBytes[tile] = capacity
      dirtyTiles.remove(tile)
      if result.lush { lushTiles.insert(tile) } else { lushTiles.remove(tile) }
      if !tile.fullDetail { entity.components.set(DynamicLightShadowComponent(castsShadow: false)) }
      hazeBands[tile] = band
      let triangles = (result.mesh.indices.count + (result.animated?.indices.count ?? 0)) / 3
        + result.stadiumSeats.count * StadiumSeatInstance.triangleCount
      let parts = result.mesh.parts.count + (result.animated?.parts.count ?? 0) + seats.count
      terrainTriangles += triangles - (triangleCounts[tile] ?? 0)
      terrainDrawParts += parts - (renderParts[tile] ?? 0)
      triangleCounts[tile] = triangles
      renderParts[tile] = parts
      let bytes = result.mesh.byteCount + (result.animated?.byteCount ?? 0) + instanceBytes
      residentMeshBytes += bytes - (meshBytes[tile] ?? 0)
      meshBytes[tile] = bytes
      hazeVersions[tile] = hazeRevision
      if let chunk = result.chunk {
        chunks[tile.coordinate] = chunk
        plants[tile.coordinate] = result.plants
        loadedChunks.insert(tile.coordinate)
      }
      terrainRoot.addChild(entity)
      surfaceSources.install(id: result.id, grid: result.surfaceGrid)
      if projectedDetailEnabled, let profile = result.surfaceProfile {
        surfaceProfiles.insert(profile, for: tile); refinementNeedsUpdate = true
      }
      installed = true
      if incrementalTerrainCoverage { coverageTracker.insert(tile) }
      if tile.fullDetail, let center = lastViewerCenter,
        VegetationDetail.isLush(tile.coordinate, center: center, previouslyLush: result.lush) != result.lush
      {
        dirtyTiles.insert(tile)
        queueNeedsRebuild = true
      }
    } catch { handleTerrainFailure(error) }
  }

  private func handleTerrainFailure(_ error: Error) {
    if error is StadiumSeatRenderer.Failure {
      // Rebuild all extracted seats through the baked path, including pending
      // jobs. Previously visible tiles survive until replacements succeed.
      stadiumSeats.disable()
      for candidate in desired where candidate.fullDetail {
        revisions[candidate, default: 0] += 1
        if entities[candidate] != nil { dirtyTiles.insert(candidate) }
        cancelPreparation(candidate)
      }
      print("WORLDCRAFT_TERRAIN seats=baked reason=\(error)")
    }
    queueNeedsRebuild = true
    onError?("Could not render terrain: \(error.localizedDescription)")
  }

  func showSelection(_ hit: RayHit?) {
    showMining(center: hit?.block.center, size: .init(repeating: 1), progress: 0, solid: true)
  }
  func showMining(center: SIMD3<Float>?, size: SIMD3<Float>, progress: Float, solid: Bool) {
    let enabled = center != nil
    if selection.isEnabled != enabled { selection.isEnabled = enabled }
    if let center {
      if selection.position != center { selection.position = center }
      if selection.scale != size { selection.scale = size }
    }
    fractures.isEnabled = enabled && solid && progress > 0
    if let center, fractures.position != center { fractures.position = center }
    let stage = min(4, Int(progress * 5))
    if fractureStage != stage {
      fractures.children.removeAll(); fractureStage = stage
      if fractureModels[stage] == nil {
        let model = Entity()
        let builder = SculptureBuilder(materials: [UnlitMaterial(color: UIColor(white: 0.08, alpha: 1))])
        for face in 0..<6 { for i in 0..<(2 + stage * 3) {
          let axis = face / 2, a = (axis + 1) % 3, b = (axis + 2) % 3
          var point = SIMD3<Float>.zero, size = SIMD3<Float>(repeating: 0.007)
          point[axis] = face % 2 == 0 ? 0.503 : -0.503
          point[a] = Float((i * 7) % 11 - 5) * 0.075
          point[b] = Float((i * 3) % 9 - 4) * 0.082
          size[i % 2 == 0 ? a : b] = 0.14
          builder.box(size, point, 0, parent: model)
        } }
        builder.finish(); fractureModels[stage] = model
      }
      if let model = fractureModels[stage] { fractures.addChild(model) }
    }
  }

  func restorePlants(_ edits: [PlantEdit]) {
    worldRevision &+= 1
    plantChanges = Dictionary(grouping: edits.filter(\.isValid), by: { $0.position.chunk }).mapValues {
      Dictionary($0.map { ($0.position, $0) }, uniquingKeysWith: { _, last in last })
    }
  }
  func plant(at p: BlockPosition) -> PlantInstance? { plants[p.chunk]?.first { $0.position == p } }
  func nearbyPlants(_ point: SIMD3<Float>) -> [PlantInstance] {
    let cell = BlockPosition(point).chunk
    var result: [PlantInstance] = []
    for z in (cell.z - 2)...(cell.z + 2) { for x in (cell.x - 2)...(cell.x + 2) {
      for plant in plants[.init(x, z)] ?? [] where simd_distance_squared(plant.center, point) < 24 * 24 {
        result.append(plant)
      }
    } }
    return result
  }
  func plant(overlapping position: BlockPosition) -> PlantInstance? {
    let cell = position.chunk
    for z in (cell.z - 1)...(cell.z + 1) { for x in (cell.x - 1)...(cell.x + 1) {
      if let plant = plants[.init(x, z)]?.first(where: { $0.overlaps(position) }) { return plant }
    } }
    return nil
  }
  func editPlant(_ edit: PlantEdit) {
    worldRevision &+= 1
    let p = edit.position
    plantChanges[p.chunk, default: [:]][p] = edit
    plants[p.chunk]?.removeAll { $0.position == p }
    if let kind = edit.kind { plants[p.chunk, default: []].append(.init(position: p, kind: kind)) }
    let tile = TerrainTile(x: p.chunk.x, z: p.chunk.z, size: 1, fullDetail: true)
    cancelPreparation(tile)
    revisions[tile, default: 0] += 1; dirtyTiles.insert(tile)
    if let lastCenter { rebuildWorkQueue(center: lastCenter) }
  }
  func targetPlant(eye: SIMD3<Float>, direction: SIMD3<Float>, reach: Float) -> (PlantInstance, Float)? {
    let cell = BlockPosition(eye).chunk
    var nearest: (PlantInstance, Float)?
    for z in (cell.z - 1)...(cell.z + 1) { for x in (cell.x - 1)...(cell.x + 1) {
      for plant in plants[.init(x, z)] ?? [] {
        if let d = plant.hitDistance(origin: eye, direction: direction, reach: nearest?.1 ?? reach) { nearest = (plant, d) }
      }
    } }
    return nearest
  }

  private func buildSelection() {
    selection.children.removeAll()
    let material = UnlitMaterial(color: UIColor(red: 1, green: 0.91, blue: 0.59, alpha: 1))
    let builder = SculptureBuilder(materials: [material])
    for axis in 0..<3 {
      for a: Float in [-0.505, 0.505] {
        for b: Float in [-0.505, 0.505] {
          var size = SIMD3<Float>(repeating: 0.009)
          size[axis] = 1.02
          var position = SIMD3<Float>.zero
          position[(axis + 1) % 3] = a
          position[(axis + 2) % 3] = b
          builder.box(size, position, 0, parent: selection)
        }
      }
    }
    builder.finish()
  }

  func updateEnvironment(
    _ environment: WorldEnvironment, deltaTime: Float, player: SIMD3<Float>,
    frame: PlayerFrame, trackedPosition: SIMD3<Float>, trackedForward: SIMD3<Float>
  ) {
    self.environment = environment
    let eye = frame.worldPoint(fromTracked: trackedPosition)
    if deltaTime <= 0 && lifeActive { suspendLife() }
    if deltaTime > 0 { lifeActive = true }
    PerformanceTrace.measure(.sky) { atmosphere.update(
      environment: environment, eye: eye, worldRotation: frame.trackingFromWorldRotation,
      trackedPosition: trackedPosition) }
    PerformanceTrace.measure(.terrainHaze) { updateHaze(eye: eye) }
    let waterView = RenderDiagnostics.current.cullRearWaterAnimation
      ? WaterAnimationSchedule.View(eye: eye, forward: frame.worldDirection(fromTracked: trackedForward)) : nil
    PerformanceTrace.measure(.water) { ocean.update(environment, eye: eye, style: generator.style, view: waterView) }
    // Water publishes independently after stream(). Revalidate before rendering
    // this frame rather than showing a region with an obsolete fluid lease.
    hazeEye = eye
    validateDryRegions()
    let weather = WorldWeather.sample(seed: generator.seed, time: environment.elapsed, style: generator.style)
    PerformanceTrace.measure(.lamps) {
      lamps.update(time:environment.elapsed,eye:eye,daylight:environment.daylight,root:root,block:actorBlock)
    }
    PerformanceTrace.measure(.fire) {
      fire.update(time: environment.elapsed, eye: eye, weather: weather, terrain: generator, root: root,
        paused: deltaTime <= 0, block: actorBlock)
    }
    PerformanceTrace.measure(.vegetationWind) {wind.update(time:environment.elapsed,eye:eye,seed:generator.seed,weather:weather)}
    PerformanceTrace.measure(.precipitation) { precipitation.update(weather: weather, time: environment.elapsed, eye: eye,
      loaded: loadedChunks, terrain: generator, block: actorBlock) }
    wildlife.setCompanionCarrier(vehicles.companionCarrier ?? boats.companionCarrier, ids:hayHayIDs) { carrier in
      switch carrier.kind {
      case .car: return vehicles.companionCarrier(for:carrier.id)
      case .boat: return boats.companionCarrier(for:carrier.id)
      }
    }
    doors.update(site:settlementLife.currentSite,terrain:generator,root:root,player:player,
      people:settlementLife.positions,animals:wildlife.simulationStates,time:environment.elapsed,seconds:deltaTime,block:block)
    PerformanceTrace.measure(.lifeSnapshot) { updateLife(deltaTime: deltaTime, player: player, environment: environment) }
    PerformanceTrace.measure(.actorPresentation) {
    wildlife.update(
      deltaTime: deltaTime, time: environment.elapsed, player: player, root: root,
      loaded: loadedChunks, site: settlementLife.currentSite, block: actorBlock)
    dinosaurs.update(
      deltaTime: deltaTime, time: environment.elapsed, player: player,
      terrain: generator, loaded: loadedChunks, root: root, drawRadius: lastRadius, block: actorBlock)
    settlementLife.update(
      terrain: generator, player: player, deltaTime: deltaTime, environment: environment,
      threats: dinosaurs.threatPositions, root: root, loaded: loadedChunks, block: actorBlock)
    vehicles.update(site: settlementLife.currentSite, terrain: generator, root: root, player: player,
      deltaTime: deltaTime, loaded: loadedChunks, obstacles: settlementLife.positions + wildlife.dogPositions,
      daylight: environment.daylight, block: actorBlock)
    if let giant=dinosaurs.simulationStates.giant?.state {
      if let previous=previousGiantPosition {vehicles.crush(from:previous,to:giant.position,radius:giant.footprint)}
      previousGiantPosition=giant.position
    } else {previousGiantPosition=nil}
    boats.update(terrain:generator,root:root,player:player,environment:environment,seconds:deltaTime)
    sports.update(terrain:generator,player:player,root:root,seconds:deltaTime,block:actorBlock)
    }
  }

  func updateLife(deltaTime: Float, player: SIMD3<Float>, environment: WorldEnvironment) {
    life.presentation.time = environment.elapsed
    life.tick(seconds: deltaTime) { seconds in
      .init(world: .init(terrain: generator, chunks: chunks, plants: plants,
        obstacle: entityObstacleSnapshot?(), revision: worldRevision, doors: doors.snapshots),
        environment: environment, player: player, seconds: seconds,
        animals: wildlife.snapshots(time: environment.elapsed) + dinosaurs.snapshots,
        wildlife: wildlife.simulationStates, threats: dinosaurs.threatPositions,
        offering: wildlife.offering, flying: life.presentation.flying, driving: life.presentation.driving,
        logs: life.presentation.logs, dinosaurs: dinosaurs.simulationStates, drawRadius: lastRadius, traffic: vehicles.trafficSnapshot(), mount: mount, hayHayIDs: hayHayIDs, hiddenCastleHayHay: hiddenCastleHayHay,
        companionCarrier:wildlife.companionCarrier)
    }
  }

  private func hazeBand(_ tile: TerrainTile, eye: SIMD3<Float>) -> Int {
    let center = tile.center + [0, eye.y, 0]
    return min(
      20,
      Int(
        AtmosphericPerspective.strength(distance: simd_distance(center, eye), altitude: eye.y) * 20)
    )
  }

  private func makeHazeBand(_ band: Int, color: SIMD3<Float>) -> ([any Material], [any Material]) {
    let amount = Float(band) / 20
    let near = materials.enumerated().map { index, original -> any Material in
      if index == 6, let repeatingAtlas {
        return (try? repeatingAtlas.band(band, color: color)) ?? repeatingAtlas.surface
      }
      guard band > 0, var material = original as? PhysicallyBasedMaterial else { return original }
      material.baseColor = .init(tint: UIColor(white: CGFloat(1 - amount), alpha: 1), texture: material.baseColor.texture)
      let glow = index == 3 ? SIMD3<Float>(1, 0.72, 0.30) * (1 - amount) + color * (amount / 1.3) : color * amount
      material.emissiveColor = .init(color: UIColor(red: CGFloat(glow.x), green: CGFloat(glow.y), blue: CGFloat(glow.z), alpha: 1))
      material.emissiveIntensity = index == 3 ? 1.3 : 1
      return material
    }
    let far = near.map { original -> any Material in
      guard var material = original as? PhysicallyBasedMaterial else { return original }
      material.baseColor = .init(tint: material.baseColor.tint, texture: distantTexture)
      material.normal = .init(); material.ambientOcclusion = .init()
      material.blending = .opaque; material.faceCulling = .back
      material.roughness = .init(floatLiteral: 1); material.specular = .init(floatLiteral: 0)
      return material
    }
    return (near, far)
  }

  private func rebuildHazeMaterials() {
    hazeColor = AtmosphericPerspective.color(environment: environment, style: generator.style)
    let bands = (0...20).map { makeHazeBand($0, color: hazeColor) }
    hazeMaterials = bands.map(\.0); distantMaterials = bands.map(\.1)
  }

  func consumeRenderingTiming() -> (haze: DurationTiming.Snapshot, upload: DurationTiming.Snapshot,
    removal: DurationTiming.Snapshot, resources: TerrainRenderResources.Metrics) {
    defer { hazeTiming.reset(); uploadTiming.reset(); removalTiming.reset() }
    return (hazeTiming.snapshot, uploadTiming.snapshot, removalTiming.snapshot, terrainResources.consumeMetrics())
  }

  private func updateHaze(eye: SIMD3<Float>) {
    let start = CACurrentMediaTime()
    defer { hazeTiming.record(seconds: CACurrentMediaTime() - start) }
    hazeEye = eye
    let color = AtmosphericPerspective.color(environment: environment, style: generator.style)
    if pendingHazeColor == nil && simd_distance(color, hazeColor) > 0.025 { pendingHazeColor = color }
    // Material constructors/component writes stay on MainActor. One palette
    // band per frame prevents day/night changes from rebuilding 252 materials
    // and touching every terrain entity in the same frame.
    if let color = pendingHazeColor {
      let band = makeHazeBand(nextHazeMaterials.count, color: color)
      nextHazeMaterials.append(band.0); nextDistantMaterials.append(band.1)
      if nextHazeMaterials.count == 21 {
        hazeMaterials = nextHazeMaterials; distantMaterials = nextDistantMaterials
        nextHazeMaterials = []; nextDistantMaterials = []; pendingHazeColor = nil
        hazeColor = color; hazeRevision += 1; lastHazeUpdate = -.infinity
      }
    }
    if hazeCursor >= hazeQueue.count && environment.elapsed - lastHazeUpdate >= 0.25 {
      lastHazeUpdate = environment.elapsed
      hazeQueue = Array(entities.keys); hazeCursor = 0
    }
    var visited = 0
    while hazeCursor < hazeQueue.count && visited < 48 && CACurrentMediaTime() - start < 0.0004 {
      let tile = hazeQueue[hazeCursor]; hazeCursor += 1; visited += 1
      guard let entity = entities[tile] else { continue }
      let band = hazeBand(tile, eye: eye)
      guard hazeVersions[tile] != hazeRevision || hazeBands[tile] != band else { continue }
      let palette = tile.fullDetail || tile.retainsBlockSurface ? hazeMaterials[band] : distantMaterials[band]
      func updateMaterial(_ target: Entity) {
        if var model = target.components[ModelComponent.self] {
          model.materials = palette; target.components.set(model)
        }
      }
      for target in [entity, animatedEntities[tile]].compactMap({ $0 }) { updateMaterial(target) }
      if let seats = seatEntities[tile] { for target in seats { updateMaterial(target) } }
      hazeBands[tile] = band; hazeVersions[tile] = hazeRevision
    }
  }
}
