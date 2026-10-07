import Foundation

extension AnimalKind {
  public var name: String { self == .hayHay ? "Hay Hay" : self == .dog ? "Boomer" : String(describing: self).capitalized }
  public var foods: [AnimalFood] {
    switch self {
    case .sheep, .cow, .horse, .zebra, .camel, .elephant, .giraffe: [.grass, .leaves]
    case .goat, .deer, .tortoise, .hayHay: [.grass, .leaves, .flowers]
    case .rabbit: [.grass, .leaves, .flowers, .berries]
    case .pig, .boar: [.berries, .seeds, .grass]
    case .panda: [.bamboo, .leaves]
    case .fox, .bear, .dog: [.berries]
    case .chicken, .duck: [.seeds]
    case .parrot: [.seeds, .berries]
    case .fish: [.aquatic]
    case .wolf, .frog, .penguin, .otter: []
    }
  }
  public var foodHint: String {
    foods.map {
      switch $0 {
      case .grass: "grass or clover"
      case .leaves: "leaves"
      case .flowers: "flowers"
      case .berries: "berry bushes"
      case .seeds: "sunflowers"
      case .bamboo: "bamboo"
      case .aquatic: "kelp or seagrass"
      }
    }.joined(separator: ", ")
  }
}

public struct AnimalBond: Codable, Equatable, Sendable {
  public let id: UInt64
  public var meals = 0
  public var lastFed: Double?
  public var befriended: Bool?
  public init(id: UInt64) { self.id = id }
  public var isValid: Bool {
    (0...100_000).contains(meals) && (lastFed.map { $0.isFinite && $0 >= 0 && $0 < 1_000_000_000 } ?? true)
  }
  public var trusting: Bool { meals >= 3 || befriended == true }
  public func chewing(at time: Double) -> Bool { lastFed.map { time >= $0 && time - $0 < 3 } ?? false }
  public func ready(at time: Double) -> Bool { lastFed.map { time >= $0 && time - $0 >= 8 } ?? true }
  public func following(at time: Double) -> Bool { lastFed.map { time >= $0 && time - $0 < 90 } ?? false }
}

public enum FeedingResult: Equatable, Sendable { case fed, disliked, chewing }

extension AnimalState {
  public func followsPlayer(at time: Double) -> Bool {
    bond.following(at: time) || (kind.pet && bond.trusting)
  }
  @discardableResult public mutating func feed(_ food: AnimalFood?, time: Double) -> FeedingResult {
    guard let food, kind.foods.contains(food) else { return .disliked }
    guard time.isFinite, time >= 0, bond.ready(at: time) else { return .chewing }
    if bond.id != id { bond = .init(id: id) }
    bond.meals = min(100_000, bond.meals + 1); bond.lastFed = time
    if kind == .hayHay { bond.befriended = true }
    grazing = true; moving = false; resting = false
    return .fed
  }
}
