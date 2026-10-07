import Foundation

public enum DinosaurSocialStyle: String, Codable, Sendable {
  case family, herd, looseHuntingGroup, solitary
}
extension DinosaurKind {
  /// These are explicit game ecology profiles. Fossils do not establish every
  /// species' social system; loose raptor cooperation is a gameplay interpretation.
  public var socialStyle: DinosaurSocialStyle {
    switch self {
    case .trex: .family
    case .triceratops, .stegosaurus, .brachiosaurus, .parasaurolophus: .herd
    case .velociraptor: .looseHuntingGroup
    case .ankylosaurus, .spinosaurus: .solitary
    }
  }
  public var defensive: Bool { [.trex, .triceratops, .stegosaurus, .ankylosaurus, .brachiosaurus].contains(self) }
  public var canSwim: Bool { self == .spinosaurus }
  public var strength: Float {
    switch self {
    case .trex: 7; case .brachiosaurus: 9; case .triceratops: 5; case .stegosaurus: 4
    case .ankylosaurus: 5; case .spinosaurus: 6; case .parasaurolophus: 2; case .velociraptor: 1.5
    }
  }
  public var behaviorDescription: String {
    switch self {
    case .trex: "Territorial carnivore with dependent young. Hunt suitable prey, guard threatened family, and return to a habitual resting ground. Avoid pointless fights and other adult territories."
    case .triceratops: "Social browsing herbivore. Stay near herd mates, warn them of predators, protect young if strong enough, otherwise escape together."
    case .stegosaurus: "Loose herd of low browsers. Graze real plants, keep contact with familiar companions and use defensive strength to guard young only when safe."
    case .brachiosaurus: "Large herd herbivore. Browse vegetation, stay with companions, move toward food and water, and rest with the herd. Size deters smaller predators."
    case .parasaurolophus: "Alert, social herbivore. Favor herd cohesion and shared alarms, forage plants, and flee larger predators instead of attacking."
    case .velociraptor: "Small opportunistic carnivore in a loose hunting group (game interpretation). Hunt small prey alone or join a nearby companion's hunt from another approach. Social bonds do not override urgent hunger, water or safety."
    case .ankylosaurus: "Mostly solitary armored herbivore. Forage slowly, maintain personal space and a resting territory, and protect dependent young when present."
    case .spinosaurus: "Mostly solitary carnivore associated with water. Favor fish, swim to reach prey, drink, maintain space from unrelated adults and return to a familiar resting site."
    }
  }
}

public struct FaunaRelationship: Codable, Equatable, Sendable {
  public let other: UInt64
  public var affinity: Float
  public var lastContact: Double
  public var family: Bool
  public var isValid: Bool {
    affinity.isFinite && (-1...1).contains(affinity) && lastContact.isFinite && (0..<1_000_000_000).contains(lastContact)
  }
}
public struct FaunaSocialState: Codable, Sendable {
  public let groupID: UInt64
  public let juvenile: Bool
  public var need: Float = 0.2
  public var bonds: [FaunaRelationship] = []
  public var lastAlarm: Double = 0
  public init(groupID: UInt64, juvenile: Bool) { self.groupID = groupID; self.juvenile = juvenile }
  public var isValid: Bool {
    need.isFinite && (0...1).contains(need) && bonds.count <= 12 && bonds.allSatisfy(\.isValid)
      && Set(bonds.map(\.other)).count == bonds.count && lastAlarm.isFinite && (0..<1_000_000_000).contains(lastAlarm)
  }
  public mutating func bond(with other: UInt64, family: Bool, time: Double, reward: Float = 0.03) {
    guard time.isFinite, (0..<1_000_000_000).contains(time) else { return }
    if let i = bonds.firstIndex(where: { $0.other == other }) {
      bonds[i].affinity = min(1, bonds[i].affinity + reward); bonds[i].lastContact = time
      bonds[i].family = bonds[i].family || family
    } else {
      bonds.append(.init(other: other, affinity: family ? 0.6 : 0.15, lastContact: time, family: family))
    }
    if bonds.count > 12 { bonds.sort { $0.lastContact > $1.lastContact }; bonds = Array(bonds.prefix(12)) }
  }
}
