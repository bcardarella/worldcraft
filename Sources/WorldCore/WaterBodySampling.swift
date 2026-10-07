/// Worker-local memoization of a deterministic, world-space shoreline lookup.
/// A dry vertex uses the nearest possible wet quad origin, with z/x ties.
/// It never invents an ocean at a lake or river rim and never uses LOD stride.
struct WaterBodySampling {
  private struct Entry { let body: WaterBody? }
  private var cache: [SIMD2<Int>: Entry] = [:]

  // The largest current water quad is 32 blocks across. Its known wet NW
  // column is at a cardinal/diagonal offset of 1,2,4,8,16 or 32 blocks from
  // any of its vertices. NW-owned quads approach from north, west or northwest;
  // these 19 fixed probes include every possible known wet source column.
  // Keep this independent of the requesting tile so neighbouring LODs agree.
  static let radius = 32
  private static let offsets: [SIMD2<Int>] = {
    var points: [SIMD2<Int>] = []
    points.append([0,0])
    for radius in [1,2,4,8,16,32] {
      points += [[-radius,0],[0,-radius],[-radius,-radius]]
    }
    return points.sorted {
      ($0.x*$0.x+$0.y*$0.y,$0.y,$0.x) < ($1.x*$1.x+$1.y*$1.y,$1.y,$1.x)
    }
  }()

  /// WorldDrainage deliberately has no lakes/rivers on these styles. Once a
  /// wet quad is known, its dry corners need no more procedural body searches.
  static func uniformBody(style: PlanetStyle) -> WaterBody? {
    switch style {
    case .solar: .lava
    case .ember: .ocean
    default: nil
    }
  }

  mutating func body(atX x: Int, z: Int, lookup: (Int,Int) -> WaterBody?) -> WaterBody? {
    let key = SIMD2(x,z)
    if let known = cache[key] { return known.body }
    let value = lookup(x,z)
    cache[key] = Entry(body: value)
    return value
  }

  /// Nil is unresolved/cancelled, not a sea-level fallback. Callers invoke
  /// this only for vertices referenced by an emitted wet quad. This selects
  /// from the fixed probes, not an exhaustive closest point in the world.
  /// Unknown/dry
  /// points are memoized too; no process-global state or actor hop is involved.
  mutating func nearest(atX x: Int, z: Int, lookup: (Int,Int) -> WaterBody?) -> WaterBody? {
    if Task.isCancelled { return nil }
    guard x > Int.min+Self.radius, z > Int.min+Self.radius,
      x < Int.max-Self.radius, z < Int.max-Self.radius else { return nil }
    if let own = body(atX:x,z:z,lookup:lookup) { return own }
    for (i,offset) in Self.offsets.dropFirst().enumerated() {
      if i%32 == 0 && Task.isCancelled { return nil }
      if let value = body(atX:x+offset.x,z:z+offset.y,lookup:lookup) { return value }
    }
    return nil
  }
}
