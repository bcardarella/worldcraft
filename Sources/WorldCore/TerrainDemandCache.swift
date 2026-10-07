/// Reuses immutable inputs for the *same admitted work*, not generated output.
/// Scheduling changes may reprioritize that work without rebuilding edit and
/// voxel snapshots. Every content change must get a new TerrainWorkID, just as
/// required by TerrainStreamingExchange/Coordinator's stale-result checks.
/// The renderer owns this value; no locks, actor hops or I/O are required.
public struct TerrainDemandCache: Sendable {
  public struct Metrics: Sendable, Encodable {
    public let enabled: Bool
    public let entries, logicalInputBytes, limitEntries, limitBytes: Int
    public let reused, rebuilt, released, refusedAdmissions, bypassed: Int
  }
  private struct Entry: Sendable {
    let request: TerrainPreparationRequest
    let bytes: Int
  }
  public let enabled: Bool
  public let limitEntries, limitBytes: Int
  private var entries: [TerrainTile: Entry] = [:]
  private var bytes = 0, reused = 0, rebuilt = 0, released = 0, refusedAdmissions = 0, bypassed = 0

  public init(enabled: Bool = true, limitEntries: Int = 2_048, limitBytes: Int = 32 * 1_024 * 1_024) {
    precondition(limitEntries >= 0 && limitBytes >= 0)
    self.enabled = enabled; self.limitEntries = limitEntries; self.limitBytes = limitBytes
  }
  public var metrics: Metrics {
    .init(enabled: enabled, entries: entries.count, logicalInputBytes: bytes,
      limitEntries: limitEntries, limitBytes: limitBytes, reused: reused,
      rebuilt: rebuilt, released: released, refusedAdmissions: refusedAdmissions, bypassed: bypassed)
  }
  /// Counts owned input values, even when COW storage is shared with an actor
  /// or an authoritative chunk. It excludes dictionary/allocator overhead and
  /// is not a measurement of additional process memory.
  public static func logicalInputBytes(_ request: TerrainPreparationRequest) -> Int {
    MemoryLayout<TerrainPreparationRequest>.stride
      + request.edits.count * (MemoryLayout<BlockPosition>.stride + MemoryLayout<Block>.stride)
      + request.plantEdits.count * (MemoryLayout<BlockPosition>.stride + MemoryLayout<PlantEdit>.stride)
      + (request.cachedChunk == nil ? 0 : 18 * 18 * (ChunkData.height - ChunkData.minimumY))
  }
  /// `create` is lazy: on a hit only service/priority change. Do not capture a
  /// prebuilt edit dictionary outside it. Capacity refusal rebuilds normally;
  /// it never discards requested work or substitutes older input.
  /// Callers may bypass reuse when input is already cheap (for example, no
  /// persisted block edits). That also releases any formerly held input.
  public mutating func request(id: TerrainWorkID, service: TerrainWorkClass, priority: Int,
    cacheInputs: Bool = true,
    create: () -> TerrainPreparationRequest) -> TerrainPreparationRequest {
    if !enabled || !cacheInputs {
      if !entries.isEmpty { invalidate(id.tile) }
      rebuilt += 1; bypassed += 1
      let fresh = create()
      precondition(fresh.id == id, "Terrain input provider returned another work identity")
      return Self.scheduling(fresh, service: service, priority: priority)
    }
    if enabled, let held = entries[id.tile], held.request.id == id {
      reused += 1
      return Self.scheduling(held.request, service: service, priority: priority)
    }
    invalidate(id.tile)
    rebuilt += 1
    let fresh = create()
    precondition(fresh.id == id, "Terrain input provider returned another work identity")
    if enabled {
      let charge = Self.logicalInputBytes(fresh)
      if entries.count < limitEntries && charge <= limitBytes - bytes {
        entries[id.tile] = .init(request: fresh, bytes: charge); bytes += charge
      } else { refusedAdmissions += 1 }
    }
    return Self.scheduling(fresh, service: service, priority: priority)
  }
  private static func scheduling(_ value: TerrainPreparationRequest, service: TerrainWorkClass,
    priority: Int) -> TerrainPreparationRequest {
    .init(id: value.id, terrain: value.terrain, edits: value.edits, plantEdits: value.plantEdits,
      cachedChunk: value.cachedChunk, service: service, priority: priority)
  }
  public mutating func invalidate(_ tile: TerrainTile) {
    if let old = entries.removeValue(forKey: tile) { bytes -= old.bytes; released += 1 }
  }
  /// Drop obsolete values before admitting the next queue. An equal tile with
  /// a different revision, incarnation, world or representation is obsolete.
  public mutating func retain(_ accepted: [TerrainTile: TerrainWorkID]) {
    let expired = entries.compactMap { key, entry in accepted[key] == entry.request.id ? nil : key }
    for tile in expired { invalidate(tile) }
  }
  public mutating func reset() {
    entries.removeAll(keepingCapacity: true)
    bytes = 0; reused = 0; rebuilt = 0; released = 0; refusedAdmissions = 0; bypassed = 0
  }
}
