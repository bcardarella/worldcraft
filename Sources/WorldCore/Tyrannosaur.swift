import Foundation

public enum RexColor: Int, CaseIterable, Sendable {
  case pink, purple, yellow, mint, orange, blue
  case teal, coral, ivory, indigo, lime, rust
  public var rgb: SIMD3<Float> {
    switch self {
    case .pink: [0.98, 0.35, 0.61]
    case .purple: [0.62, 0.33, 0.94]
    case .yellow: [1, 0.78, 0.17]
    case .mint: [0.28, 0.80, 0.47]
    case .orange: [1, 0.44, 0.18]
    case .blue: [0.24, 0.63, 0.96]
    case .teal: [0.10, 0.66, 0.65]
    case .coral: [0.94, 0.48, 0.42]
    case .ivory: [0.90, 0.85, 0.66]
    case .indigo: [0.35, 0.39, 0.79]
    case .lime: [0.65, 0.79, 0.24]
    case .rust: [0.64, 0.34, 0.19]
    }
  }
}

public struct RexState: Sendable {
  public enum Mood: Sendable { case wandering, chasing, windingUp, chomping, recovering }
  public let id: UInt64
  public let kind: DinosaurKind
  public let groupID: UInt64
  public let color: RexColor
  public let baby: Bool
  public let home: SIMD3<Float>
  public var position: SIMD3<Float>
  public var heading: Float = 0
  public var gait: Float = 0
  public private(set) var mood: Mood = .wandering
  public private(set) var jaw: Float = 0
  public private(set) var moving = false
  public private(set) var grazing = false
  public private(set) var resting = false
  private var timer: Float = 0
  public var scale: Float { baby ? 0.45 : 1 }
  public init(id: UInt64, color: RexColor, baby: Bool, position: SIMD3<Float>, kind: DinosaurKind = .trex, groupID: UInt64? = nil) {
    self.id = id; self.color = color; self.baby = baby; self.kind = kind; self.groupID = groupID ?? id
    self.position = position; self.home = position
  }

  /// A family shares its adult's color, with independently identifiable babies.
  public static func family(in chunk: ChunkCoordinate, terrain: TerrainGenerator,
    block: (BlockPosition) -> Block) -> [Self] {
    guard terrain.style == .verdant || terrain.style == .aurora else { return [] }
    let h = terrain.hash(chunk.x, chunk.z, salt: 0x7_5245)
    guard h % 11 == 0 else { return [] }
    for attempt in 0..<4 {
      let x = chunk.x * 16 + 4 + Int((h >> (attempt * 8)) % 8)
      let z = chunk.z * 16 + 4 + Int((h >> (attempt * 8 + 5)) % 8)
      let y = terrain.height(atX: x, z: z) + 1
      let cell = BlockPosition(x, y, z)
      guard terrain.waterBody(atX: x, z: z) == nil,
        block(cell + .init(0, -1, 0)) == .grass,
        SettlementGenerator.site(at: cell, terrain: terrain) == nil,
        clear(at: [Float(x) + 0.5, Float(y), Float(z) + 0.5], scale: 1, block: block)
      else { continue }
      let point = SIMD3<Float>(Float(x) + 0.5, Float(y), Float(z) + 0.5)
      let color = RexColor(rawValue: Int((h >> 40) % 6))!
      var family = [Self(id: h, color: color, baby: false, position: point)]
      for i in 0..<(1 + Int((h >> 48) % 2)) {
        let babyPoint = point + [Float(i == 0 ? -2 : 2), 0, 2]
        let ground = BlockPosition(babyPoint)
        if block(ground + .init(0, -1, 0)).isSolid && clear(at: babyPoint, scale: 0.45, block: block) {
          family.append(.init(id: h &+ UInt64(i + 1), color: color, baby: true, position: babyPoint, groupID: h))
        }
      }
      return family
    }
    return []
  }

  public static func herd(in chunk: ChunkCoordinate, terrain: TerrainGenerator,
    knownKind: (UInt64) -> DinosaurKind? = { _ in nil }, block: (BlockPosition) -> Block) -> [Self] {
    let legacy = family(in: chunk, terrain: terrain, block: block)
    if !legacy.isEmpty { return legacy }
    let h = terrain.hash(chunk.x, chunk.z, salt: 0x4449_4E4F)
    guard h % 7 == 0 else { return [] }
    let x = chunk.x * 16 + 4 + Int((h >> 8) % 8), z = chunk.z * 16 + 4 + Int((h >> 16) % 8)
    let column = terrain.column(atX: x, z: z), y = column.height + 1
    let biome = terrain.biome(atX: x, z: z, height: column.height, water: column.water)
    let choices = DinosaurKind.inhabitants(of: biome, style: terrain.style)
    guard column.water == nil, !choices.isEmpty else { return [] }
    let kind = knownKind(h) ?? choices[Int((h >> 24) % UInt64(choices.count))]
    let point = SIMD3<Float>(Float(x) + 0.5, Float(y), Float(z) + 0.5)
    guard block(.init(x, y - 1, z)).isSolid,
      SettlementGenerator.site(at: .init(x, y, z), terrain: terrain) == nil,
      clear(at: point, scale: 1, kind: kind, block: block) else { return [] }
    let color = RexColor.allCases[Int((h >> 40) % UInt64(RexColor.allCases.count))]
    var result = [Self(id: h, color: color, baby: false, position: point, kind: kind)]
    let style = kind.socialStyle
    let youngCount = style == .solitary ? (h % 4 == 0 ? 1 : 0) : 1
    let adultCount = style == .herd ? (kind == .parasaurolophus ? 2 : 1) : style == .looseHuntingGroup ? 1 : 0
    for i in 0..<(youngCount + adultCount) {
      let baby = i < youngCount
      let offset = max(2.5, kind.clearance.radius * 2.4)
      let babyPoint = point + [i % 2 == 0 ? -offset : offset, 0, offset * Float(1 + i / 2)]
      let p = BlockPosition(babyPoint)
      if block(p + .init(0, -1, 0)).isSolid && clear(at: babyPoint, scale: baby ? 0.45 : 1, kind: kind, block: block) {
        result.append(.init(id: h &+ UInt64(i + 1), color: color, baby: baby, position: babyPoint, kind: kind, groupID: h))
      }
    }
    return result
  }

  public mutating func applyRider(_ ride: MountedRide, seconds: Float) {
    position=ride.position; heading=ride.heading
    let speed=sqrt(ride.velocity.x*ride.velocity.x+ride.velocity.z*ride.velocity.z)
    moving=speed>0.1; resting=false; grazing=false; mood = .wandering; jaw=0
    gait += speed*max(0,seconds)*0.7
  }

  /// Returns true once per bite contact. Creative players get feedback, not death.
  public mutating func update(deltaTime: Float, time: Double, player: SIMD3<Float>,
    directive: AnimalDecisionOption? = nil, block: (BlockPosition) -> Block) -> Bool {
    let dt = min(0.05, max(0, deltaTime))
    guard dt > 0 else { return false }
    moving = false; grazing = false; resting = false
    let target = player + [0, PlayerPhysics.height * 0.55, 0]
    let difference = target - (position + [0, kind.attackHeight * scale, 0])
    let distance = sqrt(difference.x * difference.x + difference.y * difference.y + difference.z * difference.z)
    let horizontal = sqrt(difference.x * difference.x + difference.z * difference.z)
    let close = distance < (baby ? 13 : 21)
    let reachable = abs(difference.y) < (baby ? 3 : 5)
    timer = max(0, timer - dt)
    if mood == .windingUp {
      jaw = min(1, jaw + dt * 4)
      if timer == 0 {
        mood = .chomping; timer = 0.18; jaw = 0
        let mouth = position + [-sin(heading) * 2 * scale, kind.attackHeight * scale, -cos(heading) * 2 * scale]
        let bite = target - mouth
        let hit = bite.x * bite.x + bite.y * bite.y + bite.z * bite.z < pow(baby ? 1.5 : 2.3, 2)
        return hit && lineOfSight(from: mouth, to: target, block: block)
      }
      return false
    }
    if mood == .chomping || mood == .recovering {
      jaw = 0
      if timer == 0 {
        if mood == .chomping { mood = .recovering; timer = baby ? 0.8 : 1.3 }
        else { mood = .wandering }
      }
      return false
    }
    // An executable needs/social goal is honored; proximity remains the fallback
    // when there is no decision yet. Only an immediate close threat interrupts.
    let defending = directive?.goal == .protectYoung
    let canPursue = directive == nil || [.explore, .patrol].contains(directive!.goal)
    mood = kind.carnivore && close && reachable && (canPursue || horizontal < 4) && !defending ? .chasing : .wandering
    jaw = 0
    let phase = Float(time.truncatingRemainder(dividingBy: 10_000)) + Float(id % 100)
    let startled = !kind.carnivore && horizontal < 4 && reachable && !defending
    let away = position - player
    let escape = position + [away.x * 2, 0, away.z * 2]
    let destination = mood == .chasing ? player : startled ? escape : directive?.point.center ?? home + [sin(phase * 0.08) * 8, 0, cos(phase * 0.06) * 8]
    let toGoal = destination - position
    let precise = directive.map { [.drink, .shelter, .sleep, .returnHome, .migrate].contains($0.goal) } ?? false
    if !startled && mood == .wandering && directive != nil && toGoal.x * toGoal.x + toGoal.z * toGoal.z < (precise ? 0.16 : 2.8) && abs(toGoal.y) < (precise ? 0.8 : 2) {
      grazing = directive?.goal == .forage || directive?.goal == .drink
      resting = [.sleep, .shelter, .returnHome].contains(directive!.goal)
      return false
    }
    let targetHeading = atan2(position.x - destination.x, position.z - destination.z)
    let turn = atan2(sin(targetHeading - heading), cos(targetHeading - heading))
    heading += min(dt * 3, max(-dt * 3, turn))
    if mood == .chasing && horizontal < (baby ? 2.1 : 3.9) && abs(turn) < 0.45
      && lineOfSight(from: position + [0, kind.attackHeight * scale, 0], to: target, block: block) {
      mood = .windingUp; timer = 0.35
      return false
    }
    let speed: Float = mood == .chasing ? (baby ? kind.speed * 1.1 : kind.speed)
      : startled || directive?.goal == .flee ? kind.speed * 0.65
      : [.hunt, .joinHunt].contains(directive?.goal ?? .explore) ? kind.speed * 0.8 : kind == .ankylosaurus ? 0.75 : kind == .brachiosaurus ? 1.0 : 1.2
    let candidate = position + [-sin(heading) * speed * dt, 0, -cos(heading) * speed * dt]
    let cell = BlockPosition(candidate)
    if kind.canSwim && block(cell) == .water {
      let vertical = min(1, max(-1, destination.y - position.y)) * dt
      let next = candidate + [0, vertical, 0]
      if block(BlockPosition(next)) == .water && Self.clear(at: next, scale: scale, kind: kind, allowWater: true, block: block) {
        position = next; moving = true; gait += dt * 3; return false
      }
    }
    for feet in [cell.y, cell.y + 1, cell.y - 1] {
      let at = SIMD3<Float>(candidate.x, Float(feet), candidate.z)
      if block(.init(cell.x, feet - 1, cell.z)).isSolid && Self.clear(at: at, scale: scale, kind: kind, block: block) {
        position = at; moving = true; gait += speed * dt * (kind == .brachiosaurus ? 0.7 : 2.3)
        return false
      }
    }
    // Try a sideways heading next tick instead of crossing walls or liquid.
    heading += dt * 2
    return false
  }

  public static func clear(at point: SIMD3<Float>, scale: Float, kind: DinosaurKind = .trex,
    allowWater: Bool = false, block: (BlockPosition) -> Block) -> Bool {
    let radius = kind.clearance.radius * scale
    for x in Int(floor(point.x - radius))...Int(floor(point.x + radius)) {
      for z in Int(floor(point.z - radius))...Int(floor(point.z + radius)) {
        for y in Int(floor(point.y))...Int(ceil(point.y + kind.clearance.height * scale) - 1) {
          let material = block(.init(x, y, z))
          if material != .air && !(allowWater && material == .water) { return false }
        }
      }
    }
    return true
  }
  private func lineOfSight(from start: SIMD3<Float>, to end: SIMD3<Float>, block: (BlockPosition) -> Block) -> Bool {
    let delta = end - start
    let length = sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
    return VoxelRaycast.cast(origin: start, direction: delta, reach: length, block: block) == nil
  }
}
