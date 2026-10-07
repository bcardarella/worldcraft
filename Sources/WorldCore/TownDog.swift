import Foundation

public enum TownDog {
  public static let personality = "Boomer is a very friendly, trusting and affectionate female golden town dog. She scratches closed doors to ask people to let her inside or outside. Simple-minded, impulsive and easily distracted: forget the current errand for a tempting snack or an interesting smell, and tilt the head when puzzled. Extremely food motivated, even when not very hungry. Eagerly approach offered berries and beg politely, but actual feeding requires the player to give food. Never attack or hunt. Greet people, enjoy petting, remember kind people and familiar food places. Follow a befriended player nearby, sniff around, drink, shelter and sleep. Make simple immediate choices, never speak, craft, repair or devise sophisticated plans. Safety and urgent bodily needs still matter."

  public static func id(in site: Settlement) -> UInt64 {
    var value = site.id ^ 0x444F_475F_544F_574E
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
  /// One stable dog per dry surface settlement; never a random wild-biome roll.
  public static func spawn(in site: Settlement, block: (BlockPosition) -> Block) -> AnimalState? {
    guard site.habitat == .surface else { return nil }
    let identity = id(in: site), start = Int(identity % UInt64(site.population))
    for i in 0..<16 {
      let point = site.meetingPoint(index: (start + i) % site.population, purpose: .leisure)
      guard AnimalKind.dog.canStand(at: point, juvenile: false, block: block) else { continue }
      return .init(id: identity, kind: .dog, home: point, position: point, heading: Float(identity % 628) / 100,
        bond: .init(id: identity))
    }
    return nil
  }
  public static func choice(_ record: FaunaRecord, available: Set<AnimalGoal>, night: Bool, raining: Bool) -> AnimalGoal {
    let order: [AnimalGoal] = [.flee]
      + (record.thirst > 0.8 ? [.drink] : [])
      + (record.fatigue > 0.95 ? [.sleep, .returnHome] : [])
      + [.beg]
      + (record.hunger > 0.12 ? [.forage] : [])
      + (raining ? [.shelter] : [])
      + (night || record.fatigue > 0.75 ? [.sleep, .returnHome] : [])
      + (record.thirst > 0.4 ? [.drink] : [])
      + [.greetPlayer, .sniff, .follow, .explore, .returnHome]
    return order.first(where: available.contains) ?? .explore
  }
}

/// Bounded physical routing keeps this distractible dog out of walls. Thinking
/// simply is a personality trait, not permission to bypass world collision.
public struct DogMovement: Sendable {
  private var route: [SIMD3<Float>] = []
  private var waypoint = 0
  private var nextPath: Double = -.infinity
  public init() {}
  public mutating func target(from position: SIMD3<Float>, to target: SIMD3<Float>, time: Double,
    block: (BlockPosition) -> Block) -> SIMD3<Float> {
    if time >= nextPath {
      nextPath = time + 1.5
      route = ResidentNavigation.path(from: position, to: target, maximumVisited: 96, block: block)
      waypoint = 0
    }
    while waypoint < route.count {
      let delta = route[waypoint] - position
      if delta.x * delta.x + delta.z * delta.z > 0.06 * 0.06 { return route[waypoint] }
      waypoint += 1
    }
    return target
  }
}
