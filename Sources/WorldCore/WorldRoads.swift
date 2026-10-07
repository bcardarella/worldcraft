import Foundation

public enum RoadKind: Int, Sendable {
  case path, road, highway
  public var halfWidth: Float { self == .path ? 2 : self == .road ? 5 : 9 }
}
public struct RoadSegment: Sendable, Hashable {
  public let a, b: SIMD3<Float>
  public let kind: RoadKind
  public func sample(x: Int, z: Int) -> RoadSample? {
    let d = SIMD2(b.x - a.x, b.z - a.z)
    let p = SIMD2(Float(x) + 0.5 - a.x, Float(z) + 0.5 - a.z)
    let length = d.x * d.x + d.y * d.y
    let t = max(0, min(1, (p.x * d.x + p.y * d.y) / max(0.001, length)))
    let q = p - d * t
    let distance = sqrt(q.x * q.x + q.y * q.y)
    guard distance <= kind.halfWidth + 1 else { return nil }
    return .init(
      floor: Int((a.y + (b.y - a.y) * t).rounded()), kind: kind, distance: distance,
      dashed: (abs(x) + abs(z)) % 12 < 6)
  }
  public func overlaps(x: Int, z: Int, width: Int) -> Bool {
    let r = kind.halfWidth + 2
    return max(a.x, b.x) + r >= Float(x) && min(a.x, b.x) - r <= Float(x + width)
      && max(a.z, b.z) + r >= Float(z) && min(a.z, b.z) - r <= Float(z + width)
  }
}
public struct RoadSample: Sendable {
  public let floor: Int
  public let kind: RoadKind
  public let distance: Float
  public let dashed: Bool
  public var surface: Block {
    if kind == .path { return .dirt }
    if distance > kind.halfWidth - 0.6 || (distance < 0.7 && dashed) { return .limestone }
    if kind == .highway && abs(distance - 4.5) < 0.65 && dashed { return .limestone }
    return .basalt
  }
  public func block(at p: BlockPosition, natural: TerrainColumn) -> Block? {
    if p.y >= floor { return .air }
    if p.y == floor - 1 { return surface }
    if natural.water != nil {
      // Raised bridge deck with spaced piers; water flows underneath.
      return p.y == floor - 2 || ((p.x % 24 == 0 || p.z % 24 == 0) && distance > kind.halfWidth - 1)
        ? .stone : nil
    }
    return p.y >= min(floor - 4, natural.height + 1) ? .stone : nil
  }
}

/// Sparse inter-settlement links. Plans are immutable, bounded and prepared by
/// terrain workers; no per-frame path search or extra road scene entities.
public enum WorldRoads {
  private struct Key: Hashable, Sendable {
    let seed: UInt64
    let style: Int
    let region: ChunkCoordinate
  }
  private static let cache = RegionalPlanCache<Key, [RoadSegment]>(capacity: 64)
  static var cacheMetrics: RegionalCacheMetrics { cache.metrics }
  private static func plan(_ region: ChunkCoordinate, _ terrain: TerrainGenerator) -> [RoadSegment] {
    let key = Key(seed: terrain.seed, style: terrain.style.rawValue, region: region)
    return cache.value(for: key) { make(region: region, terrain: terrain) }
  }
  public static func segments(x: Int, z: Int, width: Int, terrain: TerrainGenerator)
    -> [RoadSegment]
  {
    let size = SettlementGenerator.regionSize
    var result: [RoadSegment] = []
    var seen = Set<RoadSegment>()
    for rz in floorDivide(z, by: size)...floorDivide(z + width, by: size) {
      for rx in floorDivide(x, by: size)...floorDivide(x + width, by: size) {
        for segment in plan(.init(rx, rz), terrain.marinaSurveyTerrain)
        where segment.overlaps(x: x, z: z, width: width) && seen.insert(segment).inserted {
          result.append(segment)
        }
      }
    }
    return result
  }
  public static func sample(x: Int, z: Int, segments: [RoadSegment]) -> RoadSample? {
    var result: RoadSample?
    for segment in segments {
      if let sample = segment.sample(x: x, z: z), sample.distance < (result?.distance ?? .infinity)
      {
        result = sample
      }
    }
    return result
  }
  private static func make(region: ChunkCoordinate, terrain: TerrainGenerator) -> [RoadSegment] {
    let size = SettlementGenerator.regionSize
    let ox = region.x * size
    let oz = region.z * size
    var sites: [ChunkCoordinate: Settlement] = [:]
    var checked = Set<ChunkCoordinate>()
    func site(_ x: Int, _ z: Int) -> Settlement? {
      let key = ChunkCoordinate(x, z)
      if checked.insert(key).inserted {
        sites[key] = SettlementGenerator.site(in: key, terrain: terrain)
      }
      guard let site = sites[key], site.habitat != .aquatic else { return nil }
      return site
    }
    var result: [RoadSegment] = []
    for z in region.z - 2...region.z + 2 {
      for x in region.x - 2...region.x + 2 {
        guard let a = site(x, z) else { continue }
        for axis in 0...1 {
          var destination: Settlement?
          for step in 1...2 {
            if let b = site(x + (axis == 0 ? step : 0), z + (axis == 1 ? step : 0)) {
              destination = b
              break
            }
          }
          guard let b = destination else { continue }
          let kind: RoadKind =
            a.kind == .village && b.kind == .village
            ? .path
            : a.kind == .city || b.kind == .city ? .highway : .road
          let bend: Float = axis == 0 ? Float(a.x + b.x) / 2 : Float(a.z + b.z) / 2
          let points: [SIMD3<Float>] =
            axis == 0
            ? [a.center, [bend, 0, Float(a.z)], [bend, 0, Float(b.z)], b.center]
            : [a.center, [Float(a.x), 0, bend], [Float(b.x), 0, bend], b.center]
          guard points.map(\.x).max()! + 64 >= Float(ox),
            points.map(\.x).min()! - 64 <= Float(ox + size),
            points.map(\.z).max()! + 64 >= Float(oz),
            points.map(\.z).min()! - 64 <= Float(oz + size)
          else { continue }
          var samples: [SIMD3<Float>] = []
          var bridgeMinimums: [Float?] = []
          for i in 0..<points.count - 1 {
            let d = points[i + 1] - points[i]
            let length = sqrt(d.x * d.x + d.z * d.z)
            let steps = max(1, Int(ceil(length / 16)))
            for j in 0..<steps {
              var p = points[i] + d * Float(j) / Float(steps)
              let awayA = max(abs(p.x - Float(a.x)), abs(p.z - Float(a.z))) - Float(a.radius + 32)
              let awayB = max(abs(p.x - Float(b.x)), abs(p.z - Float(b.z))) - Float(b.radius + 32)
              let bend =
                min(1, max(0, min(awayA, awayB) / 96)) * sin(Float(j) / Float(steps) * Float.pi)
                * sin((p.x + p.z) * 0.004 + Float(a.id % 100)) * 18
              if length > 0.01 { p += SIMD3(-d.z, 0, d.x) / length * bend }
              let natural = terrain.column(atX: Int(p.x), z: Int(p.z))
              p.y = Float(natural.height + 1)
              if let water = natural.water { p.y = max(p.y, water.level + 5) }
              if a.contains(.init(p)) { p.y = Float(a.floor) }
              if b.contains(.init(p)) { p.y = Float(b.floor) }
              samples.append(p)
              bridgeMinimums.append(
                a.contains(.init(p)) || b.contains(.init(p))
                  ? nil : natural.water.map { $0.level + 3 })
            }
          }
          samples.append(b.center)
          bridgeMinimums.append(nil)
          // Narrow rivers can fall between the 16-block road samples. Survey
          // the intervening spans before smoothing, so a bridge cannot sag
          // below its water clearance while both land endpoints look valid.
          for i in 1..<samples.count {
            let aPoint=samples[i-1],bPoint=samples[i]
            let distance=hypot(bPoint.x-aPoint.x,bPoint.z-aPoint.z)
            let steps=max(2,Int(ceil(distance/4)))
            for step in 1..<steps {
              let p=aPoint+(bPoint-aPoint)*Float(step)/Float(steps)
              guard !a.contains(.init(p)),!b.contains(.init(p)),
                let water=terrain.column(atX:Int(floor(p.x)),z:Int(floor(p.z))).water else {continue}
              for j in [i-1,i] {
                let minimum=water.level+3
                samples[j].y=max(samples[j].y,minimum)
                bridgeMinimums[j]=max(bridgeMinimums[j] ?? minimum,minimum)
              }
            }
          }
          // Pin the approaches to the actual town street elevation. Raising
          // the whole profile alone used to leave cliffs at settlement edges.
          // Cut hills near an entrance before smoothing the remaining grade.
          for i in samples.indices {
            let p = samples[i]
            func approach(_ site: Settlement) -> (Float,Float) {
              let distance = max(
                0, max(abs(p.x - Float(site.x)), abs(p.z - Float(site.z))) - Float(site.radius + 24))
              return (Float(site.floor)-distance*0.20, Float(site.floor)+distance*0.20)
            }
            let aa=approach(a),bb=approach(b)
            samples[i].y = max(aa.0,bb.0,min(p.y,aa.1,bb.1))
          }
          // Limit grade to roughly one block in four. The entrance ceilings
          // are gentler than this limit, so smoothing preserves the anchors.
          for i in 1..<samples.count {
            let d = samples[i] - samples[i - 1]
            samples[i].y = max(samples[i].y, samples[i - 1].y - sqrt(d.x * d.x + d.z * d.z) * 0.24)
          }
          for i in (0..<samples.count - 1).reversed() {
            let d = samples[i + 1] - samples[i]
            samples[i].y = max(samples[i].y, samples[i + 1].y - sqrt(d.x * d.x + d.z * d.z) * 0.24)
          }
          // A very short link between incompatible elevations or a high lake
          // immediately outside town needs a different route. Omit that link
          // rather than publishing a submerged deck or a sheer entrance.
          guard
            samples.indices.allSatisfy({ i in
              let p = samples[i]
              if let minimum = bridgeMinimums[i], p.y.rounded() < minimum { return false }
              if a.contains(.init(p)), abs(p.y - Float(a.floor)) > 0.5 { return false }
              if b.contains(.init(p)), abs(p.y - Float(b.floor)) > 0.5 { return false }
              return true
            })
          else { continue }
          for i in 0..<samples.count - 1 {
            let road = RoadSegment(a: samples[i], b: samples[i + 1], kind: kind)
            if road.overlaps(x: ox, z: oz, width: size) { result.append(road) }
          }
        }
      }
    }
    return result
  }
}
