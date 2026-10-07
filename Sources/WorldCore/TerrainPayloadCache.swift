import Foundation

/// Content equality includes the neighbour edits supplied to halo meshing.
/// Lifecycle/incarnation tokens govern publication, not reusable geometry.
struct TerrainPayloadKey: Hashable, Sendable {
  struct BlockEdit: Hashable, Sendable { let position: BlockPosition; let block: Block }
  struct PlantChange: Hashable, Sendable { let position: BlockPosition; let kind: PlantKind? }
  let seed: UInt64
  let style: PlanetStyle
  let tile: TerrainTile
  let lush: Bool
  let repeatAtlas: Bool
  let instanceSeats: Bool
  let profileSurface: Bool
  let generatorVariant: Int
  let generationVersion = 2
  let representationVersion: Int
  let atlasVersion = 1
  let blocks: [BlockEdit]
  let plants: [PlantChange]
  init(_ request: TerrainPreparationRequest) {
    seed = request.terrain.seed; style = request.terrain.style
    tile = request.id.tile; lush = request.id.lush
    repeatAtlas = request.id.repeatAtlas
    instanceSeats = request.id.instanceSeats; profileSurface = request.id.profileSurface
    // Solid additions and optional profiling remain separate representations.
    let orderedAdditions = !request.id.tile.fullDetail
      && request.edits.contains { request.id.tile.contains($0.key.chunk) && $0.value.isSolid }
    // Water rims now use canonical world-space bodies instead of a stride-
    // dependent neighbour/ocean fallback. Old cached water must be rebuilt.
    let previous = orderedAdditions ? (profileSurface ? 12 : 10) : (profileSurface ? 11 : 9)
    // Coarse payloads now carry ground samples from the exact rendered build.
    // Full-detail archives retain their existing format/content identity.
    representationVersion = previous + (tile.fullDetail ? 0 : 4)
    generatorVariant = request.terrain.cacheVariant
    blocks = request.edits.map { BlockEdit(position: $0.key, block: $0.value) }.sorted {
      ($0.position.x, $0.position.y, $0.position.z) < ($1.position.x, $1.position.y, $1.position.z)
    }
    plants = request.plantEdits.map { PlantChange(position: $0.key, kind: $0.value.kind) }.sorted {
      ($0.position.x, $0.position.y, $0.position.z) < ($1.position.x, $1.position.y, $1.position.z)
    }
  }
  var byteCount: Int { blocks.count * MemoryLayout<BlockEdit>.stride + plants.count * MemoryLayout<PlantChange>.stride }
}

public struct TerrainPayloadCacheMetrics: Sendable, Encodable {
  public let entries, bytes, limitBytes, hits, misses, evictions, oversized: Int
}

/// CPU payload reuse is separately bounded from ready jobs, voxel collision
/// state and GPU residency. Cached immutable arrays share storage with live data;
/// charging their full size is a conservative bound. No renderer calls or I/O.
final class TerrainPayloadCache: @unchecked Sendable {
  let base: TerrainBaseCache?
  private struct Entry { let value: PreparedTerrainTile; let bytes: Int }
  private let lock = NSLock()
  private let limitBytes: Int, limitEntries: Int
  private var entries: [TerrainPayloadKey: Entry] = [:]
  private var bytes = 0, hits = 0, misses = 0, evictions = 0, oversized = 0
  private var recency = TerrainCacheRecency<TerrainPayloadKey>()
  init(limitBytes: Int = 64 * 1_024 * 1_024, limitEntries: Int = 512, baseBytes: Int = 0) {
    precondition(limitBytes > baseBytes && baseBytes >= 0 && limitEntries > 0)
    self.limitBytes = limitBytes - baseBytes; self.limitEntries = limitEntries
    base = baseBytes > 0 ? .init(limitBytes: baseBytes) : nil
  }
  func value(for key: TerrainPayloadKey) -> PreparedTerrainTile? {
    lock.lock(); defer { lock.unlock() }
    guard let entry = entries[key] else { misses += 1; return nil }
    recency.touch(key); hits += 1
    return entry.value
  }
  func insert(_ value: PreparedTerrainTile, for key: TerrainPayloadKey) {
    let cost = value.byteCount + key.byteCount
    lock.lock(); defer { lock.unlock() }
    guard cost <= limitBytes else { oversized += 1; return }
    bytes -= entries.removeValue(forKey: key)?.bytes ?? 0
    recency.remove(key)
    while bytes + cost > limitBytes || entries.count >= limitEntries {
      guard let oldest = recency.oldest else { break }
      bytes -= entries.removeValue(forKey: oldest)!.bytes; evictions += 1
      recency.remove(oldest)
    }
    entries[key] = .init(value: value, bytes: cost); recency.touch(key); bytes += cost
  }
  var metrics: TerrainPayloadCacheMetrics {
    lock.lock(); defer { lock.unlock() }
    return .init(entries: entries.count, bytes: bytes, limitBytes: limitBytes,
      hits: hits, misses: misses, evictions: evictions, oversized: oversized)
  }
}
