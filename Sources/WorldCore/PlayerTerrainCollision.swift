/// Collision queries are about world data, not whether a mesh has reached the
/// GPU. Prepared voxel data wins; a bounded read-through cache covers terrain
/// the player reaches before its streaming job has finished.
public struct PlayerTerrainCollision: Sendable {
  public let capacity: Int
  private var blocks: [BlockPosition: Block] = [:]
  private var order: [BlockPosition] = []
  private var oldest = 0
  private var seed: UInt64?
  private var style: PlanetStyle?
  public private(set) var proceduralSamples = 0
  public private(set) var cacheHits = 0
  public var count: Int { blocks.count }

  public init(capacity: Int = 8_192) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  public mutating func clear() { self = .init(capacity: capacity) }

  /// Never substitutes a solid wall for an unrendered chunk. Edits are checked
  /// on every query, so cached procedural air cannot hide a newly placed wall,
  /// and cached stone cannot prevent moving through a newly excavated opening.
  public mutating func block(at p: BlockPosition, terrain: TerrainGenerator,
    chunk: ChunkData? = nil, edit: Block? = nil) -> Block {
    if seed != terrain.seed || style != terrain.style {
      clear(); seed = terrain.seed; style = terrain.style
    }
    if let edit { return terrain.waterSafeMaterial(edit, at: p) }
    // The voxel world's vertical bounds are known without generating a chunk.
    // Fly through clouds/sky immediately, even with zero meshes ready below.
    if p.y >= ChunkData.height { return .air }
    if p.y < ChunkData.minimumY { return .stone }
    if let chunk, chunk.coordinate == p.chunk {
      return chunk[p.x - p.chunk.x * 16, p.y, p.z - p.chunk.z * 16]
    }
    if let block = blocks[p] { cacheHits += 1; return block }
    let block = terrain.block(at: p)
    proceduralSamples += 1
    // Constant-time FIFO eviction avoids a large cache clear/sort during flight.
    if order.count == capacity {
      blocks.removeValue(forKey: order[oldest])
      order[oldest] = p
      oldest = (oldest + 1) % capacity
    } else { order.append(p) }
    blocks[p] = block
    return block
  }
}

/// Initial scene entry may wait for visible ground. Ordinary chunk streaming
/// after that must never hide the whole world or suspend the movement update.
/// Reset only when replacing the world, not when crossing a chunk boundary.
public struct TerrainEntryReadiness: Sendable {
  public private(set) var isWaiting = true
  public init() {}
  public mutating func observe(chunkReady: Bool) {
    if chunkReady { isWaiting = false }
  }
  public mutating func reset() { isWaiting = true }
}
