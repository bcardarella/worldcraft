import Foundation

public struct TerrainTreePlanMetrics: Sendable, Encodable {
  public let entries, inFlight, bytes, limitBytes, hits, misses, sharedWaits, evictions, oversized: Int
}

/// Procedural placements only. Roads, buildings and player edits still resolve
/// in their existing caller-specific order. No renderer or simulation state is
/// retained. Snapshot users hold immutable values across eviction/world travel.
public enum TerrainTreePlans {
  static let regionSize = 64
  static let shared = TreePlanCache()
  public static var metrics: TerrainTreePlanMetrics { shared.metrics }

  enum Order { case xThenZ, zThenX }
  static func trees(x: Range<Int>, z: Range<Int>, terrain: TerrainGenerator,
    order: Order, cache: TreePlanCache = shared) -> [TreeDescriptor] {
    guard !x.isEmpty, !z.isEmpty,
      terrain.style != .dune, terrain.style != .ember, terrain.style != .solar else { return [] }
    var trees: [TreeDescriptor] = []
    if terrain.indexedTrees {
      for rz in floorDivide(z.lowerBound, by: regionSize)...floorDivide(z.upperBound - 1, by: regionSize) {
        if Task.isCancelled { return [] }
        for rx in floorDivide(x.lowerBound, by: regionSize)...floorDivide(x.upperBound - 1, by: regionSize) {
          let key = TreePlanCache.Key(terrain: terrain, coordinate: .init(rx, rz))
          let region = cache.value(for: key) { build(key.coordinate, terrain: terrain) }
          trees.append(contentsOf: region.filter { x.contains($0.x) && z.contains($0.z) })
        }
      }
    } else {
      // Preserve each caller's original loop order without adding a sort to
      // the scalar comparison. tree(atX:z:) stays independent of this index.
      if order == .xThenZ {
        for tx in x {
          if Task.isCancelled { return [] }
          for tz in z { if let tree = terrain.tree(atX: tx, z: tz) { trees.append(tree) } }
        }
      } else {
        for tz in z {
          if Task.isCancelled { return [] }
          for tx in x { if let tree = terrain.tree(atX: tx, z: tz) { trees.append(tree) } }
        }
      }
      return trees
    }
    trees.sort {
      order == .xThenZ ? ($0.x, $0.z) < ($1.x, $1.z) : ($0.z, $0.x) < ($1.z, $1.x)
    }
    return trees
  }

  static func build(_ coordinate: ChunkCoordinate, terrain: TerrainGenerator) -> [TreeDescriptor]? {
    let ox = coordinate.x * regionSize, oz = coordinate.z * regionSize
    let marinas = terrain.cacheVariant == 1
      ? MarinaGenerator.sites(x: ox, z: oz, width: regionSize, terrain: terrain) : []
    let sampler = TerrainColumnSampler(x: ox, z: oz, width: regionSize, terrain: terrain, marinas: marinas)
    var trees: [TreeDescriptor] = []
    for z in oz..<(oz + regionSize) {
      if Task.isCancelled { return nil }
      for x in ox..<(ox + regionSize) {
        if let tree = terrain.tree(atX: x, z: z, column: sampler.column(atX: x, z: z)) {
          trees.append(tree)
        }
      }
    }
    return trees
  }
}

/// Shared misses are deduplicated on bounded preparation workers. Lock scope is
/// metadata only; neither generation nor a per-column query holds the lock.
/// Admission charges the array's actual reserved capacity, not only its count.
final class TreePlanCache: @unchecked Sendable {
  struct Key: Hashable, Sendable {
    let seed: UInt64
    let style: PlanetStyle
    let variant: Int
    let coordinate: ChunkCoordinate
    init(terrain: TerrainGenerator, coordinate: ChunkCoordinate) {
      seed = terrain.seed; style = terrain.style; variant = terrain.cacheVariant; self.coordinate = coordinate
    }
  }
  private struct Entry { let trees: [TreeDescriptor]; let charge: Int }
  private let condition = NSCondition()
  private let limitBytes: Int, limitEntries: Int
  private var entries: [Key: Entry] = [:], inFlight: Set<Key> = []
  private var recency = TerrainCacheRecency<Key>()
  private var bytes = 0, hits = 0, misses = 0, sharedWaits = 0, evictions = 0, oversized = 0
  init(limitBytes: Int = 16 * 1_024 * 1_024, limitEntries: Int = 16_384) {
    precondition(limitBytes > 0 && limitEntries > 0)
    self.limitBytes = limitBytes; self.limitEntries = limitEntries
  }
  static func charge(_ trees: [TreeDescriptor]) -> Int {
    // Fixed admission allowance also bounds negative entries and key/LRU data.
    // This is a cache budget, not a measurement of allocator/process footprint.
    trees.capacity * MemoryLayout<TreeDescriptor>.stride + 256
  }
  func value(for key: Key, build: () -> [TreeDescriptor]?) -> [TreeDescriptor] {
    condition.lock()
    while true {
      if let value = entries[key] {
        hits += 1; recency.touch(key); condition.unlock(); return value.trees
      }
      guard inFlight.contains(key) else { break }
      if Thread.isMainThread || Task.isCancelled {
        condition.unlock(); return build() ?? []
      }
      sharedWaits += 1; condition.wait()
    }
    misses += 1; inFlight.insert(key); condition.unlock()
    let value = build()
    condition.lock()
    if let value, !Task.isCancelled {
      let charge = Self.charge(value)
      if charge <= limitBytes {
        while bytes + charge > limitBytes || entries.count >= limitEntries {
          guard let oldest = recency.oldest else { break }
          bytes -= entries.removeValue(forKey: oldest)!.charge
          recency.remove(oldest); evictions += 1
        }
        entries[key] = .init(trees: value, charge: charge)
        bytes += charge; recency.touch(key)
      } else { oversized += 1 }
    }
    inFlight.remove(key); condition.broadcast(); condition.unlock()
    return value ?? []
  }
  var metrics: TerrainTreePlanMetrics {
    condition.lock(); defer { condition.unlock() }
    return .init(entries: entries.count, inFlight: inFlight.count, bytes: bytes, limitBytes: limitBytes,
      hits: hits, misses: misses, sharedWaits: sharedWaits, evictions: evictions, oversized: oversized)
  }
}
