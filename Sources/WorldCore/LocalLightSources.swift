import simd

/// Streamed fixture locations, with a refresh rate independent of tile uploads.
/// Installing dry/distant terrain must not turn a periodic lighting pass into a
/// per-frame scan and component rewrite. Overlapping LODs share one fixture.
public struct LocalLightSources: Sendable {
  private var tiles: [TerrainTile: [SIMD3<Float>]] = [:]
  private var lastSample = -Double.infinity
  public private(set) var count = 0

  public init() {}

  public mutating func install(_ tile: TerrainTile, positions: [SIMD3<Float>]) {
    count -= tiles[tile]?.count ?? 0
    tiles[tile] = positions.isEmpty ? nil : positions.map { tile.origin + $0 }
    count += positions.count
  }

  public mutating func remove(_ tile: TerrainTile) {
    count -= tiles.removeValue(forKey: tile)?.count ?? 0
  }

  public mutating func clear() { self = .init() }

  /// nil means retain the last selection. An empty array means remove all lights.
  public mutating func sample(time: Double, interval: Double, eye: SIMD3<Float>,
    radius: Float, limit: Int, isValid: (BlockPosition) -> Bool) -> [SIMD3<Float>]? {
    guard time < lastSample || time - lastSample >= interval else { return nil }
    lastSample = time
    var seen = Set<BlockPosition>()
    let candidates = tiles.values.flatMap { $0 }.filter {
      simd_distance_squared($0, eye) < radius * radius && seen.insert(BlockPosition($0)).inserted
    }.sorted {
      let a = simd_distance_squared($0, eye), b = simd_distance_squared($1, eye)
      if a != b { return a < b }
      if $0.x != $1.x { return $0.x < $1.x }
      if $0.z != $1.z { return $0.z < $1.z }
      return $0.y < $1.y
    }
    var result: [SIMD3<Float>] = []
    for point in candidates {
      guard result.count < max(0, limit) else { break }
      if isValid(BlockPosition(point)) { result.append(point) }
    }
    return result
  }
}
