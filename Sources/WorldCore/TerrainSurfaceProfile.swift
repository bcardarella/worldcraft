import Foundation

/// Immutable ground data captured from the same build as a coarse mesh. It
/// describes its actual stepped tops / triangle diagonal, not a fresh sample
/// of procedural terrain. Scenery, caves and water need separate ownership.
public struct TerrainSurfaceGrid: Sendable, Equatable {
  public let tile: TerrainTile
  public let heights: [Float]
  public let materials: [Block]
  public var side: Int { tile.blockSize / tile.sampleStride + 1 }
  public var byteCount: Int { heights.count * MemoryLayout<Float>.stride + materials.count * MemoryLayout<Block>.stride }
  public init?(tile: TerrainTile, heights: [Float], materials: [Block]) {
    let side = tile.blockSize / tile.sampleStride + 1
    guard !tile.fullDetail, heights.count == side * side,
      materials.count == (side - 1) * (side - 1), heights.allSatisfy(\.isFinite) else { return nil }
    self.tile = tile; self.heights = heights; self.materials = materials
  }
  public struct Cell: Sendable, Equatable {
    public let x, z, size: Int
    /// NW, SW, SE, NE, matching the original two triangles.
    public let heights: SIMD4<Float>
    public let material: Block
    public var corners: [SIMD3<Float>] {
      [[Float(x),heights.x,Float(z)],[Float(x),heights.y,Float(z+size)],
       [Float(x+size),heights.z,Float(z+size)],[Float(x+size),heights.w,Float(z)]]
    }
    public func height(atLocalX x: Float, z: Float) -> Float? {
      guard x.isFinite, z.isFinite, x >= Float(self.x), x <= Float(self.x+size),
        z >= Float(self.z), z <= Float(self.z+size) else { return nil }
      let u = (x-Float(self.x))/Float(size), v = (z-Float(self.z))/Float(size), h = heights
      return v >= u ? h.x+(h.y-h.x)*v+(h.z-h.y)*u : h.x+(h.z-h.w)*v+(h.w-h.x)*u
    }
  }
  /// Half-open ownership chooses the correct side of a block-height step.
  public func cell(atLocalX x: Int, z: Int) -> Cell? {
    guard (0..<tile.blockSize).contains(x), (0..<tile.blockSize).contains(z) else { return nil }
    let step = tile.sampleStride, cx = x/step, cz = z/step, i = cz*side+cx
    let h: SIMD4<Float> = tile.retainsBlockSurface ? .init(repeating: heights[i])
      : [heights[i],heights[i+side],heights[i+side+1],heights[i+1]]
    return .init(x: cx*step, z: cz*step, size: step, heights: h, material: materials[cz*(side-1)+cx])
  }
  /// Face of an owned unit column, increasing along +Z (X faces) or +X
  /// (Z faces). The uncarved reference must come from the caller's matching
  /// immutable voxel/world source; this grid does not invent that evidence.
  public func segments(atLocalX x: Int, z: Int, face: Int, referenceHeight: Float) -> [TerrainSurfaceSeam.Segment]? {
    guard [0,1,4,5].contains(face), referenceHeight.isFinite,
      let cell = cell(atLocalX: x,z: z), cell.material.isOpaque, !cell.material.isFoliage else { return nil }
    let alongZ = face < 2
    let sx = Float(x+(face == 0 ? 1:0)), sz = Float(z+(face == 4 ? 1:0))
    let diagonal = alongZ ? sx-Float(cell.x)-sz+Float(cell.z) : sz-Float(cell.z)-sx+Float(cell.x)
    var cuts: [Float] = [0]
    if diagonal > 0 && diagonal < 1 && !tile.retainsBlockSurface { cuts.append(diagonal) }
    cuts.append(1)
    func height(_ t: Float) -> Float? { cell.height(atLocalX: sx+(alongZ ? 0:t), z: sz+(alongZ ? t:0)) }
    var result: [TerrainSurfaceSeam.Segment] = []
    for i in 0..<(cuts.count-1) {
      guard let a = height(cuts[i]), let b = height(cuts[i+1]),
        min(a,b) >= Float(ChunkData.minimumY), max(a,b) <= Float(ChunkData.height) else { return nil }
      result.append(.init(lower: cuts[i],upper: cuts[i+1],firstHeight: a,lastHeight: b,
        material: cell.material,referenceHeight: referenceHeight))
    }
    return result
  }
}

/// Mirrors successful native ownership, including hidden replacement tiles.
/// Publication snapshots contain ONLY visible sources. Removal, replacement,
/// reset or ownership changes invalidate them without mutating captured arrays.
/// This is ground-source validity, not a complete world/edit/view/water lease.
public struct TerrainSurfaceSources: Sendable {
  public struct Source: Sendable {
    public let id: TerrainWorkID
    public let grid: TerrainSurfaceGrid
    fileprivate let token: UUID
  }
  public struct Snapshot: Sendable {
    public let sources: [TerrainTile: Source]
    public let visible: Set<TerrainTile>
    /// Nil when coverage contains only full-detail tiles (or is empty).
    public let world: UUID?
    fileprivate let lifetime: UUID
    public var byteCount: Int { sources.values.reduce(0) { $0+$1.grid.byteCount } }
    public func owner(containing point: ChunkCoordinate) -> TerrainTile? {
      let fine = TerrainTile(x: point.x, z: point.z, fullDetail: true)
      if visible.contains(fine) { return fine }
      for size in [1,2,4,8,16,32] {
        let tile = TerrainTile(x:floorDivide(point.x,by:size)*size,z:floorDivide(point.z,by:size)*size,size:size)
        if sources[tile] != nil { return tile }
      }
      return nil
    }
    public func source(containing point: ChunkCoordinate) -> Source? {
      owner(containing: point).flatMap { sources[$0] }
    }
    /// Records every queried ownership result, including fine coverage and
    /// empty space. The returned lease retains tokens, never the grid arrays.
    public func dependencies(for coordinates: Set<ChunkCoordinate>) -> Lease {
      var coarse: [TerrainTile: UUID] = [:], fine = Set<TerrainTile>(), missing = Set<ChunkCoordinate>()
      for coordinate in coordinates {
        if let owner = owner(containing: coordinate) {
          if let source = sources[owner] { coarse[owner] = source.token }
          else { fine.insert(owner) }
        } else { missing.insert(coordinate) }
      }
      return .init(coarse: coarse, fine: fine, missing: missing, lifetime: lifetime)
    }
  }
  /// Only the read dependencies invalidate background work. An unrelated tile
  /// finishing its upload must not continuously cancel a long feature job.
  /// Fine ownership is recorded here; its voxel content has a separate lease.
  public struct Lease: Sendable {
    fileprivate let coarse: [TerrainTile: UUID]
    fileprivate let fine: Set<TerrainTile>
    fileprivate let missing: Set<ChunkCoordinate>
    fileprivate let lifetime: UUID
    public var coarseCount: Int { coarse.count }
    public var fineCount: Int { fine.count }
    public var missingCount: Int { missing.count }
    public var byteCount: Int {
      coarse.count * (MemoryLayout<TerrainTile>.stride + MemoryLayout<UUID>.stride)
        + fine.count * MemoryLayout<TerrainTile>.stride + missing.count * MemoryLayout<ChunkCoordinate>.stride
    }
    /// Combining phases/waves must not combine contradictory source versions
    /// or spatial ownership, even if each individual read was once valid.
    public func merging(_ other: Lease) -> Lease? {
      guard lifetime == other.lifetime else { return nil }
      var coarse = coarse
      for (tile, token) in other.coarse {
        guard coarse[tile] == nil || coarse[tile] == token else { return nil }
        coarse[tile] = token
      }
      let fine = fine.union(other.fine), missing = missing.union(other.missing)
      let owners = Set(coarse.keys).union(fine), index = TerrainOverlapIndex(owners)
      guard owners.allSatisfy({ index.overlapping($0).count == 1 }),
        missing.allSatisfy({ !index.containsOverlap(with: .init(x: $0.x, z: $0.z)) }) else { return nil }
      return .init(coarse: coarse, fine: fine, missing: missing, lifetime: lifetime)
    }
  }
  public struct Metrics: Sendable, Encodable {
    public let entries, bytes, limitEntries, limitBytes, refused: Int
  }
  private var values: [TerrainTile: Source] = [:]
  private var bytes = 0, refused = 0
  private var lifetime = UUID()
  public let limitEntries, limitBytes: Int
  public init(limitEntries: Int = 2_048, limitBytes: Int = 16*1_024*1_024) {
    precondition(limitEntries >= 0 && limitBytes >= 0)
    self.limitEntries = limitEntries; self.limitBytes = limitBytes
  }
  public var metrics: Metrics { .init(entries:values.count,bytes:bytes,limitEntries:limitEntries,limitBytes:limitBytes,refused:refused) }
  @discardableResult public mutating func install(id: TerrainWorkID, grid: TerrainSurfaceGrid?) -> Bool {
    // Even an inadmissible replacement invalidates the previous rendered source.
    remove(id.tile)
    guard let grid, grid.tile == id.tile, !id.tile.fullDetail else { return false }
    guard values.count < limitEntries, grid.byteCount <= limitBytes-bytes else { refused += 1; return false }
    values[id.tile] = .init(id:id,grid:grid,token:UUID()); bytes += grid.byteCount
    return true
  }
  public mutating func remove(_ tile: TerrainTile) { bytes -= values.removeValue(forKey:tile)?.grid.byteCount ?? 0 }
  public mutating func reset() { self = .init(limitEntries:limitEntries,limitBytes:limitBytes) }
  /// A mixed surface/volume replacement cannot be described by a height grid.
  /// Until it supplies a richer source descriptor, explicitly mark its tile
  /// unavailable instead of exporting the hidden fallback as current geometry.
  public func snapshot(visible: Set<TerrainTile>, unavailable: Set<TerrainTile> = []) -> Snapshot? {
    guard available(visible, excluding: unavailable) else { return nil }
    let overlap = TerrainOverlapIndex(visible)
    var sources: [TerrainTile: Source] = [:]
    var world: UUID?
    for tile in visible {
      guard overlap.overlapping(tile).count == 1 else { return nil }
      if tile.fullDetail { continue }
      guard let source = values[tile] else { return nil }
      guard world == nil || world == source.id.world else { return nil }
      world = source.id.world
      sources[tile] = source
    }
    return .init(sources:sources,visible:visible,world:world,lifetime:lifetime)
  }
  public func isCurrent(_ snapshot: Snapshot, visible: Set<TerrainTile>, unavailable: Set<TerrainTile> = []) -> Bool {
    available(visible, excluding: unavailable) && snapshot.lifetime == lifetime && snapshot.visible == visible
      && snapshot.sources.allSatisfy { values[$0.key]?.token == $0.value.token }
  }
  private func available(_ visible: Set<TerrainTile>, excluding unavailable: Set<TerrainTile>) -> Bool {
    guard !unavailable.isEmpty else { return true }
    let index = TerrainOverlapIndex(unavailable)
    return !visible.contains(where: { index.containsOverlap(with: $0) })
  }
  public func isCurrent(_ lease: Lease, visible: Set<TerrainTile>, unavailable: Set<TerrainTile> = []) -> Bool {
    guard lease.lifetime == lifetime, lease.fine.isSubset(of: visible),
      lease.coarse.allSatisfy({ visible.contains($0.key) && values[$0.key]?.token == $0.value }) else { return false }
    if !unavailable.isEmpty {
      let changed = TerrainOverlapIndex(unavailable)
      guard !lease.coarse.keys.contains(where: { changed.containsOverlap(with: $0) }),
        !lease.fine.contains(where: { changed.containsOverlap(with: $0) }) else { return false }
    }
    // A newly installed covering tile invalidates an earlier negative lookup.
    // No spatial index is needed for the common all-known-source case.
    if lease.missing.isEmpty { return true }
    let index = TerrainOverlapIndex(visible)
    return lease.missing.allSatisfy { !index.containsOverlap(with: .init(x: $0.x, z: $0.z)) }
  }
}

/// Measured height-field residual at the next finer sampling grid, in blocks.
/// Height residuals are estimates, not Hausdorff bounds; caves and sub-grid
/// peaks need separate representations/error tests. Canopy grouping uses a
/// conservative support extent, not a measured surface displacement. No eye resolution
/// or projection matrix is assumed by the error/distance ratio below.
public struct TerrainSurfaceProfile: Sendable, Equatable {
  public let minimumY, maximumY, sampledHeightError: Float
  /// Diameter of the largest clipped group containing both the grouped canopy
  /// and its static individual-tree reference. Silhouette differences fit inside that
  /// angular support, including missing trunks/gaps; this can over-refine trees.
  public let groupedCanopyExtent: Float
  public let sampleCount: Int
  public init(minimumY: Float, maximumY: Float, sampledHeightError: Float, sampleCount: Int,
    groupedCanopyExtent: Float = 0) {
    self.minimumY = minimumY; self.maximumY = maximumY
    self.sampledHeightError = sampledHeightError; self.sampleCount = sampleCount
    self.groupedCanopyExtent = groupedCanopyExtent
  }
  public var isValid: Bool {
    minimumY.isFinite && maximumY.isFinite && minimumY <= maximumY
      && sampledHeightError.isFinite && sampledHeightError >= 0
      && groupedCanopyExtent.isFinite && groupedCanopyExtent >= 0
      && sampleCount >= 0 && sampleCount <= 65_536
  }
  public func projectedError(for tile: TerrainTile, eye: SIMD3<Float>) -> Float {
    guard isValid, eye.x.isFinite, eye.y.isFinite, eye.z.isFinite else { return 0 }
    let low = tile.origin + [0, minimumY, 0]
    let high = tile.origin + [Float(tile.blockSize), maximumY, Float(tile.blockSize)]
    let delta = componentMax(componentMax(low - eye, eye - high), .zero)
    let distance = (delta.x * delta.x + delta.y * delta.y + delta.z * delta.z).squareRoot()
    let error = max(sampledHeightError, groupedCanopyExtent)
    return error == 0 ? 0 : error / max(0.001, distance)
  }

  /// Compare the actual parent triangles (or block tops) with the next finer
  /// grid. Reuse aligned samples; evaluate only the newly introduced columns.
  static func measure(tile: TerrainTile, heights: [Float], sample: (Int, Int) -> Float) -> Self? {
    let step = tile.sampleStride, side = tile.blockSize / step + 1
    precondition(heights.count == side * side)
    var low = heights.min() ?? 0, high = heights.max() ?? 0, error: Float = 0, count = 0
    if step > 1 {
      let fineStep = step / 2, fineSide = tile.blockSize / fineStep + 1
      for z in 0..<fineSide {
        if Task.isCancelled { return nil }
        for x in 0..<fineSide where x % 2 != 0 || z % 2 != 0 {
          let observed = sample(x * fineStep, z * fineStep)
          low = min(low, observed); high = max(high, observed); count += 1
          let cx = min(x / 2, side - 2), cz = min(z / 2, side - 2)
          let u = Float(x) * 0.5 - Float(cx), v = Float(z) * 0.5 - Float(cz)
          let a = heights[cz * side + cx], b = heights[(cz + 1) * side + cx]
          let c = heights[(cz + 1) * side + cx + 1], d = heights[cz * side + cx + 1]
          let interpolated: Float
          if tile.retainsBlockSurface { interpolated = a }
          else if v >= u { interpolated = a * (1 - v) + b * (v - u) + c * u }
          else { interpolated = a * (1 - u) + c * v + d * (u - v) }
          error = max(error, abs(observed - interpolated))
        }
      }
    }
    return .init(minimumY: low, maximumY: high, sampledHeightError: error, sampleCount: count)
  }
}

/// Small metadata survives parent retirement; no mesh/collision arrays are
/// retained. Invalidating an edit touches only its six possible ancestor keys.
public struct TerrainSurfaceProfiles: Sendable {
  public private(set) var values: [TerrainTile: TerrainSurfaceProfile] = [:]
  public let limit: Int
  private var recency = TerrainCacheRecency<TerrainTile>()
  public init(limit: Int = 4_096) { precondition(limit > 0); self.limit = limit }
  public mutating func insert(_ profile: TerrainSurfaceProfile, for tile: TerrainTile) {
    guard !tile.fullDetail, profile.isValid else { return }
    if values[tile] == nil, values.count == limit, let oldest = recency.oldest {
      values[oldest] = nil; recency.remove(oldest)
    }
    values[tile] = profile; recency.touch(tile)
  }
  public mutating func invalidate(_ coordinates: Set<ChunkCoordinate>) {
    for coordinate in coordinates {
      for size in [1, 2, 4, 8, 16, 32] {
        let tile = TerrainTile(x: floorDivide(coordinate.x, by: size) * size,
          z: floorDivide(coordinate.z, by: size) * size, size: size)
        values[tile] = nil; recency.remove(tile)
      }
    }
  }
}
