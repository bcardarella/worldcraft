import Foundation

/// The static inputs that actually acquired native water ownership. This is
/// separate from desired/queued water: pending edits cannot rewrite a displayed
/// source. Dry tiles are known empty owners, not missing metadata.
public struct WaterSurfaceSources: Sendable {
  public struct Source: Sendable {
    public let geometry: WaterGeometry
    public let version: UUID
    public var byteCount: Int {
      geometry.samples.count * MemoryLayout<WaterGeometry.Sample>.stride
        + (geometry.shallowIndices.count + geometry.deepIndices.count) * MemoryLayout<UInt32>.stride
    }
  }
  public struct Snapshot: Sendable {
    public let sources: [TerrainTile: Source]
    public let visible: Set<TerrainTile>
    public let byteCount: Int
    fileprivate let lifetime: UUID
    public func owner(containing point: ChunkCoordinate) -> TerrainTile? {
      let fine = TerrainTile(x: point.x, z: point.z, fullDetail: true)
      if sources[fine] != nil { return fine }
      for size in [1, 2, 4, 8, 16, 32] {
        let tile = TerrainTile(x: floorDivide(point.x, by: size) * size,
          z: floorDivide(point.z, by: size) * size, size: size)
        if sources[tile] != nil { return tile }
      }
      return nil
    }
    /// Tokens only. Include negative reads so newly filled coverage invalidates
    /// work that relied on the absence of a source. Missing never means dry.
    public func dependencies(for points: Set<ChunkCoordinate>) -> Lease {
      var versions: [TerrainTile: UUID] = [:], missing = Set<ChunkCoordinate>()
      for point in points {
        if let tile = owner(containing: point) { versions[tile] = sources[tile]!.version }
        else { missing.insert(point) }
      }
      return .init(versions: versions, missing: missing, lifetime: lifetime)
    }
  }
  public struct Lease: Sendable {
    fileprivate let versions: [TerrainTile: UUID]
    fileprivate let missing: Set<ChunkCoordinate>
    fileprivate let lifetime: UUID
    public var sourceCount: Int { versions.count }
    public var missingCount: Int { missing.count }
    public var byteCount: Int {
      versions.count * (MemoryLayout<TerrainTile>.stride + MemoryLayout<UUID>.stride)
        + missing.count * MemoryLayout<ChunkCoordinate>.stride
    }
    public func merging(_ other: Self) -> Self? {
      guard lifetime == other.lifetime else { return nil }
      var union = versions
      for (tile, version) in other.versions {
        guard union[tile] == nil || union[tile] == version else { return nil }
        union[tile] = version
      }
      let index = TerrainOverlapIndex(Set(union.keys))
      guard union.keys.allSatisfy({ index.overlapping($0).count == 1 }) else { return nil }
      let gaps = missing.union(other.missing)
      guard gaps.allSatisfy({ !index.containsOverlap(with: .init(x: $0.x, z: $0.z)) }) else { return nil }
      return .init(versions: union, missing: gaps, lifetime: lifetime)
    }
  }
  public struct Metrics: Sendable, Encodable {
    public var entries = 0, bytes = 0, refused = 0, reused = 0
    public let entryLimit, byteLimit: Int
  }
  private var values: [TerrainTile: Source] = [:]
  private var lifetime = UUID()
  public private(set) var metrics: Metrics
  public init(entryLimit: Int = 2_048, byteLimit: Int = 32 * 1_024 * 1_024) {
    precondition(entryLimit > 0 && byteLimit >= 0)
    metrics = .init(entryLimit: entryLimit, byteLimit: byteLimit)
  }
  /// Call after successful publication, using the exact accepted tile set.
  /// Repacking unchanged inputs preserves their identity. Arrays share storage
  /// with the immutable preparation; limits charge logical arrays, not allocator
  /// overhead, framework copies or snapshots still retained by callers.
  public mutating func install(_ input: WaterGeometryRequests.Preparation, published tiles: Set<TerrainTile>) {
    for tile in tiles {
      guard let geometry = input.geometry[tile], let version = input.version(for: tile) else {
        remove(tile); metrics.refused += 1; continue
      }
      if values[tile]?.version == version { metrics.reused += 1; continue }
      remove(tile)
      let value = Source(geometry: geometry, version: version)
      guard values.count < metrics.entryLimit, value.byteCount <= metrics.byteLimit - metrics.bytes else {
        metrics.refused += 1; continue
      }
      values[tile] = value; metrics.bytes += value.byteCount
    }
    metrics.entries = values.count
  }
  /// Retired request data can still be displayed as fallback. Call this when
  /// native ownership retires, not when a desired request is merely removed.
  public mutating func remove(_ tile: TerrainTile) {
    if let old = values.removeValue(forKey: tile) { metrics.bytes -= old.byteCount }
    metrics.entries = values.count
  }
  public mutating func reset() {
    values.removeAll(); lifetime = UUID()
    metrics = .init(entryLimit: metrics.entryLimit, byteLimit: metrics.byteLimit)
  }
  public func snapshot(visible: Set<TerrainTile>) -> Snapshot? {
    guard visible.count <= metrics.entryLimit else { return nil }
    let index = TerrainOverlapIndex(visible)
    var selected: [TerrainTile: Source] = [:], bytes = 0
    for tile in visible {
      guard let source = values[tile], index.overlapping(tile).count == 1 else { return nil }
      selected[tile] = source; bytes += source.byteCount
    }
    return .init(sources: selected, visible: visible, byteCount: bytes, lifetime: lifetime)
  }
  public func isCurrent(_ snapshot: Snapshot, visible: Set<TerrainTile>) -> Bool {
    snapshot.lifetime == lifetime && snapshot.visible == visible
      && snapshot.sources.allSatisfy { values[$0.key]?.version == $0.value.version }
  }
  /// Like the terrain lease, this assumes the renderer supplies a valid,
  /// nonoverlapping coverage partition. Voxel/edit/view validity is separate.
  public func isCurrent(_ lease: Lease, visible: Set<TerrainTile>) -> Bool {
    guard lease.lifetime == lifetime,
      lease.versions.allSatisfy({ visible.contains($0.key) && values[$0.key]?.version == $0.value }) else { return false }
    if lease.missing.isEmpty { return true }
    let index = TerrainOverlapIndex(visible)
    return lease.missing.allSatisfy { !index.containsOverlap(with: .init(x: $0.x, z: $0.z)) }
  }
}

extension WaterSurfaceSources {
  /// Worker-owned decoder for the current regular-grid source representation.
  /// It preserves original samples, triangle diagonal and shallow/deep band.
  /// Unsupported topology is explicit; it cannot turn into invented dry cells.
  public struct Reader: Sendable {
    public enum Failure: String, Sendable { case missingSource, invalidTopology, limitExceeded, cancelled }
    public struct Limits: Sendable {
      public let tiles, cells, readChunks, bytes: Int
      public init(tiles: Int = 512, cells: Int = 65_536, readChunks: Int = 65_536, bytes: Int = 16 * 1_024 * 1_024) {
        precondition(tiles >= 0 && cells >= 0 && readChunks >= 0 && bytes >= 0)
        self.tiles = tiles; self.cells = cells; self.readChunks = readChunks; self.bytes = bytes
      }
    }
    public let snapshot: Snapshot
    private let limits: Limits
    private var decoded: [TerrainTile: [WaterSurfaceRefinement.CellKey: WaterSurfaceRefinement.Cell]] = [:]
    private var reads = Set<ChunkCoordinate>()
    public private(set) var failure: Failure?
    public private(set) var decodedCells = 0, byteCount = 0
    public var decodedTiles: Int { decoded.count }
    public var lease: Lease { snapshot.dependencies(for: reads) }
    public init(_ snapshot: Snapshot, limits: Limits = .init()) { self.snapshot = snapshot; self.limits = limits }
    /// This is the source grid produced by WaterPatch/TerrainSurface. Future
    /// arbitrary replacement meshes need their own descriptor/decoder.
    public static func stride(for tile: TerrainTile) -> Int {
      if tile.fullDetail { return 1 }
      return tile.sampleStride * (tile.size >= 4 ? max(2, 4 / tile.sampleStride) : max(1, 2 / tile.sampleStride))
    }
    private mutating func read(_ point: ChunkCoordinate) -> Bool {
      guard failure == nil else { return false }
      if !reads.contains(point) {
        guard reads.count < limits.readChunks else { failure = .limitExceeded; return false }
        reads.insert(point)
      }
      return true
    }
    public mutating func cell(at point: WaterSurfaceRefinement.Point) -> WaterSurfaceRefinement.Cell? {
      let coordinate = ChunkCoordinate(floorDivide(point.x, by: 16), floorDivide(point.z, by: 16))
      guard read(coordinate) else { return nil }
      guard let tile = snapshot.owner(containing: coordinate) else { failure = .missingSource; return nil }
      guard let cells = originalCells(for: tile) else { return nil }
      let step = Self.stride(for: tile)
      let key = WaterSurfaceRefinement.CellKey(x: floorDivide(point.x, by: step) * step,
        z: floorDivide(point.z, by: step) * step, size: step)
      return cells[key] ?? .init(key: key, corners: nil, shallow: false)
    }
    public mutating func originalCells(for tile: TerrainTile) -> [WaterSurfaceRefinement.CellKey: WaterSurfaceRefinement.Cell]? {
      guard read(tile.coordinate) else { return nil }
      if let held = decoded[tile] { return held }
      guard let source = snapshot.sources[tile] else { failure = .missingSource; return nil }
      guard decoded.count < limits.tiles else { failure = .limitExceeded; return nil }
      guard tile.x > Int.min / 16 + 64, tile.x < Int.max / 16 - 64,
        tile.z > Int.min / 16 + 64, tile.z < Int.max / 16 - 64 else { failure = .invalidTopology; return nil }
      if Task.isCancelled { failure = .cancelled; return nil }
      let geometry = source.geometry, step = Self.stride(for: tile)
      var cells: [WaterSurfaceRefinement.CellKey: WaterSurfaceRefinement.Cell] = [:]
      var bytes = 0
      for shallow in [true, false] {
        let indices = shallow ? geometry.shallowIndices : geometry.deepIndices
        guard indices.count % 6 == 0 else { failure = .invalidTopology; return nil }
        for i in Swift.stride(from: 0, to: indices.count, by: 6) {
          if Task.isCancelled { failure = .cancelled; return nil }
          let ids = Array(indices[i..<(i+6)])
          guard ids.allSatisfy({ Int($0) < geometry.samples.count }), ids[2] == ids[3], ids[1] == ids[4] else {
            failure = .invalidTopology; return nil
          }
          let vertices = [ids[0], ids[1], ids[2], ids[5]].map { geometry.samples[Int($0)] }
          let first = vertices[0].position
          guard first.x.isFinite, first.y.isFinite, first.x >= 0, first.y >= 0,
            first.x < Float(tile.blockSize), first.y < Float(tile.blockSize),
            first.x.truncatingRemainder(dividingBy: Float(step)) == 0,
            first.y.truncatingRemainder(dividingBy: Float(step)) == 0,
            vertices.map(\.position) == [first, first + [0, Float(step)], first + [Float(step), 0],
              first + SIMD2<Float>(repeating: Float(step))] else { failure = .invalidTopology; return nil }
          let samples = vertices.map { WaterSurfaceRefinement.Sample(depth: $0.depth, body: $0.body, wet: true) }
          guard samples.allSatisfy(\.valid) else { failure = .invalidTopology; return nil }
          let key = WaterSurfaceRefinement.CellKey(x: tile.x*16+Int(first.x), z: tile.z*16+Int(first.y), size: step)
          guard cells[key] == nil else { failure = .invalidTopology; return nil }
          let cost = MemoryLayout<WaterSurfaceRefinement.CellKey>.stride
            + MemoryLayout<WaterSurfaceRefinement.Cell>.stride + samples.count * MemoryLayout<WaterSurfaceRefinement.Sample>.stride
          guard decodedCells + cells.count < limits.cells, cost <= limits.bytes - byteCount - bytes else {
            failure = .limitExceeded; return nil
          }
          cells[key] = .init(key: key, corners: samples, shallow: shallow); bytes += cost
        }
      }
      if Task.isCancelled { failure = .cancelled; return nil }
      decoded[tile] = cells; decodedCells += cells.count; byteCount += bytes
      return cells
    }
  }
}
