import Foundation

/// Immutable regional plans shared by bulk terrain workers. Only dictionary
/// access and eviction are locked. Builders follow the feature dependency DAG:
/// drainage -> settlements -> landmarks/roads -> marinas; never request their
/// own key recursively. Negative results are values and are cached normally.
final class RegionalPlanCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
  struct Entry { let value: Value; var access: UInt64 }
  private let condition = NSCondition()
  private let capacity: Int
  private var entries: [Key: Entry] = [:]
  private var inFlight: Set<Key> = []
  private var clock: UInt64 = 0
  private var hits = 0, misses = 0, sharedWaits = 0, evictions = 0
  init(capacity: Int) { precondition(capacity > 0); self.capacity = capacity }

  func value(for key: Key, build: () -> Value) -> Value {
    condition.lock()
    while true {
      clock &+= 1
      if let entry = entries[key] {
        hits += 1; entries[key]?.access = clock
        condition.unlock(); return entry.value
      }
      if !inFlight.contains(key) { break }
      // Legacy synchronous gameplay queries must not wait on a background
      // worker. They retain their deterministic procedural fallback. Prepared
      // chunks and regional snapshots serve the normal rendering hot path.
      if Thread.isMainThread || Task.isCancelled {
        condition.unlock(); return build()
      }
      sharedWaits += 1
      condition.wait()
    }
    misses += 1; inFlight.insert(key)
    condition.unlock()
    let result = build()
    condition.lock()
    // A cancelled survey may have returned only part of its plan. It cannot
    // poison the cache with a permanent empty/partial region.
    if !Task.isCancelled {
      if entries.count >= capacity, let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
        entries[oldest] = nil; evictions += 1
      }
      clock &+= 1; entries[key] = .init(value: result, access: clock)
    }
    inFlight.remove(key); condition.broadcast(); condition.unlock()
    return result
  }

  var metrics: RegionalCacheMetrics {
    condition.lock(); defer { condition.unlock() }
    return .init(entries: entries.count, inFlight: inFlight.count, hits: hits,
      misses: misses, sharedWaits: sharedWaits, evictions: evictions)
  }
}

public struct RegionalCacheMetrics: Sendable, Encodable {
  public let entries, inFlight, hits, misses, sharedWaits, evictions: Int
}

public enum TerrainRegionalCaches {
  public static var metrics: [String: RegionalCacheMetrics] {
    ["drainage": WorldDrainage.cacheMetrics, "settlements": SettlementGenerator.cacheMetrics,
      "roads": WorldRoads.cacheMetrics, "marinas": MarinaGenerator.cacheMetrics,
      "landmarks": WorldLandmarks.cacheMetrics]
  }
}
