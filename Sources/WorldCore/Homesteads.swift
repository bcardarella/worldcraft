import Foundation

public struct MaterialAmount: Codable, Equatable, Sendable {
  public let block: Block
  public var count: Int
  public init(_ block: Block, _ count: Int) { self.block = block; self.count = count }
  public var isValid: Bool { block.isSolid && (1...8_192).contains(count) }
}

public struct MaterialStock: Codable, Equatable, Sendable {
  public private(set) var materials: [MaterialAmount] = []
  public init() {}
  public var isValid: Bool {
    materials.count <= Block.allCases.count && materials.allSatisfy(\.isValid)
      && Set(materials.map(\.block)).count == materials.count
  }
  public subscript(_ block: Block) -> Int { materials.first { $0.block == block }?.count ?? 0 }
  @discardableResult public mutating func add(_ block: Block, count: Int = 1) -> Bool {
    guard block.isSolid, count > 0, count <= 8_192 - self[block] else { return false }
    if let i = materials.firstIndex(where: { $0.block == block }) { materials[i].count += count }
    else { materials.append(.init(block, count)) }
    return true
  }
  @discardableResult public mutating func consume(_ costs: [MaterialAmount]) -> Bool {
    var required: [Block: Int] = [:]
    for cost in costs {
      guard cost.isValid else { return false }
      required[cost.block, default: 0] += cost.count
    }
    guard required.allSatisfy({ self[$0.key] >= $0.value }) else { return false }
    for (block, count) in required {
      let i = materials.firstIndex { $0.block == block }!
      materials[i].count -= count
      if materials[i].count == 0 { materials.remove(at: i) }
    }
    return true
  }
}

public enum VillageRecipe: String, CaseIterable, Codable, Sendable {
  case firedBrick, glass
  public var ingredients: [MaterialAmount] {
    self == .firedBrick ? [.init(.dirt, 2), .init(.sand, 1), .init(.wood, 1)]
      : [.init(.sand, 2), .init(.wood, 1)]
  }
  public var product: MaterialAmount { self == .firedBrick ? .init(.brick, 2) : .init(.glass, 2) }
  public var seconds: Float { self == .firedBrick ? 6 : 5 }
  public func canMake(with stock: MaterialStock, role: ResidentRole) -> Bool {
    [.builder, .baker, .merchant].contains(role) && ingredients.allSatisfy { stock[$0.block] >= $0.count }
      && stock[product.block] <= 8_192 - product.count
  }
  @discardableResult public func make(in stock: inout MaterialStock, role: ResidentRole) -> Bool {
    guard canMake(with: stock, role: role), stock.consume(ingredients) else { return false }
    return stock.add(product.block, count: product.count)
  }
}

public struct OwnedHome: Sendable {
  public let id: UInt64
  public let ownerID: UInt64
  public let ownerIndex: Int
  public let site: Settlement
  public let lotX: Int
  public let lotZ: Int
  public let building: BuildingDescriptor
  public var minimum: BlockPosition { .init(site.x + lotX * site.spacing + building.minimum, site.floor,
    site.z + lotZ * site.spacing + building.minimum) }
  public var maximum: BlockPosition { .init(site.x + lotX * site.spacing + building.maximum,
    min(ChunkData.height - 1, site.floor + building.height + max(building.solar ? 7:5, building.roofRise)),
    site.z + lotZ * site.spacing + building.maximum) }
  public var entrance: SIMD3<Float> {
    [Float(minimum.x + maximum.x) / 2 + 0.5, Float(site.floor), Float(minimum.z) - 1.5]
  }
  public func contains(_ p: BlockPosition) -> Bool {
    let lo = minimum, hi = maximum
    return (lo.x...hi.x).contains(p.x) && (lo.y...hi.y).contains(p.y) && (lo.z...hi.z).contains(p.z)
  }
  public func original(at p: BlockPosition, terrain: TerrainGenerator) -> Block {
    guard contains(p) else { return .air }
    return site.block(at: p, terrain: terrain, building: building) ?? .air
  }
  public static func properties(in site: Settlement, terrain: TerrainGenerator) -> [Self] {
    var homes: [Self] = []
    let radius = site.radius / site.spacing + 1
    for z in -radius...radius { for x in -radius...radius {
      guard let building = site.building(lotX: x, lotZ: z, terrain: terrain) else { continue }
      let owner = homes.count % site.population
      homes.append(.init(id: building.hash, ownerID: ResidentState.id(index: owner, site: site), ownerIndex: owner,
        site: site, lotX: x, lotZ: z, building: building))
    } }
    return homes
  }
}

public struct HomeRepair: Codable, Equatable, Sendable {
  public let position: BlockPosition
  public let original: Block
  public var isValid: Bool { original.isSolid && PlantEdit(position: position, kind: nil).isValid }
}

public struct HomeRecord: Codable, Sendable {
  public let id: UInt64
  public let ownerID: UInt64
  public var incident: UUID
  public private(set) var repairs: [HomeRepair] = []
  public var stock = MaterialStock()
  public var lastDamage: Double = 0
  public var lastHelp: Double = 0
  public var completedRepairs = 0
  public init(home: OwnedHome) { id = home.id; ownerID = home.ownerID; incident = UUID() }
  public var isValid: Bool {
    repairs.count <= 8_192 && repairs.allSatisfy(\.isValid) && Set(repairs.map(\.position)).count == repairs.count
      && stock.isValid && [lastDamage, lastHelp].allSatisfy { $0.isFinite && (0..<1_000_000_000).contains($0) }
      && (0...1_000_000).contains(completedRepairs)
  }
  public mutating func damage(at position: BlockPosition, original: Block, time: Double) {
    guard original.isSolid, repairs.count < 8_192 else { return }
    if repairs.isEmpty || time - lastDamage > 90 { incident = UUID() }
    lastDamage = time
    if !repairs.contains(where: { $0.position == position }) { repairs.append(.init(position: position, original: original)) }
    repairs.sort { ($0.position.y, $0.position.z, $0.position.x) < ($1.position.y, $1.position.z, $1.position.x) }
  }
  public mutating func acknowledgeRepair(at position: BlockPosition) {
    guard repairs.contains(where: { $0.position == position }) else { return }
    repairs.removeAll { $0.position == position }
    completedRepairs = min(1_000_000, completedRepairs + 1)
  }
  public static func alternatives(for block: Block, habitat: SettlementHabitat) -> [Block] {
    if habitat == .solar { return [.basalt, .brick, .stone, .limestone].filter { $0 != block } }
    if habitat == .aquatic { return [.coral, .limestone, .stone, .glass].filter { $0 != block } }
    switch block {
    case .wood, .birchWood, .spruceWood: return [.wood, .birchWood, .spruceWood].filter { $0 != block }
    case .leaves, .spruceLeaves, .cherryLeaves, .mapleLeaves, .willowLeaves:
      return [.leaves, .spruceLeaves, .willowLeaves].filter { $0 != block }
    case .glass: return [.glass, .wood, .stone].filter { $0 != block }
    default: return [.stone, .limestone, .brick, .wood].filter { $0 != block }
    }
  }
}

public enum ResidentJobKind: String, Codable, Sendable { case warn, confront, requestHelp, acceptHelp, declineHelp, gather, deliver, craft, repair, retreat }
public struct ResidentJob: Equatable, Sendable {
  public let kind: ResidentJobKind
  public let homeID: UInt64
  public let target: BlockPosition
  public let material: Block?
  public let recipe: VillageRecipe?
  public init(_ kind: ResidentJobKind, home: UInt64, target: BlockPosition, material: Block? = nil, recipe: VillageRecipe? = nil) {
    self.kind = kind; homeID = home; self.target = target; self.material = material; self.recipe = recipe
  }
}

public enum HomeDefense {
  public static func strength(of resident: ResidentState) -> Float {
    let base: Float = resident.role == .guard ? 0.95 : resident.role == .builder ? 0.7 : 0.35
    return (base + Float(resident.id % 10) * 0.015) * (1 - resident.record.fatigue * 0.45)
  }
  public static func canIntervene(resident: ResidentState, allies: [ResidentState], player: SIMD3<Float>, flying: Bool, driving: Bool) -> Bool {
    guard !flying, !driving, abs(player.y - resident.position.y) < 4 else { return false }
    let help = allies.filter { $0.id != resident.id && abs($0.position.y - resident.position.y) < 4
      && distanceSquared($0.position, resident.position) < 12 * 12 }.reduce(Float(0)) { $0 + strength(of: $1) * 0.45 }
    return strength(of: resident) + help >= 0.75
  }
  public static func willingToHelp(_ helper: ResidentState, requester: UInt64) -> Bool {
    let relationship = helper.record.relationships.first { $0.otherID == requester }
    return helper.role == .guard || helper.role == .builder
      || (relationship.map { $0.trust >= 0.5 && $0.affinity >= 0.15 } ?? false)
  }
  private static func distanceSquared(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let d = a - b; return d.x * d.x + d.y * d.y + d.z * d.z
  }
}
