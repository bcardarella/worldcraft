/// Capacity classes retain at most 25% rounding overhead above the small-buffer
/// quantum. Terrain stays spatially split into its existing tiles/mesh parts.
public struct TerrainMeshCapacity: Hashable, Sendable {
  public let vertices: Int
  public let indices: Int
  public var bytes: Int { vertices * MemoryLayout<TerrainVertex>.stride + indices * 4 }
  public init(vertices: Int, indices: Int, rounded: Bool = true) {
    precondition(vertices >= 0 && indices >= 0)
    self.vertices = rounded ? Self.bucket(vertices, minimum: 64) : vertices
    self.indices = rounded ? Self.bucket(indices, minimum: 96) : indices
  }
  private static func bucket(_ count: Int, minimum: Int) -> Int {
    guard count > 0 else { return 0 }
    guard count > minimum else { return minimum }
    let power = 1 << (Int.bitWidth - 1 - count.leadingZeroBitCount)
    let quantum = max(1, power / 4)
    return ((count + quantum - 1) / quantum) * quantum
  }
  public func fits(_ demand: Self) -> Bool {
    vertices >= demand.vertices && indices >= demand.indices
      && bytes <= max(demand.bytes, 1) * 3 / 2
  }
}

public struct TerrainMeshReuseMetrics: Sendable, Encodable {
  public let entries, bytes, limitEntries, limitBytes, hits, misses, rejected: Int
}

/// One owner removes a value before reusing it. Rejected values remain the
/// caller's responsibility, allowing their destruction to use a paced queue.
/// This value type has no executor; RealityKit users keep it on MainActor.
public struct TerrainMeshReuseCache<Value> {
  private struct Entry { let value: Value; let capacity: TerrainMeshCapacity; let storedAt: Double }
  private var entries: [Entry] = []
  private var bytes = 0, hits = 0, misses = 0, rejected = 0
  public let limitBytes, limitEntries: Int
  public init(limitBytes: Int = 32 * 1_024 * 1_024, limitEntries: Int = 64) {
    precondition(limitBytes >= 0 && limitEntries >= 0)
    self.limitBytes = limitBytes; self.limitEntries = limitEntries
  }
  public mutating func take(fitting demand: TerrainMeshCapacity) -> Value? {
    var candidate: Int?
    for index in entries.indices where entries[index].capacity.fits(demand) {
      if candidate == nil || entries[index].capacity.bytes < entries[candidate!].capacity.bytes { candidate = index }
    }
    guard let index = candidate else { misses += 1; return nil }
    hits += 1
    let entry = entries.remove(at: index); bytes -= entry.capacity.bytes
    return entry.value
  }
  @discardableResult public mutating func offer(_ value: Value, capacity: TerrainMeshCapacity, at time: Double) -> Bool {
    guard capacity.bytes > 0, capacity.bytes <= limitBytes - bytes, entries.count < limitEntries else {
      rejected += 1; return false
    }
    entries.append(.init(value: value, capacity: capacity, storedAt: time)); bytes += capacity.bytes
    return true
  }
  /// Expire one entry, not an entire bucket/cache, so a change of scenery cannot
  /// release a pile of unused rendering resources in one frame.
  public mutating func takeExpired(before time: Double) -> Value? {
    guard let index = entries.indices.first(where: { entries[$0].storedAt <= time }) else { return nil }
    let entry = entries.remove(at: index); bytes -= entry.capacity.bytes
    return entry.value
  }
  public var metrics: TerrainMeshReuseMetrics {
    .init(entries: entries.count, bytes: bytes, limitEntries: limitEntries, limitBytes: limitBytes,
      hits: hits, misses: misses, rejected: rejected)
  }
}

public struct TerrainRetirementMetrics: Sendable, Encodable {
  public let entries, bytes, highWaterEntries, highWaterBytes: Int
  public let peakEntries, peakBytes, completed: Int
  public let oldestAgeMilliseconds: Double
  public var appliesBackpressure: Bool { entries >= highWaterEntries || bytes >= highWaterBytes }
}

/// Retiring objects already belong to the live scene; this queue doesn't create
/// copies. An atomic LOD/planet switch may move a whole old scene here at once.
/// High-water marks stop subsequent mesh admission while it drains, rather than
/// forcing that old scene's entire destruction into the switch frame.
public struct TerrainRetirementQueue<Value> {
  private struct Entry { let value: Value; let bytes: Int; let time: Double }
  private var entries: [Entry?] = []
  private var head = 0, bytes = 0, peakEntries = 0, peakBytes = 0, completed = 0
  public let highWaterEntries, highWaterBytes: Int
  public init(highWaterEntries: Int = 128, highWaterBytes: Int = 64 * 1_024 * 1_024) {
    precondition(highWaterEntries > 0 && highWaterBytes > 0)
    self.highWaterEntries = highWaterEntries; self.highWaterBytes = highWaterBytes
  }
  public var isEmpty: Bool { head == entries.count }
  public var count: Int { entries.count - head }
  public var appliesBackpressure: Bool { count >= highWaterEntries || bytes >= highWaterBytes }
  public mutating func append(_ value: Value, bytes cost: Int, at time: Double) {
    precondition(cost >= 0)
    entries.append(.init(value: value, bytes: cost, time: time)); bytes += cost
    peakEntries = max(peakEntries, count); peakBytes = max(peakBytes, bytes)
  }
  public mutating func popFirst() -> Value? {
    guard let entry = entries.indices.contains(head) ? entries[head] : nil else { return nil }
    entries[head] = nil; head += 1; bytes -= entry.bytes; completed += 1
    if head >= 128 && head * 2 >= entries.count {
      entries.removeFirst(head); head = 0
    }
    if isEmpty { entries.removeAll(keepingCapacity: true); head = 0 }
    return entry.value
  }
  public func metrics(at time: Double) -> TerrainRetirementMetrics {
    let first = entries.indices.contains(head) ? entries[head]?.time : nil
    return .init(entries: count, bytes: bytes, highWaterEntries: highWaterEntries, highWaterBytes: highWaterBytes,
      peakEntries: peakEntries, peakBytes: peakBytes, completed: completed,
      oldestAgeMilliseconds: first.map { max(0, time - $0) * 1_000 } ?? 0)
  }
}
