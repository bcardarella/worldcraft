import Foundation

public struct ColossalGround: Sendable {
  public let height: Float
  public let waterDepth: Float
  public let blocked: Bool
  public init(height: Float, waterDepth: Float = 0, blocked: Bool = false) {
    self.height = height; self.waterDepth = waterDepth; self.blocked = blocked
  }
  public var walkable: Bool { height.isFinite && !blocked && waterDepth <= 8 }
}

public struct ColossalRexSite: Sendable {
  public static let regionSize = 512
  public let id: UInt64
  public let region: ChunkCoordinate
  public let position: SIMD3<Float>
  public let heightMetres: Float
  public let color: RexColor
  /// One eligible site in seven regions. Seeded sites never reroll every frame
  /// or on reload, and the renderer permits only one active colossal animal.
  public static func candidate(in region: ChunkCoordinate, terrain: TerrainGenerator) -> Self? {
    guard terrain.style != .solar && terrain.style != .ember else { return nil }
    let h = terrain.hash(region.x, region.z, salt: 0x434F_4C4F_5353)
    guard h % 7 == 0 else { return nil }
    let height: Float = 110 + Float((h >> 40) % 31)
    for attempt in 0..<3 {
      let x = region.x * regionSize + 128 + Int((h >> (8 + attempt * 7)) % 256)
      let z = region.z * regionSize + 128 + Int((h >> (16 + attempt * 7)) % 256)
      let center = terrain.column(atX: x, z: z)
      guard center.water == nil, terrain.biome(atX: x, z: z) != .alpine else { continue }
      var heights: [Float] = [], suitable = true
      for d: SIMD2<Int> in [[0,0],[-32,-32],[32,-32],[-32,32],[32,32]] {
        let column = terrain.column(atX: x + d.x, z: z + d.y)
        if column.water != nil || terrain.landmarks.contains(where: { $0.contains(x:x+d.x,z:z+d.y) }) || SettlementGenerator.site(at: .init(x + d.x, column.height + 1, z + d.y), terrain: terrain) != nil { suitable = false; break }
        heights.append(Float(column.height + 1))
      }
      guard suitable, let floor = heights.max(), floor - (heights.min() ?? floor) <= 8 else { continue }
      return .init(id: h, region: region, position: [Float(x), floor, Float(z)], heightMetres: height,
        color: RexColor.allCases[Int((h >> 48) % UInt64(RexColor.allCases.count))])
    }
    return nil
  }
}

public struct ColossalRexState: Sendable {
  public let site: ColossalRexSite
  public var position: SIMD3<Float>
  public private(set) var heading: Float
  public private(set) var gait: Float = 0
  public private(set) var display: Float = 0
  public private(set) var moving = false
  public private(set) var resting = false
  private var accumulator: Float = 0
  public var footprint: Float { site.heightMetres * 0.27 }
  public init(site: ColossalRexSite) {
    self.site = site; position = site.position; heading = Float(site.id % 628) / 100
  }
  public mutating func applyRider(_ ride:MountedRide,seconds:Float) {
    guard ride.id == site.id else { return }
    position=ride.position; heading=ride.heading; resting=false; display=0
    let speed=sqrt(ride.velocity.x*ride.velocity.x+ride.velocity.z*ride.velocity.z)
    moving=speed>0.15
    gait += min(0.1,max(0,seconds))*speed * .pi*2/max(8,footprint*1.3)
    accumulator=0
  }
  /// A few terrain columns, never a volume proportional to the monster's size.
  /// At most five probes per quarter second, irrespective of headset frame rate.
  public mutating func update(deltaTime: Float, time: Double, player: SIMD3<Float>,
    directive: AnimalDecisionOption?, ground: (Float, Float) -> ColossalGround) {
    let dt = min(0.1, max(0, deltaTime))
    guard dt > 0 else { return }
    let toPlayer = player - position
    let near = toPlayer.x * toPlayer.x + toPlayer.z * toPlayer.z < 110 * 110
      && abs(toPlayer.y) < WorldScale.blocks(site.heightMetres)
    display += ((near ? 1 : 0) - display) * min(1, dt * 1.3)
    accumulator += dt
    guard accumulator >= 0.25 else { return }
    let step = min(0.4, accumulator); accumulator = 0
    moving = false
    let phase = Float(time.truncatingRemainder(dividingBy: 10_000)) + Float(site.id % 100)
    let target = directive?.point.center ?? site.position + [sin(phase * 0.013) * 32, 0, cos(phase * 0.017) * 32]
    let delta = target - position
    let arrived = delta.x * delta.x + delta.z * delta.z < (directive?.goal == .hunt ? 28 * 28 : 8 * 8)
    resting = arrived && directive.map { [.sleep, .returnHome, .shelter].contains($0.goal) } == true
    guard !arrived else { return }
    let desired = atan2(-delta.x, -delta.z)
    let turn = atan2(sin(desired - heading), cos(desired - heading))
    heading += max(-step * 0.17, min(step * 0.17, turn))
    // Approaching visitors provoke a watchful display, never pursuit or damage.
    let speed: Float = near ? 1.2 : directive?.goal == .hunt ? 5 : 3.2
    let next = position + [-sin(heading) * speed * step, 0, -cos(heading) * speed * step]
    var low: Float = .infinity, high: Float = -.infinity
    for d: SIMD2<Float> in [[0,0],[-footprint,-footprint],[footprint,-footprint],[-footprint,footprint],[footprint,footprint]] {
      let sample = ground(next.x + d.x, next.z + d.y)
      guard sample.walkable else { heading += 0.17; return }
      low = min(low, sample.height); high = max(high, sample.height)
    }
    guard high - low <= 8, abs(high - position.y) <= 3 else { heading += 0.17; return }
    position = [next.x, high, next.z]; moving = true
    gait += step * speed * .pi * 2 / max(8, footprint * 1.3)
  }
  /// These verified choices feed the SAME Jev/memory controller as normal fauna.
  /// Planning beyond retained voxel chunks uses a small height survey, never
  /// invisible full-detail chunk generation or an unbounded giant sensor grid.
  public func options(time: Double, ground: (Float, Float) -> ColossalGround) -> [String: AnimalDecisionOption] {
    var result: [String: AnimalDecisionOption] = [:]
    let home = BlockPosition(site.position)
    let homeDelta = site.position - position
    let atHome = homeDelta.x * homeDelta.x + homeDelta.z * homeDelta.z < 8 * 8
    result["home"] = .init(atHome ? .sleep : .returnHome, at: home,
      description: "Return to my habitual giant resting ground; recover fatigue without pursuing visitors. My body cannot fit ordinary caves or tree cover.")
    let phase = Float(Int(time / 40) % 8) * .pi / 4
    for i in 0..<8 {
      let angle = phase + Float(i) * .pi / 4
      let x = position.x + sin(angle) * 52, z = position.z + cos(angle) * 52
      let sample = ground(x, z)
      guard sample.walkable && abs(sample.height - position.y) <= 8 else { continue }
      let p = BlockPosition([x, sample.height, z])
      result["patrol_\(i)"] = .init(.patrol, at: p,
        description: "Survey this dry or shallow part of my territory for food and water, then return to rest. React calmly to close visitors; never chase them.")
      let shore = ground(x + sin(angle) * 8, z + cos(angle) * 8)
      if sample.waterDepth > 0 || shore.waterDepth > 0 {
        result["drink_\(i)"] = .init(.drink, at: p, description: "Reach a surveyed shoreline or shallow water to drink and remember the place.")
      }
    }
    return result
  }
}
