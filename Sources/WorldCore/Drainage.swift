import Foundation
import simd

/// A directed drainage graph sampled from the same terrain as the voxel world.
/// Edges descend in elevation (with stable ordering across flats), so
/// tributaries merge without loops or uphill flow.
public struct RiverReach: Sendable {
  public let id: UInt64
  public let origin, destination: ChunkCoordinate
  public let points: [SIMD3<Float>]
  public let halfWidth: Float
  public let catchment: Int
  public let endsInLake: Bool
  public let endsInOcean: Bool
  public var minimum: SIMD2<Float> {
    points.reduce(SIMD2(repeating: .infinity)) { simd_min($0, [$1.x, $1.z]) }
  }
  public var maximum: SIMD2<Float> {
    points.reduce(SIMD2(repeating: -.infinity)) { simd_max($0, [$1.x, $1.z]) }
  }
}
public struct DrainagePatch: Sendable {
  public let rivers: [RiverReach]
  public let lakes: [InlandLake]
  private let bounds: [(SIMD2<Float>, SIMD2<Float>)]
  init(rivers: [RiverReach], lakes: [InlandLake]) {
    self.rivers = rivers
    self.lakes = lakes
    bounds = rivers.map {
      (
        $0.minimum - SIMD2(repeating: $0.halfWidth + 20),
        $0.maximum + SIMD2(repeating: $0.halfWidth + 20)
      )
    }
  }
  public func lake(atX x: Int, z: Int) -> InlandLake? {
    var best: InlandLake?
    var nearest: Float = 1.35
    for lake in lakes {
      // Avoid trigonometry for the overwhelmingly common dry column.
      guard abs(Float(x - lake.x)) < lake.radiusX * 1.5,
        abs(Float(z - lake.z)) < lake.radiusZ * 1.5
      else { continue }
      let distance = lake.distance(x: x, z: z)
      if distance < nearest {
        best = lake
        nearest = distance
      }
    }
    return best
  }
  public func river(atX x: Float, z: Float) -> RiverSample? {
    let point = SIMD2(x, z)
    var best: RiverSample?
    var bestDistance = Float.infinity
    for (index, river) in rivers.enumerated() {
      let (low, high) = bounds[index]
      guard x >= low.x && z >= low.y && x <= high.x && z <= high.y else { continue }
      for i in 0..<river.points.count - 1 {
        let a = river.points[i]
        let b = river.points[i + 1]
        let delta = SIMD2(b.x - a.x, b.z - a.z)
        let margin = river.halfWidth + 20
        guard x >= min(a.x, b.x) - margin && x <= max(a.x, b.x) + margin,
          z >= min(a.z, b.z) - margin && z <= max(a.z, b.z) + margin
        else { continue }
        let squared = simd_length_squared(delta)
        guard squared > 0.001 else { continue }
        let t = max(0, min(1, simd_dot(point - SIMD2(a.x, a.z), delta) / squared))
        let distance = simd_length(point - (SIMD2(a.x, a.z) + delta * t))
        let bank = max(0, distance - river.halfWidth)
        guard bank < 20 else { continue }
        // Prefer the broad shared trunk at confluences, then the nearest bed.
        let score = distance / river.halfWidth
        guard score < bestDistance else { continue }
        bestDistance = score
        let level = a.y + (b.y - a.y) * t
        let slope = max(0, (a.y - b.y) / sqrt(squared))
        let speed =
          (0.9 + min(1.8, sqrt(Float(river.catchment)) * 0.18) + min(1.2, slope * 18))
          * (0.5 + 0.5 * (1 - min(1, score)))
        let horizontal = simd_normalize(delta) * speed
        let current = SIMD3<Float>(horizontal.x, 0, horizontal.y)
        let depth = 2.5 + min(9, sqrt(Float(river.catchment)) * 0.55)
        let bed = Int(floor(level - max(1, depth * (1 - min(1, score) * 0.55))))
        best = .init(
          body: .init(id: river.id, kind: .river, level: level, current: current), bed: bed,
          bankBlend: smoothstep(river.halfWidth, river.halfWidth + 20, distance), current: current)
      }
    }
    return best
  }

  /// Reserve the channel and its banks before placing a graded building pad.
  /// Conservative bounds also protect meander bends between samples.
  func intersects(minimum: SIMD2<Float>, maximum: SIMD2<Float>) -> Bool {
    for lake in lakes {
      let radius = SIMD2(lake.radiusX, lake.radiusZ) * 1.5
      let center = SIMD2(Float(lake.x), Float(lake.z))
      if center.x + radius.x >= minimum.x && center.x - radius.x <= maximum.x
        && center.y + radius.y >= minimum.y && center.y - radius.y <= maximum.y
      {
        return true
      }
    }
    for (index, river) in rivers.enumerated() {
      let (low, high) = bounds[index]
      guard high.x >= minimum.x && low.x <= maximum.x && high.y >= minimum.y && low.y <= maximum.y
      else { continue }
      let margin = river.halfWidth + 20
      for pair in zip(river.points, river.points.dropFirst()) {
        if max(pair.0.x, pair.1.x) + margin >= minimum.x
          && min(pair.0.x, pair.1.x) - margin <= maximum.x
          && max(pair.0.z, pair.1.z) + margin >= minimum.y
          && min(pair.0.z, pair.1.z) - margin <= maximum.y
        {
          return true
        }
      }
    }
    return false
  }
}

public enum WorldDrainage {
  public static let spacing = 512
  private struct Key: Hashable, Sendable {
    let seed: UInt64
    let style: Int
    let x, z: Int
  }
  private static let cache = RegionalPlanCache<Key, DrainagePatch>(capacity: 256)
  static var cacheMetrics: RegionalCacheMetrics { cache.metrics }
  public static func patch(atX x: Int, z: Int, terrain: TerrainGenerator) -> DrainagePatch {
    guard terrain.style != .solar && terrain.style != .ember else {
      return .init(rivers: [], lakes: [])
    }
    let key = Key(seed: terrain.seed, style: terrain.style.rawValue,
      x: floorDivide(x, by: spacing), z: floorDivide(z, by: spacing))
    return cache.value(for: key) { Builder(terrain: terrain).build(around: .init(key.x, key.z)) }
  }
  public static func intersects(x: Int, z: Int, halfX: Int, halfZ: Int, terrain: TerrainGenerator)
    -> Bool
  {
    guard terrain.style != .solar && terrain.style != .ember else { return false }
    let minimum = SIMD2(Float(x - halfX), Float(z - halfZ))
    let maximum = SIMD2(Float(x + halfX), Float(z + halfZ))
    for cx in floorDivide(x - halfX, by: spacing)...floorDivide(x + halfX, by: spacing) {
      for cz in floorDivide(z - halfZ, by: spacing)...floorDivide(z + halfZ, by: spacing) {
        if patch(atX: cx * spacing, z: cz * spacing, terrain: terrain).intersects(
          minimum: minimum, maximum: maximum)
        {
          return true
        }
      }
    }
    return false
  }
  private final class Builder {
    struct Node {
      let key: ChunkCoordinate
      let point: SIMD2<Float>
      let height: Int
    }
    struct Basin {
      let area: Int
      let high: Int
    }
    let terrain: TerrainGenerator
    var nodes: [ChunkCoordinate: Node] = [:]
    var downstream: [ChunkCoordinate: ChunkCoordinate] = [:]
    var computed = Set<ChunkCoordinate>()
    var basins: [ChunkCoordinate: Basin] = [:]
    var lakeCache: [ChunkCoordinate: InlandLake] = [:]
    init(terrain: TerrainGenerator) { self.terrain = terrain }
    func neighbors(_ p: ChunkCoordinate) -> [ChunkCoordinate] {
      (-1...1).flatMap { x in
        (-1...1).compactMap { z in x == 0 && z == 0 ? nil : .init(p.x + x, p.z + z) }
      }
    }
    func node(_ p: ChunkCoordinate) -> Node {
      if let result = nodes[p] { return result }
      let h = terrain.hash(p.x, p.z, salt: 0x44_5241_494e)
      let x = p.x * spacing + spacing / 2 + Int(h % 81) - 40
      let z = p.z * spacing + spacing / 2 + Int((h >> 12) % 81) - 40
      let n = Node(key: p, point: [Float(x), Float(z)], height: terrain.rawHeight(atX: x, z: z))
      nodes[p] = n
      return n
    }
    func next(_ p: ChunkCoordinate) -> ChunkCoordinate? {
      if computed.contains(p) { return downstream[p] }
      let n = node(p)
      computed.insert(p)
      guard n.height > TerrainGenerator.seaLevel + 1 else { return nil }
      // Steepest descending neighbor, with stable ordering for equal gradients.
      let rank = terrain.hash(p.x, p.z, salt: 0x464c_4154)
      let target = neighbors(p).map(node).filter {
        $0.height < n.height
          || ($0.height == n.height && terrain.hash($0.key.x, $0.key.z, salt: 0x464c_4154) < rank)
      }.max { a, b in
        let sa = Float(n.height - a.height) / simd_distance(n.point, a.point)
        let sb = Float(n.height - b.height) / simd_distance(n.point, b.point)
        return sa == sb ? (a.key.x == b.key.x ? a.key.z > b.key.z : a.key.x > b.key.x) : sa < sb
      }
      downstream[p] = target?.key
      return target?.key
    }
    func basin(_ p: ChunkCoordinate) -> Basin {
      if let saved = basins[p] { return saved }
      var area = 1
      var high = node(p).height
      for parent in neighbors(p) where next(parent) == p {
        let upstream = basin(parent)
        area += upstream.area
        high = max(high, upstream.high)
      }
      let result = Basin(area: area, high: high)
      basins[p] = result
      return result
    }
    func terminal(_ p: ChunkCoordinate) -> ChunkCoordinate {
      var cursor = p
      while let next = next(cursor) { cursor = next }
      return cursor
    }
    func lake(_ p: ChunkCoordinate) -> InlandLake? {
      if let lake = lakeCache[p] { return lake }
      let n = node(p)
      guard n.height > TerrainGenerator.seaLevel + 1 else { return nil }
      let hash = terrain.hash(p.x, p.z, salt: 0x4c41_4b45_4241_5349)
      if next(p) != nil {
        // Some basins have an outlet, while true drainage sinks are terminal
        // lakes. Keep large basins apart so neighboring water levels never
        // create overlapping, stacked lakes.
        guard n.height > TerrainGenerator.seaLevel + 5, hash % 5 == 0 else { return nil }
        for neighbor in neighbors(p) where node(neighbor).height > TerrainGenerator.seaLevel + 1 {
          let other = terrain.hash(neighbor.x, neighbor.z, salt: 0x4c41_4b45_4241_5349)
          if next(neighbor) == nil
            || (node(neighbor).height > TerrainGenerator.seaLevel + 5 && other % 5 == 0
              && other < hash)
          {
            return nil
          }
        }
      }
      let lake = InlandLake(
        id: hash, x: Int(n.point.x), z: Int(n.point.y),
        radiusX: Float(170 + hash % 91), radiusZ: Float(160 + (hash >> 20) % 101),
        level: n.height - 2)
      lakeCache[p] = lake
      return lake
    }
    func tangent(_ p: ChunkCoordinate) -> SIMD2<Float> {
      guard let q = next(p) else { return .zero }
      let d = node(q).point - node(p).point
      let offset = Float(terrain.hash(p.x, p.z, salt: 171) % 100) / 100 - 0.5
      return simd_normalize(d + SIMD2(-d.y, d.x) * offset * 0.65)
    }
    func reach(_ p: ChunkCoordinate) -> RiverReach? {
      let source = node(p)
      guard source.height > TerrainGenerator.seaLevel + 1, let destination = next(p) else {
        return nil
      }
      let drainage = basin(p)
      guard drainage.high >= 54 else { return nil }
      let target = node(destination)
      let end = terminal(destination)
      let mouth = lake(destination)
      let endLake = lake(end)
      let id = endLake?.id ?? terrain.hash(end.x, end.z, salt: 0x5249_5645_524d_4f55)
      let a = source.point
      let b = target.point
      let length = simd_distance(a, b)
      let c1 = a + tangent(p) * length * 0.32
      let direction = tangent(destination)
      let c2 =
        b - (simd_length_squared(direction) > 0 ? direction : simd_normalize(b - a)) * length * 0.32
      var positions: [SIMD2<Float>] = []
      for i in 0...32 {
        let t = Float(i) / 32
        let u = 1 - t
        positions.append(a * u * u * u + c1 * 3 * u * u * t + c2 * 3 * u * t * t + b * t * t * t)
      }
      let start = Float(max(TerrainGenerator.seaLevel + 1, source.height - 1))
      let finish = mouth?.body.level ?? Float(max(TerrainGenerator.seaLevel + 1, target.height - 1))
      var inlet = 0
      var outlet = 32
      if let sourceLake = lake(p) {
        inlet = positions.firstIndex { sourceLake.distance(x: Int($0.x), z: Int($0.y)) > 1.1 } ?? 0
      }
      if let mouth {
        outlet = positions.firstIndex { mouth.distance(x: Int($0.x), z: Int($0.y)) < 1.1 } ?? 32
      } else if target.height <= TerrainGenerator.seaLevel + 1 {
        outlet =
          positions.firstIndex {
            terrain.rawHeight(atX: Int($0.x), z: Int($0.y)) <= TerrainGenerator.seaLevel
          } ?? 32
      }
      let points = positions.enumerated().map { i, p in
        let progress = max(0, min(1, Float(i - inlet) / Float(max(1, outlet - inlet))))
        return SIMD3<Float>(p.x, start + (min(start, finish) - start) * progress, p.y)
      }
      return .init(
        id: id, origin: p, destination: destination, points: points,
        halfWidth: min(18, 3.5 + sqrt(Float(drainage.area)) * 1.3), catchment: drainage.area,
        endsInLake: mouth != nil, endsInOcean: target.height <= TerrainGenerator.seaLevel + 1)
    }
    func build(around key: ChunkCoordinate) -> DrainagePatch {
      var rivers: [RiverReach] = []
      var lakes: [InlandLake] = []
      // Curve controls and lake shoulders stay inside this shared neighborhood.
      // Adjacent patches compute identical reaches, avoiding chunk-edge seams.
      for x in key.x - 1...key.x + 1 {
        for z in key.z - 1...key.z + 1 {
          let p = ChunkCoordinate(x, z)
          if let river = reach(p) { rivers.append(river) }
          if let water = lake(p) { lakes.append(water) }
        }
      }
      return .init(rivers: rivers, lakes: lakes)
    }
  }
}
