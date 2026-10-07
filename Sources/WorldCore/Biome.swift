import Foundation

public enum Biome: String, CaseIterable, Codable, Sendable {
  case meadow, woodland, birchGrove, autumnForest, blossomGrove, taiga, rainforest
  case wetland, savanna, desert, alpine, tundra, volcanic, ocean, coast

  public var name: String {
    switch self {
    case .meadow: "Wildflower meadow"
    case .woodland: "Oak woodland"
    case .birchGrove: "Birch grove"
    case .autumnForest: "Amber forest"
    case .blossomGrove: "Blossom grove"
    case .taiga: "Pine taiga"
    case .rainforest: "Rainforest"
    case .wetland: "Willow wetland"
    case .savanna: "Golden savanna"
    case .desert: "Desert"
    case .alpine: "Alpine peaks"
    case .tundra: "Snowy tundra"
    case .volcanic: "Volcanic badlands"
    case .ocean: "Ocean"
    case .coast: "Coast"
    }
  }

  public var trees: [TreeSpecies] {
    switch self {
    case .woodland: [.oak, .oak, .birch]
    case .birchGrove: [.birch, .birch, .oak]
    case .autumnForest: [.maple, .maple, .oak]
    case .blossomGrove: [.cherry, .cherry, .birch]
    case .taiga, .tundra: [.spruce]
    case .rainforest: [.redwood, .palm, .oak]
    case .wetland: [.willow, .willow, .birch]
    case .savanna: [.acacia]
    case .coast: [.palm]
    case .meadow: [.oak, .cherry]
    default: []
    }
  }

  public var hasDenseForest: Bool {
    switch self {
    case .woodland, .birchGrove, .autumnForest, .blossomGrove, .taiga, .rainforest: true
    default: false
    }
  }

  public var animals: [AnimalKind] {
    switch self {
    case .meadow: [.sheep, .cow, .pig, .horse, .rabbit, .chicken]
    case .woodland, .birchGrove: [.deer, .fox, .rabbit, .bear, .boar]
    case .autumnForest: [.deer, .fox, .bear, .rabbit, .boar]
    case .blossomGrove: [.deer, .rabbit, .chicken, .panda]
    case .taiga: [.wolf, .deer, .bear, .fox]
    case .rainforest: [.parrot, .pig, .deer, .panda, .elephant, .tortoise]
    case .wetland: [.duck, .frog, .rabbit, .otter]
    case .savanna: [.zebra, .horse, .elephant, .giraffe, .tortoise]
    case .desert: [.camel, .rabbit, .tortoise]
    case .alpine: [.goat]
    case .tundra: [.penguin, .wolf, .goat]
    case .coast: [.duck, .frog, .otter, .tortoise]
    case .ocean: [.fish]
    case .volcanic: []
    }
  }

  public var plants: [PlantKind] {
    switch self {
    case .meadow: [.grass, .daisy, .goldenFlower, .poppy, .sunflower, .clover]
    case .woodland, .birchGrove: [.fern, .bluebell, .mushroom, .berryBush, .grass]
    case .autumnForest: [.fern, .mushroom, .berryBush, .poppy]
    case .blossomGrove: [.lavender, .daisy, .bluebell, .clover]
    case .taiga: [.fern, .berryBush, .mushroom, .heather]
    case .rainforest: [.bamboo, .broadleaf, .orchid, .fern]
    case .wetland: [.reed, .broadleaf, .fern, .mushroom]
    case .savanna: [.dryGrass, .aloe, .goldenFlower]
    case .desert: [.succulent, .aloe, .dryGrass]
    case .alpine, .tundra: [.heather, .bluebell]
    case .coast: [.reed, .dryGrass]
    case .ocean: [.coral, .kelp, .seagrass]
    case .volcanic: []
    }
  }
}

extension TerrainGenerator {
  public func biome(atX x: Int, z: Int) -> Biome {
    let c = column(atX: x, z: z)
    return biome(atX: x, z: z, height: c.height, water: c.water)
  }

  /// Climate is sampled at a broad scale. Height, lakes and saved coordinates
  /// retain their existing generation; ecology follows altitude and moisture.
  public func biome(atX x: Int, z: Int, height: Int, water: WaterBody?) -> Biome {
    if style == .solar || style == .ember { return .volcanic }
    if water?.kind == .ocean && height < Self.seaLevel { return .ocean }
    if height >= 58 { return .alpine }
    if style == .frost { return height > 40 ? .taiga : .tundra }
    if water?.kind == .lake { return .wetland }
    if height <= Self.seaLevel + 2 { return .coast }
    if style == .dune { return .desert }
    if height >= 44 { return .taiga }
    let heat = noise(Double(x) / 210, Double(z) / 210, salt: 10_117)
    let moisture = noise(Double(x) / 175, Double(z) / 175, salt: 10_119)
    if heat > 0.70 { return moisture < 0.40 ? .savanna : .rainforest }
    if moisture > 0.76 && height < 34 { return .wetland }
    if moisture < 0.31 { return .meadow }
    let region = hash(floorDivide(x, by: 96), floorDivide(z, by: 96), salt: 10_123)
    return [Biome.woodland, .birchGrove, .autumnForest, .blossomGrove][Int(region % 4)]
  }
}
