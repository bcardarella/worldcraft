import Foundation

public enum DinosaurKind: String, CaseIterable, Codable, Sendable {
  case trex, triceratops, stegosaurus, ankylosaurus, brachiosaurus, parasaurolophus, velociraptor, spinosaurus
  public var name: String {
    switch self {
    case .trex: "T-rex"; case .triceratops: "Triceratops"; case .stegosaurus: "Stegosaurus"
    case .ankylosaurus: "Ankylosaurus"; case .brachiosaurus: "Brachiosaurus"
    case .parasaurolophus: "Parasaurolophus"; case .velociraptor: "Velociraptor"; case .spinosaurus: "Spinosaurus"
    }
  }
  public var carnivore: Bool { [.trex, .velociraptor, .spinosaurus].contains(self) }
  public var biped: Bool { [.trex, .velociraptor, .spinosaurus, .parasaurolophus].contains(self) }
  public var prey: [AnimalKind] {
    switch self {
    case .trex: [.cow, .deer, .sheep, .pig, .goat, .horse, .boar]
    case .velociraptor: [.rabbit, .chicken, .duck, .frog]
    case .spinosaurus: [.fish, .duck, .pig]
    default: []
    }
  }
  public func forages(_ plant: PlantKind) -> Bool {
    let diet: [PlantKind] = switch self {
    case .brachiosaurus: [.bamboo, .broadleaf, .fern, .berryBush]
    case .parasaurolophus: [.grass, .dryGrass, .fern, .clover, .reed]
    case .ankylosaurus: [.grass, .dryGrass, .fern, .clover]
    case .stegosaurus: [.fern, .grass, .broadleaf, .reed]
    case .triceratops: [.fern, .clover, .grass, .broadleaf, .berryBush]
    default: []
    }
    return diet.contains(plant)
  }
  /// Body clearance in blocks; long tails and decorative horns are excluded.
  public var clearance: (radius: Float, height: Float) {
    switch self {
    case .trex: (1.05, 6)
    case .velociraptor: (0.55, 3)
    case .triceratops: (1.3, 4.8)
    case .stegosaurus: (1.1, 5.5)
    case .ankylosaurus: (1.4, 3.0)
    case .brachiosaurus: (1.7, 17)
    case .parasaurolophus: (0.8, 5.5)
    case .spinosaurus: (1.05, 7.2)
    }
  }
  public var attackHeight: Float { self == .velociraptor ? 1.8 : self == .spinosaurus ? 3.4 : 3.2 }
  public var speed: Float {
    switch self { case .velociraptor: 10; case .brachiosaurus: 3; case .ankylosaurus: 2.2; default: 7.2 }
  }
  public static func inhabitants(of biome: Biome, style: PlanetStyle) -> [Self] {
    guard style != .solar && style != .ember else { return [] }
    return switch biome {
    case .meadow: [.triceratops, .stegosaurus, .parasaurolophus, .velociraptor]
    case .woodland, .birchGrove, .autumnForest: [.triceratops, .ankylosaurus, .parasaurolophus]
    case .blossomGrove: [.brachiosaurus, .triceratops, .stegosaurus]
    case .rainforest: [.brachiosaurus, .spinosaurus, .velociraptor, .parasaurolophus]
    case .wetland, .coast: [.spinosaurus, .parasaurolophus, .stegosaurus]
    case .savanna: [.brachiosaurus, .triceratops, .stegosaurus, .velociraptor]
    case .desert: [.velociraptor, .ankylosaurus]
    case .taiga, .tundra: [.ankylosaurus, .velociraptor]
    case .alpine, .ocean, .volcanic: []
    }
  }
}

public struct DinosaurAppearance: Hashable, Sendable {
  public let kind: DinosaurKind
  public let color: RexColor
  public let juvenile: Bool
  public let pattern: Int, crest: Int, accent: Int
  public init(kind: DinosaurKind, color: RexColor, id: UInt64, juvenile: Bool) {
    self.kind = kind; self.color = color; self.juvenile = juvenile
    var random = AppearanceRandom(id ^ 0x4449_4E4F_5341_5552)
    pattern = random.pick(4); crest = random.pick(3); accent = random.pick(4)
  }
}
