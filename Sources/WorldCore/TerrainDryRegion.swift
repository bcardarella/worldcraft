import Foundation

/// A complete, conservative first regional replacement. Only a whole, dry
/// surface leaf is replaced, retaining its original outer border. Wet boundaries,
/// crossing scenery and exposed cave caps retain their existing representation;
/// no partial mesh is publishable.
public enum TerrainDryRegion {
  public struct Request: Sendable {
    public let token = UUID()
    public let source: TerrainWorkID
    public let revision: UInt64
    public let terrain: TerrainGenerator
    public let ground: TerrainSurfaceSources.Snapshot
    public let water: WaterSurfaceSources.Snapshot
    public let edits: [BlockPosition: Block]
    public let plants: [BlockPosition: PlantEdit]
    public init(source: TerrainWorkID, revision: UInt64, terrain: TerrainGenerator,
      ground: TerrainSurfaceSources.Snapshot, water: WaterSurfaceSources.Snapshot,
      edits: [BlockPosition: Block], plants: [BlockPosition: PlantEdit] = [:]) {
      self.source = source; self.revision = revision; self.terrain = terrain
      self.ground = ground; self.water = water; self.edits = edits; self.plants = plants
    }
    public var byteCount: Int {
      ground.byteCount + water.byteCount
        + (ground.visible.count + water.visible.count) * MemoryLayout<TerrainTile>.stride
        + edits.count * (MemoryLayout<BlockPosition>.stride + MemoryLayout<Block>.stride)
        + plants.count * (MemoryLayout<BlockPosition>.stride + MemoryLayout<PlantEdit>.stride)
    }
  }
  public enum Status: String, Sendable, Encodable {
    case ready, cancelled, invalidInput, inputLimit, outputLimit, missingGround, missingWater
    case wet, crossingScenery, unsupportedBoundary, exposedCave, exposureLimit
  }
  public struct Result: Sendable {
    public let status: Status
    public let candidate: Candidate?
  }
  public struct Candidate: Sendable {
    public let token: UUID
    public let source: TerrainWorkID
    public let revision: UInt64
    public let prepared: PreparedTerrainTile
    public let ground: TerrainSurfaceSources.Lease
    public let water: WaterSurfaceSources.Lease
    public let enclosedCapCount: Int
    public var tile: TerrainTile { source.tile }
    public var byteCount: Int { prepared.byteCount + ground.byteCount + water.byteCount }
    /// Connectivity certificates assume the viewer is outside this bounded
    /// patch. Entry (including flight/teleport) restores the retained fallback.
    public func permits(eye: SIMD3<Float>) -> Bool {
      TerrainDryRegion.permits(eye: eye, outside: tile)
    }
    public var columnOwners: [ChunkCoordinate: VoxelColumnMask] { TerrainDryRegion.columns(in: tile) }
  }
  public static let maximumInputBytes = 48 * 1_024 * 1_024
  public static let maximumOutputBytes = 8 * 1_024 * 1_024
  public static let retainedBorderBlocks = 2

  static func columns(in tile: TerrainTile) -> [ChunkCoordinate: VoxelColumnMask] {
    let border = retainedBorderBlocks, width = tile.blockSize
    var result: [ChunkCoordinate: VoxelColumnMask] = [:]
    for z in 0..<tile.size { for x in 0..<tile.size {
      var mask = VoxelColumnMask()
      mask.include(x: max(0,border-x*16)..<min(16,width-border-x*16),
        z: max(0,border-z*16)..<min(16,width-border-z*16))
      result[.init(tile.x+x,tile.z+z)] = mask
    } }
    return result
  }

  public static func permits(eye: SIMD3<Float>, outside tile: TerrainTile) -> Bool {
    guard eye.x.isFinite, eye.y.isFinite, eye.z.isFinite else { return false }
    let low = tile.origin - [2, 0, 2]
    let high = tile.origin + [Float(tile.blockSize + 2), 0, Float(tile.blockSize + 2)]
    return eye.x < low.x || eye.x > high.x || eye.z < low.z || eye.z > high.z
  }

  public static func build(_ input: Request) -> Result {
    guard valid(input) else { return .init(status: .invalidInput, candidate: nil) }
    guard input.byteCount <= maximumInputBytes else { return .init(status: .inputLimit, candidate: nil) }
    let tile = input.source.tile, ox = tile.x * 16, oz = tile.z * 16, width = tile.blockSize
    let sampler = TerrainSurface.Sampler(tile: tile, terrain: input.terrain)
    // Broader structure transactions must own their complete footprints. This
    // first path never cuts through procedural buildings, roads or sports lots.
    guard sampler.sites.isEmpty, sampler.roads.isEmpty, sampler.marinas.isEmpty,
      sampler.landmarks.isEmpty else { return .init(status: .crossingScenery, candidate: nil) }
    let lowX = ox+retainedBorderBlocks, lowZ = oz+retainedBorderBlocks
    let highX = ox+width-retainedBorderBlocks, highZ = oz+width-retainedBorderBlocks
    let trees = TerrainTreePlans.trees(x: (ox-5)..<(ox+width+5), z: (oz-5)..<(oz+width+5),
      terrain: input.terrain, order: .zThenX)
    guard !trees.contains(where: { tree in
      let intersects = tree.x+4 >= lowX && tree.x-4 < highX && tree.z+4 >= lowZ && tree.z-4 < highZ
      return intersects && (tree.x-4 < lowX || tree.x+4 >= highX || tree.z-4 < lowZ || tree.z+4 >= highZ)
    }) else { return .init(status: .crossingScenery, candidate: nil) }
    let retained = TerrainSurface.buildRetained(tile,terrain: input.terrain,edits: input.edits,
      measureError: input.source.profileSurface)
    guard retained.grid == input.ground.sources[tile]?.grid else { return .init(status: .invalidInput,candidate: nil) }
    var chunks: [ChunkCoordinate: ChunkData] = [:]
    for z in tile.z..<(tile.z+tile.size) { for x in tile.x..<(tile.x+tile.size) {
      if Task.isCancelled { return .init(status: .cancelled, candidate: nil) }
      let key = ChunkCoordinate(x, z)
      chunks[key] = input.terrain.generate(key, edits: input.edits)
    } }
    return assemble(input, chunks: chunks, retained: retained.mesh)
  }

  private static func valid(_ input: Request) -> Bool {
    let tile = input.source.tile
    return !tile.fullDetail && tile.size <= 2
      && input.ground.world == input.source.world
      && input.ground.sources[tile]?.id == input.source
  }

  /// Same assembler used in production, with immutable voxel fixtures available
  /// to regression tests. It never changes authoritative collision/world data.
  static func assemble(_ input: Request, chunks: [ChunkCoordinate: ChunkData], retained: VoxelMesh) -> Result {
    func rejected(_ status: Status) -> Result { .init(status: status, candidate: nil) }
    guard valid(input) else { return rejected(.invalidInput) }
    guard input.byteCount <= maximumInputBytes else { return rejected(.inputLimit) }
    let tile = input.source.tile, ox = tile.x*16, oz = tile.z*16, width = tile.blockSize
    let keys = (tile.z..<(tile.z+tile.size)).flatMap { z in
      (tile.x..<(tile.x+tile.size)).map { ChunkCoordinate($0,z) }
    }
    guard chunks.count == keys.count, keys.allSatisfy({ chunks[$0]?.coordinate == $0 }) else {
      return rejected(.invalidInput)
    }
    let ownership = columns(in: tile), border = retainedBorderBlocks
    // The retained rim must not hide an edited volume. Larger/cross-boundary
    // edits wait for a transaction owning the adjacent leaves too.
    for point in input.edits.keys where tile.contains(point.chunk) {
      guard ownership[point.chunk]?.contains(x: point.x-point.chunk.x*16,z: point.z-point.chunk.z*16) == true
      else { return rejected(.crossingScenery) }
    }
    var water = WaterSurfaceSources.Reader(input.water,
      limits: .init(tiles: 16, cells: 16_384, readChunks: 64, bytes: 4*1_024*1_024))
    // Check actual displayed fluid coverage, including a halo. A missing owner
    // is never evidence of dry land; mismatched ground/water LOD is permitted.
    for z in (oz-1)...(oz+width) {
      if Task.isCancelled { return rejected(.cancelled) }
      for x in (ox-1)...(ox+width) {
        guard let cell = water.cell(at: .init(x, z)) else { return rejected(.missingWater) }
        guard cell.corners == nil else { return rejected(.wet) }
      }
    }
    for chunk in chunks.values {
      guard !chunk.archiveCells.contains(Block.water.rawValue), !chunk.archiveCells.contains(Block.lava.rawValue)
      else { return rejected(.wet) }
    }
    var reads = Set(keys), exterior: [BlockPosition: Float] = [:]
    var boundaries: [ChunkCoordinate: VoxelColumnBoundary] = [:]
    var seams: [ChunkCoordinate: TerrainSurfaceSeam.Result] = [:]
    var samplers: [TerrainTile: TerrainSurface.Sampler] = [:]
    func coordinate(_ x: Int, _ z: Int) -> ChunkCoordinate {
      .init(floorDivide(x,by:16), floorDivide(z,by:16))
    }
    func sample(_ owner: TerrainTile, _ x: Int, _ z: Int) -> Float {
      if samplers[owner] == nil { samplers[owner] = .init(tile: owner, terrain: input.terrain) }
      return samplers[owner]!.column(x,z).height
    }
    for key in keys {
      if Task.isCancelled { return rejected(.cancelled) }
      let chunk = chunks[key]!
      let boundary = VoxelColumnBoundary(columns: ownership[key]!) { x, z in
        let outside = coordinate(key.x*16+x,key.z*16+z)
        let localX = key.x*16+x-outside.x*16, localZ = key.z*16+z-outside.z*16
        if ownership[outside]?.contains(x: localX,z: localZ) == true { return true }
        reads.insert(outside)
        if input.ground.owner(containing: outside)?.fullDetail == true {
          // Full voxel neighbours can expose any connected air at this edge.
          let px = key.x*16+min(15,max(0,x)), pz = key.z*16+min(15,max(0,z))
          exterior[.init(px,0,pz)] = Float(ChunkData.minimumY)
          return true
        }
        return false
      }
      var profiles: [VoxelColumnBoundary.Edge: [TerrainSurfaceSeam.Segment]] = [:]
      for edge in boundary.edges {
        let outside = edge.neighbor, x = key.x*16+outside.x, z = key.z*16+outside.z
        reads.insert(coordinate(x,z))
        guard let source = input.ground.source(containing: coordinate(x,z)),
          let segments = source.grid.segments(atLocalX: x-source.id.tile.x*16, z: z-source.id.tile.z*16,
            face: edge.face ^ 1, referenceHeight: sample(source.id.tile,x,z)) else { return rejected(.missingGround) }
        profiles[edge] = segments
        let inner = BlockPosition(key.x*16+edge.x,0,key.z*16+edge.z)
        exterior[inner] = min(exterior[inner] ?? .infinity, segments.map { min($0.firstHeight,$0.lastHeight) }.min()!)
        // A terrain-only seam cannot replace the sides of scenery spanning the
        // region boundary. Includes player-built geometry and clipped foliage.
        let a = Int(ceil(sample(tile,inner.x,inner.z))), b = Int(ceil(sample(source.id.tile,x,z)))
        if a <= chunk.maximumFilledY {
          for y in max(a,ChunkData.minimumY)...chunk.maximumFilledY where chunk[edge.x,y,edge.z] != .air {
            return rejected(.crossingScenery)
          }
        }
        if b <= chunk.maximumFilledY {
          for y in max(b,ChunkData.minimumY)...chunk.maximumFilledY where chunk[outside.x,y,outside.z] != .air {
            return rejected(.crossingScenery)
          }
        }
      }
      guard let seam = TerrainSurfaceSeam.build(chunk, boundary: boundary, surface: { profiles[$0]! })
      else { return rejected(.cancelled) }
      guard seam.unsupportedCells.isEmpty else { return rejected(.unsupportedBoundary) }
      boundaries[key] = boundary; seams[key] = seam
    }
    let exposure: VoxelPatchExposure
    switch VoxelPatchExposure.build(chunks.mapValues { .init(chunk: $0, columns: ownership[$0.coordinate]!) },
      maximumColumns: 1_024, maximumSpans: 65_536, exteriorOpening: { x,z,range in
        exterior[.init(x,0,z)].map { Float(range.upperBound) > $0 } ?? false
      }) {
    case let .ready(value): exposure = value
    case .cancelled: return rejected(.cancelled)
    case .limitExceeded: return rejected(.exposureLimit)
    }
    guard !seams.values.contains(where: { $0.requiresExpandedDetail(using: exposure) }) else { return rejected(.exposedCave) }
    let cut = TerrainMeshCutout.Rectangle(minimum: .init(repeating: Float(border)),
      maximum: .init(repeating: Float(width-border)))
    guard var mesh = TerrainMeshCutout.remove(cut,from: retained) else { return rejected(.unsupportedBoundary) }
    guard mesh.firesAndLampsAreEmpty else { return rejected(.unsupportedBoundary) }
    for key in keys {
      if Task.isCancelled { return rejected(.cancelled) }
      let chunk = chunks[key]!
      var piece = VoxelMesher.build(chunk, columns: ownership[key]!, includeWater: false, repeatAtlas: true, boundary: boundaries[key])
      piece.append(seams[key]!.mesh)
      let plants = SurfaceDecorationMesher.instances(in: chunk, terrain: input.terrain, lush: false, changes: input.plants)
        .filter { ownership[key]!.contains(x: $0.position.x-key.x*16,z: $0.position.z-key.z*16) }
      guard piece.firesAndLampsAreEmpty else { return rejected(.unsupportedBoundary) }
      let offset = SIMD3<Float>(Float((key.x-tile.x)*16),0,Float((key.z-tile.z)*16))
      piece.positions = piece.positions.map { $0 + offset }
      guard piece.positions.allSatisfy({ cut.contains($0) }) else { return rejected(.crossingScenery) }
      mesh.append(piece)
      // Surface proxies have no small plant geometry. Whole plants rooted on
      // exact columns may overhang the retained rim without duplicating scenery;
      // they must still fit within this leaf's unchanged external footprint.
      var foliage = SurfaceDecorationMesher.mesh(plants, chunk: key)
      foliage.positions = foliage.positions.map { $0+offset }
      guard foliage.positions.allSatisfy({ $0.x >= 0 && $0.z >= 0 && $0.x <= Float(width) && $0.z <= Float(width) })
      else { return rejected(.crossingScenery) }
      mesh.append(foliage)
      // The output limit is logical payload; one indivisible chunk mesher can
      // transiently allocate more. There are at most four source chunks.
      guard mesh.positions.count <= maximumOutputBytes / 64 else { return rejected(.outputLimit) }
    }
    let id = TerrainWorkID(world: input.source.world, tile: tile, revision: input.source.revision,
      lush: false, incarnation: input.source.incarnation, repeatAtlas: true)
    // Fine cube faces already carry repeating-atlas coordinates. Retained and
    // clipped faces keep their original atlas UVs; converting them into a new
    // unit quad here would stretch textures and change the preserved border.
    let packed = PackedTerrainMesh(mesh)
    let prepared = PreparedTerrainTile(id: id, mesh: packed)
    let candidate = Candidate(token: input.token, source: input.source, revision: input.revision, prepared: prepared,
      ground: input.ground.dependencies(for: reads), water: water.lease,
      enclosedCapCount: seams.values.reduce(0) { $0+$1.cavityCells.count })
    guard candidate.byteCount <= maximumOutputBytes else { return rejected(.outputLimit) }
    if Task.isCancelled { return rejected(.cancelled) }
    return .init(status: .ready, candidate: candidate)
  }
}

private extension VoxelMesh {
  var firesAndLampsAreEmpty: Bool { firePositions.isEmpty && lampPositions.isEmpty }
}

/// Bulk region work has an explicit utility executor. Neither generation nor
/// connectivity inspection inherits the rendering actor's executor.
public actor TerrainDryRegionWorker {
  private let executor = DryRegionExecutor()
  nonisolated public var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
  public init() {}
  public func build(_ input: TerrainDryRegion.Request) -> TerrainDryRegion.Result { TerrainDryRegion.build(input) }
}
private final class DryRegionExecutor: SerialExecutor {
  private let queue = DispatchQueue(label: "com.worldcraft.dry-region", qos: .utility)
  func enqueue(_ job: consuming ExecutorJob) {
    let work = UnownedJob(job)
    queue.async { work.runSynchronously(on: self.asUnownedSerialExecutor()) }
  }
}
