import Foundation

public enum TreeSpecies: Int, CaseIterable, Sendable {
  case oak, birch, spruce, maple, cherry, willow, palm, acacia, redwood
}
public struct TreeDescriptor: Sendable, Equatable {
  public let species: TreeSpecies
  public let x: Int
  public let z: Int
  public let ground: Int
  public let height: Int
  public var top: Int { ground + height }
  public var trunk: Block {
    switch species {
    case .birch: .birchWood
    case .spruce, .redwood: .spruceWood
    default: .wood
    }
  }
  public var leaves: Block {
    switch species {
    case .spruce, .redwood: .spruceLeaves
    case .palm, .acacia: .willowLeaves
    case .maple: .mapleLeaves
    case .cherry: .cherryLeaves
    case .willow: .willowLeaves
    default: .leaves
    }
  }
  public func block(at p: BlockPosition) -> Block? {
    let dx = abs(p.x - x)
    let dz = abs(p.z - z)
    if dx == 0 && dz == 0 && p.y > ground && p.y <= top { return trunk }
    if species == .palm {
      guard (top - 2...top + 1).contains(p.y), max(dx, dz) <= 4 else { return nil }
      let frond = min(dx, dz) <= 1 && p.y == top + 1 - max(dx, dz) / 2
      return frond ? leaves : nil
    }
    if species == .acacia {
      guard (top...top + 2).contains(p.y), dx <= 4, dz <= 3 else { return nil }
      return p.y == top + 2 && dx + dz > 4 ? nil : leaves
    }
    if species == .redwood && p.y >= ground + 7 && p.y <= top + 2 {
      let r = p.y > top ? 1 : (p.y > top - 5 ? 2 : 3)
      return dx <= r && dz <= r && dx + dz <= r * 2 - 1 ? leaves : nil
    }
    if species == .spruce {
      guard (ground + 3...top + 2).contains(p.y) else { return nil }
      let r = min(3, max(0, (top + 2 - p.y) / 3))
      return dx <= r && dz <= r && dx + dz <= max(0, r * 2 - 1) ? leaves : nil
    }
    if species == .willow && (top - 4...top).contains(p.y) && max(dx, dz) >= 3 && max(dx, dz) <= 4
      && dx + dz <= 6
    {
      return (p.x + p.z) % 3 != 0 ? leaves : nil
    }
    guard (top - 1...top + 2).contains(p.y) else { return nil }
    let base = species == .birch ? 2 : (species == .willow ? 4 : 3)
    let r = p.y == top + 2 ? max(1, base - 2) : base
    return dx <= r && dz <= r && dx + dz <= r * 2 - 1 ? leaves : nil
  }
}
