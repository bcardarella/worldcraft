import Foundation

public enum AnimalFood: String, Codable, Sendable {
  case grass, leaves, flowers, berries, seeds, bamboo, aquatic
}

public enum InventoryItem: Hashable, Codable, Sendable {
  case block(Block)
  case plant(PlantKind)
  case baseball

  public var isValid: Bool {
    if case .block(let block) = self { return block.isSolid }
    return true
  }
  public var name: String {
    switch self {
    case .baseball: "Baseball"
    case .block(let block): block == .grass ? "Grass block" : block.name
    case .plant(let plant): plant.name
    }
  }
  /// Seconds of continuous bare-hand work. Liquids are never collectible blocks.
  public var breakingEffort: Float {
    switch self {
    case .baseball: 0.1
    case .block(let block): block.breakingEffort ?? .infinity
    case .plant(let kind): kind == .bamboo || kind == .coral ? 0.65 : kind == .berryBush ? 0.4 : 0.18
    }
  }
  public var food: AnimalFood? {
    switch self {
    case .baseball: nil
    case .block(let block):
      [.leaves, .cherryLeaves, .mapleLeaves, .willowLeaves].contains(block) ? .leaves : nil
    case .plant(let kind):
      switch kind {
      case .grass, .dryGrass, .clover, .reed: .grass
      case .fern, .broadleaf: .leaves
      case .daisy, .goldenFlower, .bluebell, .orchid: .flowers
      case .berryBush: .berries
      case .sunflower: .seeds
      case .bamboo: .bamboo
      case .kelp, .seagrass: .aquatic
      default: nil
      }
    }
  }
}

extension Block {
  public var breakingEffort: Float? {
    return switch self {
    case .woodStairsEast, .woodStairsWest, .woodStairsSouth, .woodStairsNorth, .stoneStairsEast, .stoneStairsWest, .stoneStairsSouth, .stoneStairsNorth: self.stairMaterial == .stone ? 3.2 : 1.8
    case .air, .water, .lava: nil
    case .leaves, .cherryLeaves, .mapleLeaves, .spruceLeaves, .willowLeaves: 0.35
    case .snow: 0.35
    case .glass, .lamp, .torch, .lantern: 0.55
    case .dirt, .sand: 0.65
    case .grass: 0.8
    case .wood, .birchWood, .spruceWood: 1.8
    case .coral: 1.4
    case .limestone: 2.2
    case .brick: 2.8
    case .stone: 3.2
    case .basalt: 4.5
    }
  }
}

public struct ItemStack: Codable, Equatable, Sendable {
  public var item: InventoryItem
  public var count: Int
  public init(_ item: InventoryItem, count: Int = 1) { self.item = item; self.count = count }
  public var isValid: Bool { item.isValid && (1...Inventory.stackLimit).contains(count) }
}

public struct Inventory: Codable, Equatable, Sendable {
  public static let hotbarCount = 9
  public static let slotCount = 36
  public static let stackLimit = 64
  public private(set) var slots: [ItemStack?]
  public init() { slots = .init(repeating: nil, count: Self.slotCount) }
  public var isValid: Bool { slots.count == Self.slotCount && slots.allSatisfy { $0?.isValid ?? true } }
  public subscript(_ index: Int) -> ItemStack? { slots.indices.contains(index) ? slots[index] : nil }
  public var occupiedSlots: Int { slots.compactMap { $0 }.count }
  public func capacity(for item: InventoryItem) -> Int {
    guard item.isValid else { return 0 }
    return slots.reduce(0) { $0 + ($1.map { $0.item == item ? Self.stackLimit - $0.count : 0 } ?? Self.stackLimit) }
  }
  /// Returns the uncollected remainder. Matching stacks fill before empty slots.
  @discardableResult public mutating func collect(_ item: InventoryItem, count: Int = 1) -> Int {
    guard item.isValid, count > 0 else { return max(0, count) }
    var remaining = count
    for i in slots.indices where slots[i]?.item == item {
      let amount = min(remaining, Self.stackLimit - slots[i]!.count)
      slots[i]!.count += amount; remaining -= amount
      if remaining == 0 { return 0 }
    }
    for i in slots.indices where slots[i] == nil {
      let amount = min(remaining, Self.stackLimit)
      slots[i] = .init(item, count: amount); remaining -= amount
      if remaining == 0 { return 0 }
    }
    return remaining
  }
  @discardableResult public mutating func consume(slot: Int, count: Int = 1) -> Bool {
    guard slots.indices.contains(slot), count > 0, let stack = slots[slot], stack.count >= count else { return false }
    slots[slot] = stack.count == count ? nil : .init(stack.item, count: stack.count - count)
    return true
  }
  /// Merge equal stacks or swap distinct ones; no detached cursor stack can be
  /// lost if the inventory closes or the app saves midway through rearranging.
  public mutating func move(from source: Int, to destination: Int) {
    guard slots.indices.contains(source), slots.indices.contains(destination), source != destination,
      var moving = slots[source] else { return }
    if var target = slots[destination], target.item == moving.item {
      let amount = min(moving.count, Self.stackLimit - target.count)
      target.count += amount; moving.count -= amount
      slots[destination] = target; slots[source] = moving.count > 0 ? moving : nil
    } else { slots.swapAt(source, destination) }
  }
}

public struct MiningTarget: Equatable, Sendable {
  public let position: BlockPosition
  public let item: InventoryItem
  public init(position: BlockPosition, item: InventoryItem) { self.position = position; self.item = item }
}

public struct MiningProgress: Sendable {
  public private(set) var target: MiningTarget?
  public private(set) var work: Float = 0
  public init() {}
  public var fraction: Float { target.map { min(1, work / $0.item.breakingEffort) } ?? 0 }
  public mutating func reset() { target = nil; work = 0 }
  @discardableResult public mutating func update(target next: MiningTarget?, held: Bool, seconds: Float,
    workRate: Float = 1) -> Bool {
    guard held, let next, next.item.isValid, next.position.y > ChunkData.minimumY,
      seconds.isFinite, seconds > 0, workRate.isFinite, workRate > 0 else { reset(); return false }
    if next != target { target = next; work = 0 }
    work += min(0.05, seconds) * min(20, workRate)
    return work >= next.item.breakingEffort
  }
}

public struct DroppedItem: Codable, Equatable, Sendable {
  public let id: UUID
  public var stack: ItemStack
  public var position: SIMD3<Float>
  public var velocity: SIMD3<Float>
  public var pickupDelay: Float
  public init(stack: ItemStack, position: SIMD3<Float>, pickupDelay: Float = 0.35) {
    id = UUID(); self.stack = stack; self.position = position
    velocity = [0, 2.5, 0]; self.pickupDelay = pickupDelay
  }
  public var isValid: Bool {
    stack.isValid && (0..<3).allSatisfy { position[$0].isFinite && abs(position[$0]) < 100_000_000
      && velocity[$0].isFinite && abs(velocity[$0]) <= 40 }
      && pickupDelay.isFinite && (0...2).contains(pickupDelay)
  }
  public mutating func update(seconds: Float, current: SIMD3<Float> = .zero, block: (BlockPosition) -> Block) {
    let dt = min(0.05, max(0, seconds))
    pickupDelay = max(0, pickupDelay - dt)
    let fluid = block(BlockPosition(position)).isLiquid
    velocity.y = max(-20, velocity.y + (fluid ? 3 : -15) * dt)
    if fluid { velocity.y = min(1, velocity.y); velocity *= max(0, 1 - dt * 2) }
    if fluid { position = FluidMotion.advected(position,current:current,seconds:dt,block:block) }
    let next = position + velocity * dt
    if block(BlockPosition(next - [0, 0.2, 0])).isSolid {
      velocity = .zero
    } else { position = next }
  }
}
