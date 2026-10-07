import Foundation

/// Nearby water shares 4-chunk (32 metre) regions. Coarser water shares at most
/// a 2-by-2 group of its existing LOD tiles; distant regions stay independently
/// cullable instead of combining the entire ocean into one mesh.
public struct WaterBatchKey: Hashable, Sendable {
  public let x, z, size: Int
  public init(_ tile: TerrainTile) {
    size = max(4, tile.size * 2)
    x = floorDivide(tile.x, by: size) * size
    z = floorDivide(tile.z, by: size) * size
  }
  public var origin: SIMD3<Float> { [Float(x * 16), 0, Float(z * 16)] }
  public var center: SIMD3<Float> { origin + [Float(size * 8), 0, Float(size * 8)] }
}

/// These layouts are shared with WaterAnimation.metal.txt.
public struct WaterMeshSource: Sendable {
  public var geometry: SIMD4<Float>
  public var identity: SIMD4<UInt32>
}
public struct WaterMeshVertex: Sendable {
  public var px, py, pz: Float
  public var uv: SIMD2<Float>
  public var normal, tangent, bitangent: SIMD4<UInt16>
  public var detailUV: SIMD2<Float>
  public var optics: SIMD4<UInt16>
}

/// Packing changes neither triangle topology nor wave sampling. Indices are
/// ordered by transparency and depth so adjacent parts with identical haze can
/// share a draw without combining distant regions or changing any material.
public struct WaterMeshBatch: Sendable {
  public struct Slice: Sendable {
    public let tile: TerrainTile
    public let indexStart, indexCount, depth: Int
    public let minimum, maximum: SIMD3<Float>
  }
  public struct Part: Equatable, Sendable {
    public var indexStart, indexCount, materialIndex: Int
    public var minimum, maximum: SIMD3<Float>
  }
  public let key: WaterBatchKey
  public let tiles: Set<TerrainTile>
  public private(set) var sources: [WaterMeshSource] = []
  public private(set) var indices: [UInt32] = []
  public private(set) var slices: [Slice] = []
  private var sourceRanges: [TerrainTile: Range<Int>] = [:]

  private init(key: WaterBatchKey, tiles: Set<TerrainTile>) {
    self.key = key; self.tiles = tiles
  }

  public init(key: WaterBatchKey, geometry: [TerrainTile: WaterGeometry]) {
    precondition(geometry.keys.allSatisfy { WaterBatchKey($0) == key })
    self.key = key; tiles = Set(geometry.keys)
    let ordered = geometry.keys.sorted {
      if $0.fullDetail != $1.fullDetail { return $0.fullDetail }
      if $0.z != $1.z { return $0.z < $1.z }
      if $0.x != $1.x { return $0.x < $1.x }
      return $0.size < $1.size
    }
    sources.reserveCapacity(geometry.values.reduce(0) { $0 + $1.samples.count })
    indices.reserveCapacity(geometry.values.reduce(0) { $0 + $1.shallowIndices.count + $1.deepIndices.count })
    for tile in ordered {
      let offset = tile.origin - key.origin
      let start = sources.count
      for sample in geometry[tile]!.samples {
        sources.append(.init(
          geometry: [sample.position.x + offset.x, sample.position.y + offset.z, sample.depth, sample.body.level],
          identity: [UInt32(truncatingIfNeeded: sample.body.id), UInt32(truncatingIfNeeded: sample.body.id >> 32),
            UInt32(sample.body.kind.rawValue), UInt32(Float16(sample.body.current.x).bitPattern)
              | UInt32(Float16(sample.body.current.z).bitPattern)<<16]))
      }
      sourceRanges[tile] = start..<sources.count
    }
    for fullDetail in [true, false] { for depth in 0...1 {
      for tile in ordered where tile.fullDetail == fullDetail {
        let water = geometry[tile]!
        let selected = depth == 0 ? water.shallowIndices : water.deepIndices
        guard !selected.isEmpty else { continue }
        let start = indices.count, offset = UInt32(sourceRanges[tile]!.lowerBound)
        indices.append(contentsOf: selected.map { $0 + offset })
        let origin = tile.origin - key.origin
        var low = Float.infinity, high = -Float.infinity
        for sample in water.samples {
          let envelope = WaterWaveEnvelope.verticalRange(depth: sample.depth, body: sample.body)
          low = min(low, envelope.lowerBound); high = max(high, envelope.upperBound)
        }
        slices.append(.init(tile: tile, indexStart: start, indexCount: selected.count, depth: depth,
          minimum: origin + [0, low, 0],
          maximum: origin + [Float(tile.blockSize), high, Float(tile.blockSize)]))
      }
    } }
  }

  /// Remove permanently rejected members of an asynchronous preparation before
  /// upload. Copy the already evaluated vertices and rebase indices; coordinates,
  /// waves, depth/material ordering and bounds stay identical. This is NOT view
  /// culling: hidden but current tiles must remain available for later coverage.
  /// The usual all-accepted path shares the immutable arrays without copying.
  public func retaining(_ accepted: Set<TerrainTile>, vertices: [WaterMeshVertex])
    -> (batch: WaterMeshBatch, vertices: [WaterMeshVertex]) {
    precondition(vertices.count == sources.count)
    let selected = tiles.intersection(accepted)
    guard selected != tiles else { return (self, vertices) }
    var batch = Self(key: key, tiles: selected)
    var output: [WaterMeshVertex] = []
    let ranges = sourceRanges.filter { selected.contains($0.key) }
    let count = ranges.values.reduce(0) { $0 + $1.count }
    batch.sources.reserveCapacity(count); output.reserveCapacity(count)
    // Samples of each tile are contiguous. Empty ranges carry dry ownership
    // without allocating a mesh; their relative ordering cannot affect indices.
    for (tile, range) in ranges.sorted(by: { $0.value.lowerBound < $1.value.lowerBound }) {
      let start = batch.sources.count
      batch.sources.append(contentsOf: sources[range])
      output.append(contentsOf: vertices[range])
      batch.sourceRanges[tile] = start..<batch.sources.count
    }
    let keptSlices = slices.filter { selected.contains($0.tile) }
    batch.indices.reserveCapacity(keptSlices.reduce(0) { $0 + $1.indexCount })
    for slice in keptSlices {
      let before = UInt32(sourceRanges[slice.tile]!.lowerBound)
      let after = UInt32(batch.sourceRanges[slice.tile]!.lowerBound)
      let start = batch.indices.count
      for index in indices[slice.indexStart..<(slice.indexStart + slice.indexCount)] {
        batch.indices.append(index - before + after)
      }
      batch.slices.append(.init(tile: slice.tile, indexStart: start, indexCount: slice.indexCount,
        depth: slice.depth, minimum: slice.minimum, maximum: slice.maximum))
    }
    return (batch, output)
  }

  /// Material slots 0...41 are transparent (21 haze bands × 2 depths),
  /// 42...83 are their opaque horizon equivalents. Hidden slices stay hidden.
  public func parts(visible: Set<TerrainTile>, bands: [TerrainTile: Int], continuousDepth: Bool = false) -> [Part] {
    var result: [Part] = []
    for slice in slices where visible.contains(slice.tile) {
      let material = (slice.tile.fullDetail ? 0 : 42) + min(20, max(0, bands[slice.tile] ?? 0)) * 2
        + (continuousDepth ? 0 : slice.depth)
      if let last = result.last, last.materialIndex == material,
        last.indexStart + last.indexCount == slice.indexStart {
        let i = result.count - 1
        result[i].indexCount += slice.indexCount
        for axis in 0..<3 {
          result[i].minimum[axis] = min(last.minimum[axis], slice.minimum[axis])
          result[i].maximum[axis] = max(last.maximum[axis], slice.maximum[axis])
        }
      } else {
        result.append(.init(indexStart: slice.indexStart, indexCount: slice.indexCount, materialIndex: material,
          minimum: slice.minimum, maximum: slice.maximum))
      }
    }
    return result
  }

  public func vertices(environment: WorldEnvironment) -> [WaterMeshVertex] {
    let t = Float(environment.elapsed.truncatingRemainder(dividingBy: 10_000))
    func packed(_ v: SIMD3<Float>) -> SIMD4<UInt16> {
      [Float16(v.x).bitPattern, Float16(v.y).bitPattern, Float16(v.z).bitPattern, 0]
    }
    func normalized(_ v: SIMD3<Float>) -> SIMD3<Float> {
      v / (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
    }
    return sources.map { source in
      let body = WaterBody(id: UInt64(source.identity.x) | UInt64(source.identity.y) << 32,
        kind: WaterBodyKind(rawValue: Int(source.identity.z))!, level: source.geometry.w,
        current:[Float(Float16(bitPattern:UInt16(truncatingIfNeeded:source.identity.w))),0,
          Float(Float16(bitPattern:UInt16(truncatingIfNeeded:source.identity.w>>16)))])
      let wave = environment.water(atX: key.origin.x + source.geometry.x,
        z: key.origin.z + source.geometry.y, depth: source.geometry.z, body: body)
      let dx = -wave.normal.x / wave.normal.y, dz = -wave.normal.z / wave.normal.y
      let scale: Float = body.kind == .lava ? 0.0625 : 0.1
      let current = body.kind == .river ? -SIMD2(body.current.x,body.current.z)*scale
        : SIMD2<Float>(body.kind == .lava ? 0.002:0.008,body.kind == .lava ? -0.0012:-0.004)
      let flow = SIMD2<Float>(key.origin.x,key.origin.z)*scale + t*current
      let fraction = flow - SIMD2<Float>(floor(flow.x), floor(flow.y))
      let detailFlow = SIMD2<Float>(key.origin.x, key.origin.z) * 0.27
        + (body.kind == .river ? -SIMD2(body.current.x,body.current.z)*0.27:SIMD2<Float>(-0.012,0.01))*t
      let detailFraction = detailFlow - SIMD2<Float>(floor(detailFlow.x), floor(detailFlow.y))
      let optics = WaterAppearance.optics(depth: source.geometry.z, body: body, sample: wave)
      return .init(px: source.geometry.x, py: wave.height, pz: source.geometry.y,
        uv: SIMD2<Float>(source.geometry.x, source.geometry.y) * scale + fraction,
        normal: packed(wave.normal), tangent: packed(normalized([1, dx, 0])), bitangent: packed(normalized([0, dz, 1])),
        detailUV: SIMD2<Float>(source.geometry.x, source.geometry.y) * 0.27 + detailFraction,
        optics: [Float16(optics.x).bitPattern, Float16(optics.y).bitPattern,
          Float16(optics.z).bitPattern, Float16(optics.w).bitPattern])
    }
  }
}

/// Pure CPU packing and initial analytic wave evaluation never run in a frame.
public actor WaterMeshPreparation {
  public init() {}
  public func animate(_ batches: [UUID: WaterMeshBatch], environment: WorldEnvironment) -> [UUID: [WaterMeshVertex]] {
    batches.mapValues { $0.vertices(environment: environment) }
  }
  public func prepare(key: WaterBatchKey, geometry: [TerrainTile: WaterGeometry],
    environment: WorldEnvironment) -> (WaterMeshBatch, [WaterMeshVertex]) {
    let batch = WaterMeshBatch(key: key, geometry: geometry)
    return (batch, batch.vertices(environment: environment))
  }
}

/// Water publications may lag terrain uploads. Retain old parents until every
/// replacement (including dry tiles) is ready; never show both LODs together.
public struct WaterPresentationCoverage: Sendable {
  public private(set) var visible: Set<TerrainTile> = []
  public init() {}
  public mutating func update(desired: Set<TerrainTile>, available: Set<TerrainTile>) {
    let candidates = available.intersection(desired.union(visible))
    visible = TerrainCoverage(desired: desired, available: candidates).visible
  }
}
