import Foundation

/// A vertical interface between exact voxel columns and a piecewise-linear
/// coarse ground surface. Interior voxel geometry is never displaced.
/// This is a preparation primitive, not a feature-selection or water policy.
public enum TerrainSurfaceSeam {
  public enum FluidOwnership: Sendable, Equatable {
    /// A caller without separate fluid coverage must retain detailed boundaries.
    case requireExpansion
    /// Only terrain is joined. The caller must keep a matching water/lava
    /// surface across the reported fluid cells until its replacement is ready.
    /// This does not authorize publishing a terrain patch by itself.
    case retainedSeparately
  }
  public struct Segment: Sendable, Equatable {
    /// Fraction of the unit edge, increasing along +Z for X faces, +X for Z.
    public let lower, upper, firstHeight, lastHeight: Float
    public let material: Block
    /// Uncarved ground height outside the patch, used to identify cavity caps.
    public let referenceHeight: Float
    public init(lower: Float = 0, upper: Float = 1, firstHeight: Float, lastHeight: Float,
      material: Block, referenceHeight: Float) {
      precondition(lower >= 0 && upper <= 1 && upper > lower)
      precondition(firstHeight.isFinite && lastHeight.isFinite && referenceHeight.isFinite)
      precondition(min(firstHeight, lastHeight) >= Float(ChunkData.minimumY)
        && max(firstHeight, lastHeight) <= Float(ChunkData.height))
      precondition(material.isOpaque && !material.isFoliage)
      self.lower = lower; self.upper = upper
      self.firstHeight = firstHeight; self.lastHeight = lastHeight
      self.material = material; self.referenceHeight = referenceHeight
    }
    func height(_ u: Float) -> Float {
      firstHeight + (lastHeight - firstHeight) * ((u - lower) / (upper - lower))
    }
  }
  /// Bounds of potential false-wall geometry, rather than the whole air cell
  /// behind it. Pieces on the same oriented cell face share conservative bounds.
  public struct CavityFace: Sendable, Equatable {
    public let outsideCell: BlockPosition
    /// Face of the outside cell facing into the exact voxel patch.
    public let face: Int
    /// Bounds relative to outsideCell, in [0,1]. The normal axis has zero
    /// thickness. Keep the integer world origin separate to retain precision
    /// far from the origin; convert it to Double before adding these offsets.
    public let minimum, maximum: SIMD3<Float>
  }
  public struct Inspection: Sendable, Equatable {
    /// World cells where a coarse solid would cap an actual void at this edge.
    /// Connectivity can conservatively exclude enclosed pockets; potentially
    /// exposed caps must expand/retain detail rather than publish a false wall.
    public let cavityCells: [BlockPosition]
    /// Tighter targets for a conservative visibility test. Every exposed face
    /// must be resolved; certifying one face does not certify the whole cell.
    /// These are diagnostics, never valid occluders for their own visibility.
    public let cavityFaces: [CavityFace]
    /// Shaped fixtures and liquids need their own cross-sections/ownership.
    public let unsupportedCells: [BlockPosition]
    /// Actual water/lava cells at the interface when retainedSeparately is
    /// requested. These are dependencies on another layer, not false solid
    /// walls and not an instruction to expand terrain along the whole shoreline.
    public let fluidBoundaryCells: [BlockPosition]
    public var requiresRetainedFluidSurface: Bool { !fluidBoundaryCells.isEmpty }
    /// Conservative fallback when patch-wide connectivity is not available.
    public var requiresExpandedDetail: Bool { !cavityCells.isEmpty || !unsupportedCells.isEmpty }
    public func requiresExpandedDetail(using exposure: VoxelPatchExposure) -> Bool {
      !unsupportedCells.isEmpty || !exposure.exposedFrontier(cavityCells).isEmpty
    }
  }
  public struct Result: Sendable {
    public let mesh: VoxelMesh
    public let inspection: Inspection
    public var cavityCells: [BlockPosition] { inspection.cavityCells }
    public var cavityFaces: [CavityFace] { inspection.cavityFaces }
    public var unsupportedCells: [BlockPosition] { inspection.unsupportedCells }
    public var fluidBoundaryCells: [BlockPosition] { inspection.fluidBoundaryCells }
    public var requiresExpandedDetail: Bool { inspection.requiresExpandedDetail }
    public func requiresExpandedDetail(using exposure: VoxelPatchExposure) -> Bool {
      inspection.requiresExpandedDetail(using: exposure)
    }
  }
  private struct Vertex {
    let position: SIMD3<Float>
    let uv: SIMD2<Float>
    func interpolate(_ other: Self, _ t: Float) -> Self {
      .init(position: position + (other.position - position) * t, uv: uv + (other.uv - uv) * t)
    }
  }
  private struct FaceKey: Hashable {
    let cell: BlockPosition
    let face: Int
  }
  private static func clip(_ polygon: [Vertex], distance: (Vertex) -> Float) -> [Vertex] {
    guard var previous = polygon.last else { return [] }
    var old = distance(previous), result: [Vertex] = []
    for current in polygon {
      let now = distance(current)
      if (old >= 0) != (now >= 0) { result.append(previous.interpolate(current, old / (old - now))) }
      if now >= 0 { result.append(current) }
      previous = current; old = now
    }
    return result
  }
  /// Segments for each edge must partition [0,1] in ascending order. Their
  /// heights are the original coarse triangles at the boundary, including any
  /// triangle/grid breakpoints, not an unrelated bilinear approximation.
  /// Returns nil on cancellation. The caller must keep its existing coverage
  /// whenever the result reports an unresolved cavity or unsupported cell.
  public static func build(_ chunk: ChunkData, boundary: VoxelColumnBoundary,
    fluids: FluidOwnership = .requireExpansion,
    surface: (VoxelColumnBoundary.Edge) -> [Segment]) -> Result? {
    prepare(chunk, boundary: boundary, fluids: fluids, includeMesh: true, surface: surface)
  }
  /// Selection can inspect a boundary without allocating its render buffers.
  /// Use the same immutable chunk, boundary and surface for the eventual build;
  /// an inspection alone is not a complete mesh or a publication decision.
  public static func inspect(_ chunk: ChunkData, boundary: VoxelColumnBoundary,
    fluids: FluidOwnership = .requireExpansion,
    surface: (VoxelColumnBoundary.Edge) -> [Segment]) -> Inspection? {
    prepare(chunk, boundary: boundary, fluids: fluids, includeMesh: false, surface: surface)?.inspection
  }
  private static func prepare(_ chunk: ChunkData, boundary: VoxelColumnBoundary,
    fluids: FluidOwnership, includeMesh: Bool, surface: (VoxelColumnBoundary.Edge) -> [Segment]) -> Result? {
    if Task.isCancelled { return nil }
    var mesh = VoxelMesh(), cavities = Set<BlockPosition>(), unsupported = Set<BlockPosition>()
    var cavityFaces: [FaceKey: CavityFace] = [:]
    var fluidCells = Set<BlockPosition>()
    let worldX = chunk.coordinate.x * 16, worldZ = chunk.coordinate.z * 16
    func world(_ x: Int, _ y: Int, _ z: Int) -> BlockPosition { .init(worldX + x, y, worldZ + z) }
    func append(_ polygon: [Vertex], block: Block, face: Int) {
      var polygon = polygon
      func same(_ a: Vertex, _ b: Vertex) -> Bool {
        let d = a.position - b.position
        return d.x*d.x + d.y*d.y + d.z*d.z < 1e-12
      }
      var clean: [Vertex] = []
      for vertex in polygon where clean.last.map({ !same($0, vertex) }) ?? true { clean.append(vertex) }
      if clean.count > 1 && same(clean[0], clean.last!) { clean.removeLast() }
      polygon = clean
      guard polygon.count >= 3 else { return }
      let d = VoxelMesher.offsets[face], normal = SIMD3<Float>(Float(d.x), 0, Float(d.z))
      let material: UInt32 = block == .glass ? 2 : block.isFoliage ? 4 : block == .lamp ? 3 : 6
      let tile = TerrainAtlas.tile(block: block, face: face)
      func quad(_ vertices: [Vertex]) {
        let start = UInt32(mesh.positions.count)
        mesh.positions += vertices.map(\.position)
        mesh.normals += Array(repeating: normal, count: 4)
        mesh.textureCoordinates += vertices.map {
          material == 6 ? $0.uv : TerrainAtlas.origin(tile: tile) + $0.uv * TerrainAtlas.repeatSpan
        }
        mesh.indices += [start, start + 1, start + 2, start, start + 2, start + 3]
        mesh.materials += [material, material]
        mesh.repeatingAtlasTiles.append(UInt16(material == 6 ? tile : 0))
      }
      // Convex coplanar pieces retain the quad packing contract. Pair fan
      // triangles into quads; only the last odd triangle needs padding.
      var i = 1
      while i < polygon.count - 1 {
        let a = polygon[0], b = polygon[i], c = polygon[i + 1]
        let u = b.position - a.position, v = c.position - a.position
        let area = SIMD3<Float>(u.y*v.z-u.z*v.y, u.z*v.x-u.x*v.z, u.x*v.y-u.y*v.x)
        if area.x*area.x + area.y*area.y + area.z*area.z <= 1e-12 { i += 1; continue }
        if i + 2 < polygon.count { quad([a, b, c, polygon[i + 2]]); i += 2 }
        else { quad([a, b, c, c]); i += 1 }
      }
    }
    for edge in boundary.edges {
      if Task.isCancelled { return nil }
      let segments = surface(edge)
      precondition(!segments.isEmpty && segments.first!.lower == 0 && segments.last!.upper == 1)
      for i in 1..<segments.count { precondition(segments[i - 1].upper == segments[i].lower) }
      let neighbor = edge.neighbor, axis = edge.horizontalAxis
      let horizontalOrigin = Float(axis == 0 ? edge.x : edge.z)
      let top = min(ChunkData.height, max(chunk.maximumFilledY + 1,
        Int(ceil(segments.map { max($0.firstHeight, $0.lastHeight) }.max()!))))
      for y in ChunkData.minimumY..<top {
        if y & 15 == 0 && Task.isCancelled { return nil }
        let inner = chunk[edge.x, y, edge.z], outer = chunk[neighbor.x, y, neighbor.z]
        if fluids == .retainedSeparately {
          if inner.isLiquid { fluidCells.insert(world(edge.x, y, edge.z)) }
          if outer.isLiquid { fluidCells.insert(world(neighbor.x, y, neighbor.z)) }
        }
        if inner.isStair || inner == .torch || inner == .lantern
          || outer.isStair || outer == .torch || outer == .lantern {
          unsupported.insert(world(edge.x, y, edge.z)); continue
        }
        if fluids == .requireExpansion && (inner.isLiquid || outer.isLiquid) {
          unsupported.insert(world(edge.x, y, edge.z)); continue
        }
        for segment in segments {
          func polygon(face: Int, inside: Bool) -> [Vertex] {
            let owner = inside ? BlockPosition(edge.x, y, edge.z) : .init(neighbor.x, y, neighbor.z)
            let origin = SIMD3<Float>(Float(owner.x), Float(y), Float(owner.z))
            let uvs: [SIMD2<Float>] = [[0,0],[0,1],[1,1],[1,0]]
            var p = (0..<4).map { Vertex(position: VoxelMesher.corners[face][$0] + origin, uv: uvs[$0]) }
            p = clip(p) { $0.position[axis] - horizontalOrigin - segment.lower }
            p = clip(p) { segment.upper - ($0.position[axis] - horizontalOrigin) }
            return clip(p) {
              let delta = $0.position.y - segment.height($0.position[axis] - horizontalOrigin)
              return inside ? delta : -delta
            }
          }
          // The exterior is opaque ground below its sampled surface, air above.
          // Transparent interior cubes retain the ordinary mesher's culling rule.
          if includeMesh && inner != .air && !inner.isLiquid
            && Float(y + 1) > min(segment.firstHeight, segment.lastHeight) {
            append(polygon(face: edge.face, inside: true), block: inner, face: edge.face)
          }
          if !inner.isOpaque && Float(y) < max(segment.firstHeight, segment.lastHeight) {
            // Without a mesh, only a potential cavity needs clipped geometry.
            // Unsupported cells were recorded before reaching this branch.
            // Glass and cutout leaves outside the patch cannot prove a solid
            // wall already exists. In terrain-only mode, fluids transmit too.
            let mayCapCavity = (!outer.isOpaque || outer.isFoliage)
              && Float(y + 1) <= segment.referenceHeight
            if !includeMesh && !mayCapCavity { continue }
            let face = edge.face ^ 1, p = polygon(face: face, inside: false)
            if mayCapCavity && p.count >= 3 {
              let cell = world(neighbor.x, y, neighbor.z), key = FaceKey(cell: cell, face: face)
              cavities.insert(cell)
              let origin = SIMD3<Float>(Float(neighbor.x), Float(y), Float(neighbor.z))
              var minimum = cavityFaces[key]?.minimum ?? SIMD3<Float>(repeating: .infinity)
              var maximum = cavityFaces[key]?.maximum ?? SIMD3<Float>(repeating: -.infinity)
              for vertex in p {
                let local = vertex.position - origin
                for axis in 0..<3 {
                  minimum[axis] = min(minimum[axis], local[axis])
                  maximum[axis] = max(maximum[axis], local[axis])
                }
              }
              cavityFaces[key] = .init(outsideCell: cell, face: face, minimum: minimum, maximum: maximum)
            }
            if includeMesh { append(p, block: segment.material, face: face) }
          }
        }
      }
    }
    func ordered(_ cells: Set<BlockPosition>) -> [BlockPosition] {
      cells.sorted { ($0.x, $0.y, $0.z) < ($1.x, $1.y, $1.z) }
    }
    let faces = cavityFaces.values.sorted {
      let a = $0.outsideCell, b = $1.outsideCell
      return (a.x, a.y, a.z, $0.face) < (b.x, b.y, b.z, $1.face)
    }
    return .init(mesh: mesh, inspection: .init(cavityCells: ordered(cavities), cavityFaces: faces,
      unsupportedCells: ordered(unsupported), fluidBoundaryCells: ordered(fluidCells)))
  }
}

extension TerrainSurfaceSeam {
  /// Immutable voxel data including its halo. Copies retain identity; creating
  /// a source after an edit/reload always gets a new identity. A cache never
  /// relies on a caller remembering to increment a content revision.
  public struct Source: Sendable {
    fileprivate let identity = UUID()
    public let chunk: ChunkData
    public init(_ chunk: ChunkData) { self.chunk = chunk }
  }

  /// Worker/actor-owned cache, with no locks or per-voxel actor calls. It holds
  /// diagnostics and exact coarse edge profiles, not chunks or render buffers.
  /// It does not cache camera visibility or authorize publishing a feature.
  public struct InspectionCache: Sendable {
    public struct Metrics: Sendable {
      public let hits, misses, evictions, bypasses, entries, bytes: Int
    }
    private struct Profile: Equatable, Sendable {
      let edge: VoxelColumnBoundary.Edge
      let segments: [Segment]
    }
    private struct Entry: Sendable {
      let source: UUID
      let fluids: FluidOwnership
      let profiles: [Profile]
      let inspection: Inspection
      var bytes: Int {
        // Logical retained payload plus fixed bookkeeping allowance. This is
        // an admission budget, not a measurement of allocator/process memory.
        160 + MemoryLayout<Self>.stride + profiles.count * MemoryLayout<Profile>.stride
          + profiles.reduce(0) { $0 + $1.segments.count * MemoryLayout<Segment>.stride }
          + (inspection.cavityCells.count + inspection.unsupportedCells.count
            + inspection.fluidBoundaryCells.count) * MemoryLayout<BlockPosition>.stride
          + inspection.cavityFaces.count * MemoryLayout<CavityFace>.stride
      }
    }
    private let maximumBytes, maximumEntries: Int
    private var entries: [ChunkCoordinate: Entry] = [:]
    private var recency = TerrainCacheRecency<ChunkCoordinate>()
    private var bytes = 0, hits = 0, misses = 0, evictions = 0, bypasses = 0
    public var metrics: Metrics {
      .init(hits: hits, misses: misses, evictions: evictions, bypasses: bypasses,
        entries: entries.count, bytes: bytes)
    }
    public init(maximumBytes: Int = 4 * 1_024 * 1_024, maximumEntries: Int = 512) {
      precondition(maximumBytes >= 0 && maximumEntries >= 0)
      self.maximumBytes = maximumBytes; self.maximumEntries = maximumEntries
    }
    public mutating func removeAll() {
      entries.removeAll(); recency = .init(); bytes = 0
    }
    private mutating func remove(_ key: ChunkCoordinate) {
      if let old = entries.removeValue(forKey: key) { bytes -= old.bytes }
      recency.remove(key)
    }
    /// Every profile is compared, including material, reference height and
    /// triangle breakpoints. Ownership changes are represented by exact edges;
    /// edits/halo changes require a new immutable Source. A miss returns fresh
    /// diagnostics even when the result exceeds cache admission limits.
    public mutating func inspect(_ source: Source, boundary: VoxelColumnBoundary,
      fluids: FluidOwnership = .requireExpansion,
      surface: (VoxelColumnBoundary.Edge) -> [Segment]) -> Inspection? {
      if Task.isCancelled { return nil }
      var profiles: [Profile] = []
      for edge in boundary.edges {
        if Task.isCancelled { return nil }
        profiles.append(.init(edge: edge, segments: surface(edge)))
      }
      let key = source.chunk.coordinate
      if let old = entries[key], old.source == source.identity, old.fluids == fluids,
        old.profiles == profiles {
        if Task.isCancelled { return nil }
        hits += 1; recency.touch(key)
        return old.inspection
      }
      misses += 1
      // The boundary's deterministic order avoids a second lookup table. The
      // shared inspector must consume precisely the profiles checked above.
      var next = profiles.makeIterator()
      guard let result = TerrainSurfaceSeam.inspect(source.chunk, boundary: boundary, fluids: fluids,
        surface: { edge in
          let profile = next.next()!
          precondition(profile.edge == edge)
          return profile.segments
        }), !Task.isCancelled else { return nil }
      let entry = Entry(source: source.identity, fluids: fluids, profiles: profiles, inspection: result)
      let cost = entry.bytes
      guard maximumEntries > 0, cost <= maximumBytes else {
        bypasses += 1; return result
      }
      remove(key)
      while entries.count >= maximumEntries || bytes > maximumBytes - cost {
        guard let oldest = recency.oldest else { preconditionFailure("Inspection cache accounting mismatch") }
        remove(oldest); evictions += 1
      }
      entries[key] = entry; bytes += cost; recency.touch(key)
      return result
    }
  }
}
