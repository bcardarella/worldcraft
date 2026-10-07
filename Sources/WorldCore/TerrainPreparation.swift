import Foundation

public enum TerrainWorkClass: String, CaseIterable, Sendable, Encodable {
  case collision, coverage, detail, refinement
}

public struct TerrainWorkID: Hashable, Sendable {
  public let world: UUID
  public let tile: TerrainTile
  public let revision: Int
  public let lush: Bool
  public let repeatAtlas: Bool
  public let instanceSeats: Bool
  public let profileSurface: Bool
  public let incarnation: UInt64
  public init(world: UUID, tile: TerrainTile, revision: Int, lush: Bool, incarnation: UInt64 = 0,
    repeatAtlas: Bool = false, instanceSeats: Bool = false, profileSurface: Bool = false) {
    self.world = world; self.tile = tile; self.revision = revision; self.lush = lush
    self.incarnation = incarnation
    self.repeatAtlas = repeatAtlas
    self.instanceSeats = instanceSeats && tile.fullDetail
    self.profileSurface = profileSurface && !tile.fullDetail
  }
}

public struct TerrainPreparationRequest: Sendable {
  public let id: TerrainWorkID
  public let terrain: TerrainGenerator
  public let edits: [BlockPosition: Block]
  public let plantEdits: [BlockPosition: PlantEdit]
  public let cachedChunk: ChunkData?
  public let service: TerrainWorkClass
  public let priority: Int
  public init(id: TerrainWorkID, terrain: TerrainGenerator,
    edits: [BlockPosition: Block] = [:], plantEdits: [BlockPosition: PlantEdit] = [:],
    cachedChunk: ChunkData? = nil, service: TerrainWorkClass, priority: Int) {
    self.id = id; self.terrain = terrain; self.edits = edits; self.plantEdits = plantEdits
    self.cachedChunk = cachedChunk; self.service = service; self.priority = priority
  }
}

public struct PreparedTerrainTile: Sendable {
  public let id: TerrainWorkID
  public var tile: TerrainTile { id.tile }
  public var revision: Int { id.revision }
  public var lush: Bool { id.lush }
  public let chunk: ChunkData?
  public let mesh: PackedTerrainMesh
  public let animated: PackedTerrainMesh?
  public let windAdmissionVertexCount: Int
  public let stadiumSeats: [StadiumSeatInstance]
  public let water: WaterGeometry
  public let surfaceProfile: TerrainSurfaceProfile?
  public let surfaceGrid: TerrainSurfaceGrid?
  public let plants: [PlantInstance]
  public let lamps: [SIMD3<Float>]
  public let fires: [SIMD3<Float>]
  public let stages: [String: Double]
  public let readyAt: Double
  public var byteCount: Int {
    mesh.byteCount + (animated?.byteCount ?? 0)
      + (surfaceProfile == nil ? 0 : MemoryLayout<TerrainSurfaceProfile>.stride)
      + (surfaceGrid?.byteCount ?? 0)
      + water.samples.count * MemoryLayout<WaterGeometry.Sample>.stride
      + (water.shallowIndices.count + water.deepIndices.count) * 4
      + (chunk == nil ? 0 : 18 * 18 * (ChunkData.height - ChunkData.minimumY))
      + plants.count * MemoryLayout<PlantInstance>.stride
      + (lamps.count + fires.count) * MemoryLayout<SIMD3<Float>>.stride
      + stadiumSeats.count * max(MemoryLayout<StadiumSeatInstance>.stride, StadiumSeatInstance.transformBytes)
  }
  /// CPU input plus the maximum admitted native mesh capacity. A pooled static
  /// allocation may be up to 1.5 times its requested capacity class. Animated
  /// meshes use exact capacity and are never pooled. Excludes framework copies.
  public func publicationByteCount(reuseMeshes: Bool) -> Int {
    let demand = TerrainMeshCapacity(vertices: mesh.vertices.count, indices: mesh.indices.count, rounded: reuseMeshes)
    let staticBytes = mesh.vertices.isEmpty ? 0 : (reuseMeshes ? demand.bytes * 3 / 2 : demand.bytes)
    return byteCount + staticBytes + (animated?.byteCount ?? 0)
  }
  public init(id: TerrainWorkID, chunk: ChunkData? = nil, mesh: PackedTerrainMesh,
    animated: PackedTerrainMesh? = nil, windAdmissionVertexCount: Int = 0,
    stadiumSeats: [StadiumSeatInstance] = [],
    surfaceProfile: TerrainSurfaceProfile? = nil, surfaceGrid: TerrainSurfaceGrid? = nil,
    water: WaterGeometry = .init(), plants: [PlantInstance] = [],
    lamps: [SIMD3<Float>] = [], fires: [SIMD3<Float>] = [], stages: [String: Double] = [:]) {
    self.id = id; self.chunk = chunk; self.mesh = mesh; self.animated = animated
    self.windAdmissionVertexCount = windAdmissionVertexCount; self.water = water
    self.stadiumSeats = stadiumSeats; self.surfaceProfile = surfaceProfile; self.surfaceGrid = surfaceGrid
    self.plants = plants; self.lamps = lamps; self.fires = fires; self.stages = stages
    readyAt = ProcessInfo.processInfo.systemUptime
  }
  func reissued(id: TerrainWorkID, stages: [String: Double]) -> Self {
    .init(id: id, chunk: chunk, mesh: mesh, animated: animated,
      windAdmissionVertexCount: windAdmissionVertexCount, stadiumSeats: stadiumSeats, surfaceProfile: surfaceProfile,
      surfaceGrid: surfaceGrid, water: water,
      plants: plants, lamps: lamps, fires: fires, stages: stages)
  }
}

/// Pure bulk computation. The collision callback puts a value in a bounded
/// mailbox; it never waits for MainActor or for a rendering resource.
public enum TerrainPreparation {
  public static let indexedWindPartition = !ProcessInfo.processInfo.arguments.contains("--hashed-terrain-wind-partition")
  private static let cache = TerrainPayloadCache(baseBytes:
    ProcessInfo.processInfo.arguments.contains("--rebuild-terrain-base") ? 0 : 32 * 1_024 * 1_024)
  public static var cacheMetrics: TerrainPayloadCacheMetrics { cache.metrics }
  public static var baseCacheMetrics: TerrainBaseCacheMetrics { cache.base?.metrics ?? .init() }
  public static var diskCacheMetrics: TerrainDiskCacheMetrics { TerrainDiskCache.shared.snapshot }

  public static func prepare(_ request: TerrainPreparationRequest,
    collision: @Sendable (ChunkData) -> Void) async -> PreparedTerrainTile? {
    await prepare(request, cache: cache, disk: .shared, collision: collision)
  }
  static func prepare(_ request: TerrainPreparationRequest, cache: TerrainPayloadCache,
    disk: TerrainDiskCache, collision: @Sendable (ChunkData) -> Void) async -> PreparedTerrainTile? {
    guard !Task.isCancelled else { return nil }
    let began = ProcessInfo.processInfo.systemUptime, key = TerrainPayloadKey(request)
    // Explicit voxel snapshots always win over derived procedural caches.
    if request.cachedChunk == nil {
      if let cached = cache.value(for: key) {
        guard !Task.isCancelled else { return nil }
        if let chunk = cached.chunk { collision(chunk) }
        return cached.reissued(id: request.id,
          stages: ["memory_cache_hit": ProcessInfo.processInfo.systemUptime - began])
      }
      if let cached = await disk.value(for: key, id: request.id) {
        guard !Task.isCancelled else { return nil }
        cache.insert(cached, for: key)
        if let chunk = cached.chunk { collision(chunk) }
        return cached.reissued(id: request.id,
          stages: ["disk_cache_hit": ProcessInfo.processInfo.systemUptime - began])
      }
    }
    guard !Task.isCancelled else { return nil }
    let stages = ["cache_lookup": ProcessInfo.processInfo.systemUptime - began]
    guard let result = generate(request, cache: cache, key: key, stages: stages, collision: collision) else { return nil }
    if request.cachedChunk == nil { disk.enqueue(result, key: key) }
    return result
  }

  /// Synchronous CPU/memory path for tools and callers with authoritative voxel
  /// snapshots. Streaming uses prepare(), which can reuse persisted payloads.
  public static func build(_ request: TerrainPreparationRequest,
    collision: @Sendable (ChunkData) -> Void) -> PreparedTerrainTile? {
    build(request, cache: cache, cullHidden: true, collision: collision)
  }
  // Tools can use isolated cold caches to compare the scalar and masked
  // traversals. Their byte-identical output intentionally shares cache keys.
  static func build(_ request: TerrainPreparationRequest, cache: TerrainPayloadCache,
    cullHidden: Bool, collision: @Sendable (ChunkData) -> Void) -> PreparedTerrainTile? {
    let began = ProcessInfo.processInfo.systemUptime
    guard !Task.isCancelled else { return nil }
    let key = TerrainPayloadKey(request)
    // A supplied voxel snapshot may contain unpublished/transient changes.
    // Its cells, rather than the procedural key, remain authoritative.
    if request.cachedChunk == nil, let cached = cache.value(for: key) {
      if let chunk = cached.chunk { collision(chunk) }
      return cached.reissued(id: request.id,
        stages: ["memory_cache_hit": ProcessInfo.processInfo.systemUptime - began])
    }
    return generate(request, cache: cache, key: key,
      stages: ["cache_lookup": ProcessInfo.processInfo.systemUptime - began],
      cullHidden: cullHidden, collision: collision)
  }
  private static func generate(_ request: TerrainPreparationRequest, cache: TerrainPayloadCache,
    key: TerrainPayloadKey, stages initial: [String: Double],
    cullHidden: Bool = true,
    collision: @Sendable (ChunkData) -> Void) -> PreparedTerrainTile? {
    var stages = initial, began = ProcessInfo.processInfo.systemUptime
    func stage(_ name: String) {
      let now = ProcessInfo.processInfo.systemUptime
      stages[name] = now - began; began = now
    }
    let tile = request.id.tile
    let data: ChunkData?
    let mesh: VoxelMesh
    let water: WaterGeometry
    let surfaceProfile: TerrainSurfaceProfile?
    let surfaceGrid: TerrainSurfaceGrid?
    let plants: [PlantInstance]
    if tile.fullDetail {
      surfaceProfile = nil; surfaceGrid = nil
      let chunk = request.cachedChunk ?? request.terrain.generate(tile.coordinate, edits: request.edits)
      stage("generation")
      guard !Task.isCancelled else { return nil }
      collision(chunk)
      let baseKey = TerrainBaseKey(key)
      let base = cache.base?.value(for: baseKey, chunk: chunk)
      if cache.base != nil { stage(base == nil ? "base_cache_lookup" : "base_cache_hit") }
      var full: VoxelMesh
      if let base { full = base.mesh }
      else {
        full = VoxelMesher.build(chunk, includeWater: false, repeatAtlas: request.id.repeatAtlas, cullHidden: cullHidden)
        stage("meshing")
        full.append(SportsGroundMesher.build(tile, terrain: request.terrain, edits: request.edits,
          instanceSeats: request.id.instanceSeats))
      }
      // Admit the locally lush base only. Keeping it separate before append
      // preserves exact quad/index order and every material/animation attribute.
      let reusableMesh = base == nil && cache.base != nil && request.id.lush ? full : nil
      plants = SurfaceDecorationMesher.instances(in: chunk, terrain: request.terrain,
        lush: request.id.lush, changes: request.plantEdits)
      full.append(SurfaceDecorationMesher.mesh(plants, chunk: tile.coordinate))
      stage("decoration")
      data = chunk; mesh = full
      water = base?.water ?? .init(WaterPatch.build(chunk, terrain: request.terrain))
      stage("water_preparation")
      if let reusableMesh, !Task.isCancelled {
        cache.base?.insert(.init(chunk: chunk, mesh: reusableMesh, water: water), for: baseKey)
        stage("base_cache_insert")
      }
    } else {
      let surface = TerrainSurface.buildRetained(tile, terrain: request.terrain, edits: request.edits, measureError: request.id.profileSurface)
      data = nil; plants = []; mesh = surface.mesh; water = surface.water; surfaceProfile = surface.profile
      surfaceGrid = surface.grid
      stage("surface")
    }
    guard !Task.isCancelled else { return nil }
    let packed = PackedTerrainMesh(mesh, repeatOpaqueAtlas: tile.fullDetail && request.id.repeatAtlas)
    stage("packing")
    guard !Task.isCancelled else { return nil }
    let split = tile.fullDetail ? packed.separatingWind(indexed: indexedWindPartition) : (stationary: packed, animated: nil)
    stage("wind_partition")
    let result = PreparedTerrainTile(id: request.id, chunk: data, mesh: split.stationary, animated: split.animated,
      // Instancing static seats must not expand the existing wind admission
      // budget or change which vegetation animates in a matched comparison.
      windAdmissionVertexCount: packed.vertices.count + mesh.stadiumSeats.count * StadiumSeatInstance.vertexCount,
      stadiumSeats: mesh.stadiumSeats, surfaceProfile: surfaceProfile, surfaceGrid: surfaceGrid, water: water, plants: plants,
      lamps: mesh.lampPositions, fires: mesh.firePositions, stages: stages)
    guard !Task.isCancelled else { return nil }
    if request.cachedChunk == nil { cache.insert(result, for: key) }
    return result
  }
}
