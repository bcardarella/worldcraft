import Foundation

/// Decoration-independent context. Sports furniture also depends on explicit
/// edits, even when the supplied collision cells have not changed.
struct TerrainBaseKey: Hashable, Sendable {
  let seed: UInt64
  let style: PlanetStyle
  let tile: TerrainTile
  let variant: Int
  let repeatAtlas, instanceSeats: Bool
  let blocks: [TerrainPayloadKey.BlockEdit]
  init(_ key: TerrainPayloadKey) {
    seed = key.seed; style = key.style; tile = key.tile; variant = key.generatorVariant
    repeatAtlas = key.repeatAtlas; instanceSeats = key.instanceSeats; blocks = key.blocks
  }
  var byteCount: Int { blocks.count * MemoryLayout<TerrainPayloadKey.BlockEdit>.stride }
}

/// Complete base geometry and water, before optional surface plants are added.
/// Immutable value arrays use copy-on-write when a worker appends decoration.
struct TerrainBase: Sendable {
  let chunk: ChunkData
  let mesh: VoxelMesh
  let water: WaterGeometry
  var byteCount: Int {
    chunk.archiveCells.count
      + (mesh.positions.count + mesh.normals.count + mesh.lampPositions.count + mesh.firePositions.count)
        * MemoryLayout<SIMD3<Float>>.stride
      + mesh.textureCoordinates.count * MemoryLayout<SIMD2<Float>>.stride
      + (mesh.indices.count + mesh.materials.count) * MemoryLayout<UInt32>.stride
      + mesh.windWeights.count * MemoryLayout<Float>.stride
      + mesh.repeatingAtlasTiles.count * MemoryLayout<UInt16>.stride
      + mesh.stadiumSeats.count * MemoryLayout<StadiumSeatInstance>.stride
      + water.samples.count * MemoryLayout<WaterGeometry.Sample>.stride
      + (water.shallowIndices.count + water.deepIndices.count) * MemoryLayout<UInt32>.stride
  }
  func matches(_ other: ChunkData) -> Bool {
    // Check the actual cells, not a procedural revision or a hash alone. The
    // halo affects face exposure/AO and must participate in this comparison.
    chunk.coordinate == other.coordinate && chunk.maximumFilledY == other.maximumFilledY
      && chunk.archiveCells == other.archiveCells
  }
}

public struct TerrainBaseCacheMetrics: Sendable, Encodable {
  public var enabled = false
  public var entries = 0, bytes = 0, limitBytes = 0, limitEntries = 0
  public var hits = 0, misses = 0, cellMismatches = 0, evictions = 0, oversized = 0
}

/// A reserved portion of the existing CPU cache budget. Only locally detailed
/// plants admit a base, so the whole draw-distance population cannot wash out
/// terrain needed by the next plant-detail downgrade. Contains no renderer API.
final class TerrainBaseCache: @unchecked Sendable {
  private struct Entry { let value: TerrainBase; let bytes: Int }
  private let lock = NSLock()
  private let limitBytes: Int, limitEntries: Int
  private var entries: [TerrainBaseKey: Entry] = [:]
  private var recency = TerrainCacheRecency<TerrainBaseKey>()
  private var counters = TerrainBaseCacheMetrics()
  init(limitBytes: Int, limitEntries: Int = 256) {
    precondition(limitBytes > 0 && limitEntries > 0)
    self.limitBytes = limitBytes; self.limitEntries = limitEntries
    counters.enabled = true; counters.limitBytes = limitBytes; counters.limitEntries = limitEntries
  }
  func value(for key: TerrainBaseKey, chunk: ChunkData) -> TerrainBase? {
    lock.withLock {
      guard let entry = entries[key] else { counters.misses += 1; return nil }
      guard entry.value.matches(chunk) else {
        counters.misses += 1; counters.cellMismatches += 1; return nil
      }
      recency.touch(key); counters.hits += 1
      return entry.value
    }
  }
  func insert(_ value: TerrainBase, for key: TerrainBaseKey) {
    let bytes = value.byteCount + key.byteCount
    lock.withLock {
      guard bytes <= limitBytes else { counters.oversized += 1; return }
      counters.bytes -= entries.removeValue(forKey: key)?.bytes ?? 0
      recency.remove(key)
      while counters.bytes + bytes > limitBytes || entries.count >= limitEntries {
        guard let oldest = recency.oldest else { break }
        counters.bytes -= entries.removeValue(forKey: oldest)!.bytes
        recency.remove(oldest); counters.evictions += 1
      }
      entries[key] = .init(value: value, bytes: bytes); recency.touch(key)
      counters.bytes += bytes
    }
  }
  var metrics: TerrainBaseCacheMetrics {
    lock.withLock { var value = counters; value.entries = entries.count; return value }
  }
}
