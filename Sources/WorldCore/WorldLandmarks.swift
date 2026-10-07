import Foundation

/// A small, immutable plan built once per planet and shared by terrain workers.
/// Landmarks reserve open land outside settlement footprints.
public struct WorldLandmark: Sendable {
  public enum Kind: Sendable { case circuit, castle }
  public let id: UInt64
  public let kind: Kind
  public let x, z, floor: Int
  public let variant: Int
  public var name: String { kind == .castle ? "Hay Hay's Castle" : circuit.layout.name }
  public var center: SIMD3<Float> { [Float(x), Float(floor), Float(z)] }
  public var halfX: Int { kind == .circuit ? 304 : 44 }
  public var halfZ: Int { kind == .circuit ? 208 : 44 }
  public func contains(x px: Int, z pz: Int) -> Bool { abs(px-x) <= halfX && abs(pz-z) <= halfZ }
  public var petHome: SIMD3<Float> { center + [-18.5, 9, -18.5] }
  public var entrance: SIMD3<Float> { kind == .castle ? center + [-18, 0, 36] : center + [0, 0, circuit.pitZ+15] }
  public var circuit: RaceCircuit { .init(id:id,center:center,layout:CircuitLayout(rawValue:variant % CircuitLayout.allCases.count) ?? .speedway) }

  public func surface(x px: Int, z pz: Int, natural: Int) -> Int {
    let edge = min(halfX-abs(px-x), halfZ-abs(pz-z))
    // Eight-block graded shoulders join each pad to the original landscape.
    let blend = Float(min(8, max(0, edge))) / 8
    return Int((Float(natural + 1)*(1-blend) + Float(floor)*blend).rounded())
  }
  public func ground(x px: Int, z pz: Int) -> Block {
    let rx = px-x, rz = pz-z
    if kind == .castle {
      return abs(rx+18) <= 2 || (abs(rx) < 27 && abs(rz) < 27) ? .limestone : .grass
    }
    let distance = circuit.laneDistance(x: Float(px)+0.5, z: Float(pz)+0.5)
    if abs(distance) <= RaceCircuit.roadHalfWidth {
      if abs(rx) <= 1 && rz > 0 { return (abs(rx+rz) % 2 == 0) ? .limestone : .basalt }
      if abs(distance) > RaceCircuit.roadHalfWidth-1.2 { return (abs(rx+rz) / 3) % 2 == 0 ? .brick : .limestone }
      return .basalt
    }
    // Pit apron joins the near straight without a barrier or raised kerb.
    if abs(rx) <= 38 && Float(rz) >= circuit.startZ-5 && Float(rz) <= circuit.pitZ+7 { return .stone }
    return .grass
  }
  public func block(at p: BlockPosition, surface: Int, natural: Int) -> Block? {
    guard contains(x: p.x, z: p.z) else { return nil }
    if p.y < surface - 4 { return p.y > natural ? .stone : nil }
    if p.y < surface - 1 { return .stone }
    if p.y == surface - 1 { return ground(x: p.x, z: p.z) }
    let rx = p.x-x, rz = p.z-z, y = p.y-floor
    if kind == .circuit {
      guard y >= 0 && y <= 7 else { return .air }
      if (0...1).contains(y), !(abs(rx) <= 40 && rz > 0) {
        let distance=circuit.laneDistance(x:Float(p.x)+0.5,z:Float(p.z)+0.5)
        if distance>=12 && distance<13 { return .limestone }
      }
      // Pit garages, open toward the track, plus trackside lighting.
      if (-38...38).contains(rx), (Int(circuit.pitZ)-5...Int(circuit.pitZ)+6).contains(rz) {
        if y == 5 { return .brick }
        if y >= 0 && y < 5 && (rz == Int(circuit.pitZ)+6 || abs(rx) == 38) { return .stone }
      }
      if abs(rx) == 42 && rz == Int(circuit.pitZ)+4 && (0...7).contains(y) { return y == 7 ? .torch : .stone }
      return .air
    }
    return castleBlock(x: rx, y: y, z: rz)
  }

  private func castleBlock(x: Int, y: Int, z: Int) -> Block {
    guard y >= 0 && y <= 26 else { return .air }
    // Hollow corner towers with crenellations and tiered turquoise roofs.
    for tx in [-29,29] { for tz in [-29,29] {
      let dx = abs(x-tx), dz = abs(z-tz)
      if max(dx,dz) <= 5 {
        if y < 22 {
          if max(dx,dz) == 5 {
            if (4...6).contains(y) && (dx == 0 || dz == 0) { return .glass }
            return .limestone
          }
          return y == 10 || y == 20 ? .wood : .air
        }
        if y < 27 && max(dx,dz) <= 5-(y-22) { return variant % 2 == 0 ? .coral : .brick }
      }
    } }
    // Curtain wall and walkable outer courtyard. The south gate is always open.
    if max(abs(x),abs(z)) == 32 {
      if z == 32 && abs(x+18) <= 3 && y < 6 { return .air }
      if y < 10 || (y < 12 && (abs(x+z) % 4 < 2)) { return .stone }
    }
    if abs(x) > 26 || abs(z) > 26 {
      if abs(x) == 23 && abs(z) == 30 && y == 0 { return .lamp }
      return .air
    }
    let outer = abs(x) == 26 || abs(z) == 26
    let stair = (15...20).contains(x) && (-24 ... -12).contains(z)
    if y == 8 && !stair { return .wood }
    // One-block stairs lead from the last ground-floor room to the upper gallery.
    if (15...20).contains(x) && (-22 ... -14).contains(z) {
      let step = -z-14
      if y == step { return .stoneStairsNorth }
      if y < step { return .limestone }
    }
    if outer && y < 18 {
      if z == 26 && abs(x+18) <= 2 && y < 6 { return .air }
      if (3...5).contains(y % 9) && (abs(x) % 9 <= 1 || abs(z) % 9 <= 1) { return .glass }
      return .limestone
    }
    if y < 8 {
      // Three linked rows form a guaranteed winding route, with furnished side
      // alcoves. Doors are five blocks wide and six high for players and pets.
      if abs(x) == 9 && !(abs(abs(z)-18) <= 2 || abs(z) <= 2) { return .stone }
      if z == 9 && abs(x-18) > 2 { return .stone }
      if z == -9 && abs(x+18) > 2 { return .stone }
      if y == 0 && abs(x) % 18 == 5 && abs(z) % 18 == 5 { return .wood }
      if y == 1 && abs(x) % 18 == 5 && abs(z) % 18 == 5 { return .torch }
    } else if y < 18 {
      if x == 9 && abs(z-18) > 2 { return .brick }
      if x == -9 && abs(z+18) > 2 { return .brick }
      if y == 9 && abs(x+18) <= 4 && abs(z+18) <= 4 { return .air }
      if y == 10 && abs(x) == 23 && abs(z) == 23 { return .lamp }
    }
    // Roof over the keep; a high sanctuary and battlements remain conspicuous
    // in the distant silhouette without an independent scene hierarchy.
    if y == 18 { return .wood }
    if (19...21).contains(y) && outer && abs(x+z) % 4 < 2 { return .limestone }
    return .air
  }
}

public enum WorldLandmarks {
  private struct Key: Hashable, Sendable { let seed: UInt64; let style: Int }
  private static let cache = RegionalPlanCache<Key, [WorldLandmark]>(capacity: 32)
  static var cacheMetrics: RegionalCacheMetrics { cache.metrics }
  public static func cached(terrain: TerrainGenerator) -> [WorldLandmark] {
    let key = Key(seed: terrain.seed, style: terrain.style.rawValue)
    return cache.value(for: key) { make(terrain: terrain) }
  }
  public static func make(terrain: TerrainGenerator) -> [WorldLandmark] {
    let home = SettlementGenerator.site(in: .init(0,0), terrain: terrain)?.center ?? [128,32,128]
    var candidates: [(Int,Int,Float)] = []
    var settlements: [ChunkCoordinate: Settlement] = [:]
    var checked = Set<ChunkCoordinate>()
    for z in -4...4 { for x in -4...4 where x != 0 || z != 0 {
      let px=x*640+320, pz=z*640+320
      var overlaps=false
      for rz in floorDivide(pz-220,by:SettlementGenerator.regionSize)...floorDivide(pz+220,by:SettlementGenerator.regionSize) {
        for rx in floorDivide(px-316,by:SettlementGenerator.regionSize)...floorDivide(px+316,by:SettlementGenerator.regionSize) {
          let region=ChunkCoordinate(rx,rz)
          if checked.insert(region).inserted { settlements[region]=SettlementGenerator.site(in:region,terrain:terrain) }
          if let site=settlements[region], abs(px-site.x)<site.radius+316,abs(pz-site.z)<site.radius+220 { overlaps=true }
        }
      }
      // Keep flat race/castle pads off drainage corridors and lake basins.
      // Otherwise an otherwise valid mountain river ends at an artificial dam.
      if overlaps || WorldDrainage.intersects(x:px,z:pz,halfX:316,halfZ:220,terrain:terrain) { continue }
      let dx=Float(px)-home.x,dz=Float(pz)-home.z
      candidates.append((x,z,dx*dx+dz*dz))
    } }
    candidates.sort { $0.2 == $1.2 ? ($0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0) : $0.2 < $1.2 }
    return candidates.prefix(2).enumerated().map { index, region in
      let x = region.0*640+320, z = region.1*640+320
      let hash = terrain.hash(region.0,region.1,salt:0x48415952414345)
      return .init(id: hash &+ UInt64(index+1) &* 0x9E37_79B9_7F4A_7C15, kind: index == 1 ? .castle : .circuit, x: x, z: z,
        floor: min(ChunkData.height-40, max(TerrainGenerator.seaLevel+6,terrain.height(atX:x,z:z)+1)),
        // One destination circuit per planet; the seed selects among all six layouts.
        variant: index == 1 ? Int(hash % 3) : Int(hash % UInt64(CircuitLayout.allCases.count)))
    }
  }
}

/// Ordered progress gates reject shortcuts, reversing across the finish line
/// and teleports. Going off circuit cancels the current lap, preserving best.
public struct RaceProgress: Sendable {
  public private(set) var laps = 0
  public private(set) var elapsed: Float = 0
  public private(set) var best: Float?
  public private(set) var last: Float?
  public private(set) var active = false
  private var previous: Float?
  private var travelled: Float = 0
  public init() {}
  public mutating func update(position: SIMD3<Float>, seconds: Float, circuit: RaceCircuit) {
    let progress = circuit.progress(at:position)
    guard abs(position.y-circuit.center.y) < 3,
      abs(circuit.laneDistance(x:position.x,z:position.z)) <= RaceCircuit.roadHalfWidth+0.5 else {
      active = false; elapsed = 0; travelled = 0; previous = nil; return
    }
    defer { previous = progress }
    guard let previous else { return }
    var delta = progress-previous
    if delta < -circuit.length/2 { delta += circuit.length }
    if delta > circuit.length/2 { delta -= circuit.length }
    guard abs(delta) < 8 else { active = false; elapsed = 0; travelled = 0; return }
    let crossed = previous > circuit.length-8 && progress < 8 && delta > 0
    if active { elapsed += max(0,seconds); travelled = max(0,travelled+delta) }
    if crossed {
      if active && travelled >= circuit.length-8 {
        laps += 1; last = elapsed; best = min(best ?? elapsed,elapsed)
      }
      active = true; travelled = 0; elapsed = 0
    }
  }
}
