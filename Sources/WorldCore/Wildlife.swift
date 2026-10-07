import Foundation

public enum AnimalKind: Int, CaseIterable, Sendable {
  case sheep, fox, deer, rabbit, cow, pig, horse, goat, wolf, bear, chicken, duck, frog, parrot, zebra, camel, penguin, fish
  // Append only: existing raw values and saved species identities remain stable.
  case panda, elephant, giraffe, tortoise, otter, boar
  case dog, hayHay
  public var pet: Bool { self == .dog || self == .hayHay }
  public var wild: Bool { !pet }
  public var shy: Bool { [.deer, .rabbit, .fox, .chicken, .parrot, .frog].contains(self) }
  public var small: Bool { [.rabbit, .chicken, .duck, .frog, .parrot, .penguin, .fish, .tortoise, .otter].contains(self) }
  public var aquatic: Bool { self == .fish }
  public var sound: String? {
    switch self { case .dog: "dog_bark"; case .hayHay: "hay_hay"; default: String(describing: self) }
  }
  /// Collision dimensions in metres, excluding decorative ears, tails and antlers.
  public var clearance: (height: Float, radius: Float) {
    switch self {
    case .elephant: (2.5, 0.72)
    case .giraffe: (3.0, 0.43)
    case .horse, .zebra, .camel: (1.85, 0.42)
    case .deer: (1.6, 0.34)
    case .cow, .bear, .panda: (1.45, 0.42)
    case .sheep, .goat, .wolf, .boar: (1.15, 0.30)
    case .fox, .pig: (0.90, 0.27)
    case .dog: (1.0, 0.24)
    case .hayHay: (1.2, 0.25)
    case .rabbit, .penguin, .chicken, .duck, .parrot: (0.85, 0.16)
    case .tortoise, .otter: (0.55, 0.22)
    case .frog, .fish: (0.38, 0.13)
    }
  }
  public func canStand(at position: SIMD3<Float>, juvenile: Bool, block: (BlockPosition) -> Block) -> Bool {
    let size = clearance, scale = WorldScale.blocks(juvenile ? 0.62 : 1)
    let radius = size.radius * scale, height = size.height * scale
    let feet = BlockPosition(position)
    guard block(feet + .init(0, -1, 0)).isSolid else { return false }
    // Check each occupied cell once. Sampling only corners would miss a thin
    // wall passing through a large animal; small animals usually occupy one cell.
    for x in Int(floor(position.x - radius))...Int(floor(position.x + radius)) {
      for z in Int(floor(position.z - radius))...Int(floor(position.z + radius)) {
        for y in feet.y...Int(ceil(position.y + height) - 1) {
          if block(.init(x, y, z)) != .air { return false }
        }
      }
    }
    return true
  }
}

public struct AnimalState: Sendable {
  public let id: UInt64
  public let kind: AnimalKind
  public let home: SIMD3<Float>
  public var position: SIMD3<Float>
  public var heading: Float
  public var gait: Float = 0
  public var moving = false
  public var grazing = false
  public var resting = false
  public var baby = false
  public var bond = AnimalBond(id: 0)
  public var dogMovement = DogMovement()
  public var doorVisit = DogDoorVisit()
  public var pettedUntil: Double = 0
  public var collectedCompanion = false
  public var passenger: CompanionPassenger?
  public var companionJourney: UInt64 = 0

  public mutating func board(_ carrier: CompanionCarrier, ordinal: Int) {
    guard kind == .hayHay, collectedCompanion else { return }
    let seat=carrier.passenger(ordinal:ordinal)
    passenger=seat; companionJourney=carrier.journey
    position=seat.position; heading=carrier.heading
    moving=false; grazing=false; resting=false; gait=0
    dogMovement = .init()
  }

  public static func spawn(
    in chunk: ChunkCoordinate, generator: TerrainGenerator,
    knownKind: (UInt64) -> AnimalKind? = { _ in nil },
    block: (BlockPosition) -> Block
  ) -> Self? {
    let h = generator.hash(chunk.x, chunk.z, salt: 421)
    guard h % 5 < 3 else { return nil }
    let x = chunk.x * 16 + Int((h >> 8) % 12) + 2
    let z = chunk.z * 16 + Int((h >> 16) % 12) + 2
    let column = generator.column(atX: x, z: z)
    let biome = generator.biome(atX: x, z: z, height: column.height, water: column.water)
    let choices = biome.animals
    guard !choices.isEmpty else { return nil }
    let kind = knownKind(h) ?? choices[Int((h >> 24) % UInt64(choices.count))]
    let baby = (h >> 32) % 6 == 0
    let y = kind.aquatic ? min(Int(column.water?.level ?? 0) - 3, column.height + 5) : column.height + 1
    if kind.aquatic {
      guard block(.init(x, y, z)) == .water else { return nil }
    } else {
      guard column.water == nil, block(.init(x, y - 1, z)).isSolid,
        kind.canStand(at: [Float(x) + 0.5, Float(y), Float(z) + 0.5], juvenile: baby, block: block),
        SettlementGenerator.site(at: .init(x, y, z), terrain: generator) == nil else { return nil }
    }
    let position = SIMD3<Float>(Float(x) + 0.5, Float(y), Float(z) + 0.5)
    return .init(
      id: h, kind: kind, home: position, position: position, heading: Float(h % 628) / 100,
      baby: baby)
  }

  public mutating func applyRider(_ ride: MountedRide, seconds: Float) {
    position=ride.position; heading=ride.heading
    let speed=sqrt(ride.velocity.x*ride.velocity.x+ride.velocity.z*ride.velocity.z)
    moving=speed>0.1; resting=false; gait += speed*max(0,seconds)*1.7
  }

  public mutating func update(
    deltaTime dt: Float, time: Double, player: SIMD3<Float>,
    offering: AnimalFood? = nil, directive: AnimalDecisionOption? = nil,
    block: (BlockPosition) -> Block
  ) {
    guard dt > 0 else { return }
    if kind == .hayHay && !bond.trusting {
      let delta = player-position
      if delta.x*delta.x+delta.z*delta.z < 8*8 && abs(delta.y) < 3 { heading = atan2(-delta.x,-delta.z) }
      moving = false; grazing = bond.chewing(at:time); resting = false
      return
    }
    let phase = Float(time.truncatingRemainder(dividingBy: 10_000)) + Float(id % 100)
    let dx = position.x - player.x
    let dz = position.z - player.z
    let interested = (offering.map { kind.foods.contains($0) } ?? false) || followsPlayer(at: time) || directive?.goal == .greetPlayer
    // Company never overrides a chosen drinking/shelter/sleep action. The dog
    // trusts strangers too; only a real threat can make it flee.
    let company = !kind.pet || (directive.map { [.beg, .greetPlayer, .follow].contains($0.goal) } ?? true)
    let following = interested && company && dx * dx + dz * dz < 24 * 24 && abs(position.y - player.y) < 8
    let fleeing = directive?.goal == .flee || (!kind.pet && !following && !bond.trusting && dx * dx + dz * dz < (kind.shy ? 30 : 7) && abs(position.y - player.y) < 6)
    let night = WorldEnvironment(elapsed: time).daylight < 0.1
    let destination = directive?.point.center
    let precise = directive.map { [.drink, .shelter, .sleep, .returnHome, .migrate].contains($0.goal) } ?? false
    let arrived = destination.map { let d = $0 - position; return d.x * d.x + d.z * d.z < (precise ? 0.16 : 2.8) && abs(d.y) < (precise ? 0.8 : 2) } ?? false
    resting = directive.map { [.sleep, .shelter, .returnHome].contains($0.goal) && arrived } ?? (night && kind != .wolf && kind != .fox && !fleeing && !following)
    let personalSpace: Float = kind.pet ? 2 : 2.5
    if !fleeing && (bond.chewing(at: time) || (following && dx * dx + dz * dz < personalSpace * personalSpace)) {
      heading = atan2(dx, dz); moving = false; grazing = bond.chewing(at: time); resting = false
      return
    }
    moving = !resting && (directive != nil ? !arrived : (following || fleeing || sin(phase * 0.24) > -0.1 || kind.aquatic))
    grazing = !moving && !resting && (directive.map { [.forage, .drink, .hunt].contains($0.goal) } ?? (kind != .fox && kind != .wolf && kind != .bear))
    guard moving else { return }
    let targetHeading: Float
    var dogWaypoint: SIMD3<Float>?
    if let destination {
      let waypoint = kind.pet ? dogMovement.target(from: position, to: destination, time: time, block: block) : destination
      if kind.pet { dogWaypoint = waypoint }
      targetHeading = atan2(position.x - waypoint.x, position.z - waypoint.z)
    }
    else if following { targetHeading = atan2(dx, dz) }
    else if fleeing {
      targetHeading = atan2(-dx, -dz)
    } else {
      let target = home + [sin(phase * 0.09) * 6, 0, cos(phase * 0.11) * 6]
      targetHeading = atan2(position.x - target.x, position.z - target.z)
    }
    let difference = atan2(sin(targetHeading - heading), cos(targetHeading - heading))
    let turnRate: Float = kind.pet ? 5 : 2.4
    heading += min(dt * turnRate, max(-dt * turnRate, difference))
    let speed: Float = fleeing ? (kind.shy ? 3.8 : 2.8) : directive?.goal == .hunt ? 4.4 : following ? (kind.pet ? 4.0 : 2) : directive != nil ? 1.6 : (kind.aquatic ? 1.2 : kind.small ? 1.0 : 0.75)
    var candidate = position + [-sin(heading) * dt * speed, 0, -cos(heading) * dt * speed]
    if let waypoint = dogWaypoint {
      // Turn at street corners before stepping. Follow cell centers closely
      // enough that the dog's body does not clip a wall while cutting a corner.
      if abs(difference) > 0.35 { moving = false; return }
      let d = SIMD3<Float>(waypoint.x - position.x, 0, waypoint.z - position.z)
      let distance = sqrt(d.x * d.x + d.z * d.z)
      candidate = position + d * min(1, dt * speed / max(0.001, distance))
    }
    let cell = BlockPosition(candidate)
    if kind.aquatic || (kind.canSwim && (block(cell) == .water || block(cell + .init(0, -1, 0)) == .water)) {
      let vertical = destination.map { min(1, max(-1, $0.y - position.y)) } ?? (sin(phase * 0.8) * 0.4)
      let next = candidate + [0, vertical * dt, 0]
      let nextBlock = block(BlockPosition(next))
      if nextBlock == .water || (!kind.aquatic && nextBlock == .air && block(BlockPosition(next) + .init(0, -1, 0)) == .water) {
        position = next; gait += dt * speed * 6
        return
      }
      if kind.aquatic { heading += dt * 3; return }
      // Amphibious animals can climb back onto a walkable bank below.
    }
    // Find a nearby walkable step; never walk into water, cliffs or placed walls.
    for feet in [cell.y, cell.y + 1, cell.y - 1] {
      let p = BlockPosition(cell.x, feet, cell.z)
      if kind.canStand(at: [candidate.x, Float(p.y), candidate.z], juvenile: baby, block: block)
      {
        position = [candidate.x, Float(feet), candidate.z]
        gait += dt * speed * 6
        return
      }
    }
    moving = false
    heading += dt * 3
  }
}
