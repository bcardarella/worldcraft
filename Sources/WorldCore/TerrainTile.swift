/// Stable, world-aligned quadtree leaves. Only the innermost leaves own voxel
/// volumes. A distant leaf covers up to 1,024 chunks with a single surface mesh.
public struct TerrainTile: Hashable, Sendable {
  public let x: Int
  public let z: Int
  public let size: Int
  public let fullDetail: Bool
  public init(x: Int, z: Int, size: Int = 1, fullDetail: Bool = false) {
    precondition(size > 0 && size <= 32 && size.nonzeroBitCount == 1)
    precondition(x % size == 0 && z % size == 0)
    precondition(!fullDetail || size == 1)
    self.x = x
    self.z = z
    self.size = size
    self.fullDetail = fullDetail
  }
  public var coordinate: ChunkCoordinate { .init(x, z) }
  public var origin: SIMD3<Float> { coordinate.origin }
  public var blockSize: Int { size * 16 }
  public var sampleStride: Int { size <= 2 ? 1 : max(2, size / 2) }
  public var retainsBlockSurface: Bool { !fullDetail && size <= 4 }
  public var center: SIMD3<Float> { origin + [Float(blockSize) / 2, 0, Float(blockSize) / 2] }
  public func contains(_ coordinate: ChunkCoordinate) -> Bool {
    coordinate.x >= x && coordinate.x < x + size && coordinate.z >= z && coordinate.z < z + size
  }
  public func overlaps(_ other: Self) -> Bool {
    x < other.x + other.size && x + size > other.x && z < other.z + other.size && z + size > other.z
  }
  public func distanceSquared(to coordinate: ChunkCoordinate) -> Int {
    let dx = max(x - coordinate.x, coordinate.x - (x + size - 1), 0)
    let dz = max(z - coordinate.z, coordinate.z - (z + size - 1), 0)
    return dx * dx + dz * dz
  }
}

public struct TerrainStreamingPlan: Sendable {
  public let tiles: Set<TerrainTile>
  /// Quantized, bounded prediction keeps walking/flight upgrades ahead of the
  /// player without rebuilding the plan for every small velocity fluctuation.
  public static func lookAhead(
    from center: ChunkCoordinate, velocity: SIMD3<Float>
  ) -> ChunkCoordinate {
    guard velocity.x.isFinite, velocity.z.isFinite else { return center }
    // Use Double for the magnitude so even a finite but corrupted Float input
    // cannot overflow, produce NaN while clamping, and trap during Int conversion.
    var lead = SIMD2<Double>(Double(velocity.x), Double(velocity.z)) * (2.5 / 16)
    let length = (lead.x * lead.x + lead.y * lead.y).squareRoot()
    if length > 6 { lead *= 6 / length }
    return .init(center.x + Int((lead.x / 2).rounded()) * 2,
      center.z + Int((lead.y / 2).rounded()) * 2)
  }
  public static func anchor(
    for center: ChunkCoordinate, radius: Int,
    previous: ChunkCoordinate? = nil
  ) -> ChunkCoordinate {
    guard DrawDistance.clamp(radius) > 6 else { return center }
    if let previous, abs(center.x - previous.x) <= 2 && abs(center.z - previous.z) <= 2 {
      return previous
    }
    return .init(floorDivide(center.x, by: 4) * 4 + 2, floorDivide(center.z, by: 4) * 4 + 2)
  }
  public init(
    center: ChunkCoordinate, radius: Int, detailRadius: Int = DrawDistance.detailedRadius,
    lookAhead: ChunkCoordinate? = nil
  ) {
    let requested = DrawDistance.clamp(radius)
    let center = Self.anchor(for: center, radius: requested)
    let detail = min(requested, DrawDistance.clampDetail(detailRadius))
    let ahead = lookAhead ?? center
    let aheadRadius = max(0, detail - 2)
    // Buffer both the horizon and the interactive radius against the anchor's
    // movement hysteresis. Mid-distance meshes retain block steps and trees.
    let radius = requested + (requested > 6 ? 3 : 0)
    var leaves: Set<TerrainTile> = []
    func visit(x: Int, z: Int, size: Int, retainedCoverage: Bool = false) {
      let tile = TerrainTile(x: x, z: z, size: size)
      let distance = tile.distanceSquared(to: center)
      guard retainedCoverage || distance <= radius * radius else { return }
      let baseDetail = distance <= detail * detail
      let fullDetail = baseDetail
        || tile.distanceSquared(to: ahead) <= aheadRadius * aheadRadius
      if size == 1 {
        leaves.insert(.init(x: x, z: z, fullDetail: fullDetail))
      } else if !fullDetail && distance >= size * size * 6
      {
        leaves.insert(tile)
      } else {
        let half = size / 2
        // Predictive refinement must replace the entire original coarse leaf,
        // including its conservative fringe outside the requested circle.
        // Clipping children anew could make existing horizon coverage vanish.
        let retain = retainedCoverage || (!baseDetail && distance >= size * size * 6)
        for dz in [0, half] { for dx in [0, half] {
          visit(x: x + dx, z: z + dz, size: half, retainedCoverage: retain)
        } }
      }
    }
    // Keep the outermost tile whole instead of subdividing a circle's edge into
    // hundreds of tiny jobs. The requested radius is a guaranteed minimum.
    for z in floorDivide(center.z - radius, by: 32)...floorDivide(center.z + radius, by: 32) {
      for x in floorDivide(center.x - radius, by: 32)...floorDivide(center.x + radius, by: 32) {
        visit(x: x * 32, z: z * 32, size: 32)
      }
    }
    tiles = leaves
  }
}

/// Resolve an LOD exchange as an atomic coverage change. The renderer can
/// prepare children invisibly and retire their parent only once all are ready.
public struct TerrainCoverage: Sendable {
  public let retired: Set<TerrainTile>
  public let visible: Set<TerrainTile>
  public init(desired: Set<TerrainTile>, available: Set<TerrainTile>) {
    let outgoing = available.subtracting(desired)
    guard !outgoing.isEmpty else { retired = []; visible = available; return }
    let missing = TerrainOverlapIndex(desired.subtracting(available))
    var removing = Set(outgoing.filter { !missing.containsOverlap(with: $0) })
    let retained = outgoing.subtracting(removing)
    // A changed frontier can make both a fallback parent and its already
    // installed hidden child obsolete. The child must not become a second
    // visible fallback. Retire redundant descendants while the parent covers
    // them; aligned power-of-two ancestors make this a bounded set lookup.
    for tile in retained {
      if !tile.fullDetail && tile.size == 1
        && retained.contains(.init(x: tile.x, z: tile.z, fullDetail: true)) {
        removing.insert(tile); continue
      }
      var size = tile.size * 2
      while size <= 32 {
        let parent = TerrainTile(x: floorDivide(tile.x, by: size) * size,
          z: floorDivide(tile.z, by: size) * size, size: size)
        if retained.contains(parent) { removing.insert(tile); break }
        size *= 2
      }
    }
    retired = removing
    let remaining = available.subtracting(removing)
    let blockers = retained.subtracting(removing)
    guard !blockers.isEmpty else { visible = remaining; return }
    let old = TerrainOverlapIndex(blockers)
    visible = Set(remaining.filter { !desired.contains($0) || !old.containsOverlap(with: $0) })
  }
}

/// Incremental scene ownership, partitioned by the largest aligned terrain tile.
/// No tile overlaps two regions, so each region uses exactly the full-scan
/// coverage rules while unchanged regions keep their last resolved ownership.
/// Own this value alongside the scene; insert only successfully installed tiles.
public struct TerrainCoverageTracker: Sendable {
  public struct Changes: Sendable {
    public var retired: Set<TerrainTile> = []
    public var becameVisible: Set<TerrainTile> = []
    public var becameHidden: Set<TerrainTile> = []
  }
  public struct Metrics: Sendable, Encodable {
    public let regions, dirtyRegions, desiredTiles, availableTiles, visibleTiles: Int
    public let resolutions, unchangedResolutions, regionsResolved: Int
    public let desiredTilesExamined, availableTilesExamined: Int
  }
  private struct Region: Sendable {
    var desired: Set<TerrainTile> = []
    var available: Set<TerrainTile> = []
    var visible: Set<TerrainTile> = []
  }
  private var desired: Set<TerrainTile> = []
  private var regions: [TerrainTile: Region] = [:]
  private var dirty: Set<TerrainTile> = []
  private var resolutions = 0, unchangedResolutions = 0, regionsResolved = 0
  private var desiredTilesExamined = 0, availableTilesExamined = 0

  public init() {}

  private static func region(for tile: TerrainTile) -> TerrainTile {
    .init(x: floorDivide(tile.x, by: 32) * 32, z: floorDivide(tile.z, by: 32) * 32, size: 32)
  }

  public mutating func setDesired(_ next: Set<TerrainTile>) {
    guard next != desired else { return }
    for tile in desired.subtracting(next) {
      let key = Self.region(for: tile)
      regions[key]?.desired.remove(tile); dirty.insert(key)
    }
    for tile in next.subtracting(desired) {
      let key = Self.region(for: tile)
      regions[key, default: .init()].desired.insert(tile); dirty.insert(key)
    }
    desired = next
  }

  /// Replacing a mesh at an existing address changes its content, not coverage.
  /// Avoid dirtying the region or copying its sets for that common edit path.
  public mutating func insert(_ tile: TerrainTile) {
    let key = Self.region(for: tile)
    guard regions[key]?.available.contains(tile) != true else { return }
    regions[key, default: .init()].available.insert(tile); dirty.insert(key)
  }

  /// Consume changes once. Retired tiles are removed from availability here;
  /// the caller must retire the corresponding scene resources in the same turn.
  public mutating func resolve() -> Changes {
    resolutions += 1
    guard !dirty.isEmpty else { unchangedResolutions += 1; return .init() }
    var changes = Changes()
    for key in dirty {
      // Take ownership before mutating sets, avoiding a copy held by the map.
      guard var region = regions.removeValue(forKey: key) else { continue }
      regionsResolved += 1
      desiredTilesExamined += region.desired.count
      availableTilesExamined += region.available.count
      let result = TerrainCoverage(desired: region.desired, available: region.available)
      changes.retired.formUnion(result.retired)
      changes.becameVisible.formUnion(result.visible.subtracting(region.visible))
      changes.becameHidden.formUnion(region.visible.subtracting(result.visible))
      region.available.subtract(result.retired)
      region.visible = result.visible
      // Leaving a world region releases its sets rather than accumulating an
      // ever-growing record of previously visited terrain.
      if !region.desired.isEmpty || !region.available.isEmpty { regions[key] = region }
    }
    dirty.removeAll(keepingCapacity: true)
    return changes
  }

  public var metrics: Metrics {
    .init(regions: regions.count, dirtyRegions: dirty.count, desiredTiles: desired.count,
      availableTiles: regions.values.reduce(0) { $0 + $1.available.count },
      visibleTiles: regions.values.reduce(0) { $0 + $1.visible.count },
      resolutions: resolutions, unchangedResolutions: unchangedResolutions, regionsResolved: regionsResolved,
      desiredTilesExamined: desiredTilesExamined, availableTilesExamined: availableTilesExamined)
  }

  public mutating func reset() { self = .init() }
}
