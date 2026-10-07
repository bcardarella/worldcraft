/// Complete a nearby parent's replacement set together. Otherwise a finished
/// voxel tile can remain hidden behind a coarse parent while far siblings wait.
public enum TerrainWorkPriority {
  public static func services(desired: Set<TerrainTile>, available: Set<TerrainTile>,
    ranks: [TerrainTile: Int]) -> [TerrainTile: TerrainWorkClass] {
    let index = TerrainOverlapIndex(available)
    return Dictionary(uniqueKeysWithValues: desired.map { tile in
      let service: TerrainWorkClass
      if (ranks[tile] ?? Int.max) < 1_000 { service = .collision }
      else if tile.fullDetail { service = .detail }
      else if !index.containsOverlap(with: tile) { service = .coverage }
      else { service = .refinement }
      return (tile, service)
    })
  }

  public static func streaming(desired: Set<TerrainTile>, available: Set<TerrainTile>,
    center: ChunkCoordinate, lookAhead: ChunkCoordinate, speculative: Set<TerrainTile> = []
  ) -> (ranks: [TerrainTile: Int], services: [TerrainTile: TerrainWorkClass]) {
    var ranks = ranks(desired: desired, available: available, center: center, lookAhead: lookAhead)
    var services = services(desired: desired, available: available, ranks: ranks)
    for tile in desired where services[tile] == .coverage {
      // A distant regional tile fills substantially more missing skyward area
      // than a single close cell. Distance per covered chunk prioritizes broad
      // coverage, while reserved collision/detail turns keep local work moving.
      let distance = min(tile.distanceSquared(to: center), tile.distanceSquared(to: lookAhead) + 4)
      ranks[tile] = distance * 16 / (tile.size * tile.size)
    }
    var optional = desired.intersection(speculative)
    if !optional.isEmpty {
      let index = TerrainOverlapIndex(desired)
      for parent in available.subtracting(desired) {
        let siblings = index.overlapping(parent)
        if siblings.contains(where: { !optional.contains($0) }) { optional.subtract(siblings) }
      }
    }
    for tile in optional where services[tile] != .collision {
      // Additional travel detail must not delay the guaranteed nearby region.
      // It shares the existing refinement opportunity with distant work and
      // retains worker/ready aging; no extra worker or publication budget.
      services[tile] = .refinement
      ranks[tile] = 100_000 + tile.distanceSquared(to: lookAhead)
    }
    return (ranks, services)
  }

  public static func ranks(
    desired: Set<TerrainTile>, available: Set<TerrainTile>,
    center: ChunkCoordinate, lookAhead: ChunkCoordinate
  ) -> [TerrainTile: Int] {
    func priority(_ tile: TerrainTile) -> Int {
      let distance = tile.distanceSquared(to: center)
      let ahead = tile.distanceSquared(to: lookAhead) + 4
      if tile.fullDetail && distance <= 4 { return distance }
      return (tile.fullDetail ? 1_000 : 10_000) + min(distance, ahead)
    }
    var result = Dictionary(uniqueKeysWithValues: desired.map { ($0, priority($0)) })
    let outgoing = available.subtracting(desired)
    guard !outgoing.isEmpty else { return result }
    let index = TerrainOverlapIndex(desired)
    for parent in outgoing {
      let children = index.overlapping(parent)
      guard let rank = children.compactMap({ result[$0] }).min() else { continue }
      for child in children { result[child] = min(result[child] ?? rank, rank) }
    }
    return result
  }

  public static func precedes(
    _ a: TerrainTile, _ b: TerrainTile, ranks: [TerrainTile: Int], center: ChunkCoordinate
  ) -> Bool {
    let first = ranks[a] ?? Int.max, second = ranks[b] ?? Int.max
    if first != second { return first < second }
    let da = a.distanceSquared(to: center), db = b.distanceSquared(to: center)
    return da == db ? (a.z, a.x, a.size) < (b.z, b.x, b.size) : da < db
  }
}

public enum VegetationDetail {
  public static func isLush(
    _ coordinate: ChunkCoordinate, center: ChunkCoordinate, previouslyLush: Bool = false
  ) -> Bool {
    let radius = previouslyLush ? 5 : 4
    return coordinate.distanceSquared(to: center) <= radius * radius
  }
}
