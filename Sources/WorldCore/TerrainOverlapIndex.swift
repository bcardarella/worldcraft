/// Aligned power-of-two tiles overlap only when one contains the other. Index
/// each tile under its (at most six) ancestors instead of scanning the horizon.
/// The full/surface pair at size one deliberately shares a spatial key.
struct TerrainOverlapIndex: Sendable {
  private let tiles: Set<TerrainTile>
  private var descendants: [TerrainTile: [TerrainTile]] = [:]
  init(_ tiles: Set<TerrainTile>) {
    self.tiles = tiles
    for tile in tiles {
      var size = tile.size
      while size <= 32 {
        let key = Self.key(tile, size: size)
        descendants[key, default: []].append(tile)
        size *= 2
      }
    }
  }
  func containsOverlap(with tile: TerrainTile) -> Bool {
    if descendants[Self.key(tile, size: tile.size)] != nil { return true }
    var size = tile.size * 2
    while size <= 32 {
      if tiles.contains(Self.key(tile, size: size)) { return true }
      size *= 2
    }
    return false
  }
  func overlapping(_ tile: TerrainTile) -> [TerrainTile] {
    var result = descendants[Self.key(tile, size: tile.size)] ?? []
    var size = tile.size * 2
    while size <= 32 {
      let key = Self.key(tile, size: size)
      if tiles.contains(key) { result.append(key) }
      size *= 2
    }
    return result
  }
  private static func key(_ tile: TerrainTile, size: Int) -> TerrainTile {
    .init(x: floorDivide(tile.x, by: size) * size, z: floorDivide(tile.z, by: size) * size, size: size)
  }
}
