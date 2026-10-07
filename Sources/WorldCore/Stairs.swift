import Foundation

/// Stair direction names the high side. Two quarter-metre risers fill a block;
/// collision, meshing and ray selection share these exact boxes.
extension Block {
  public var isStair: Bool { stairDirection != nil }
  public var stairDirection: Int? {
    switch self {
    case .woodStairsEast, .stoneStairsEast: 0
    case .woodStairsWest, .stoneStairsWest: 1
    case .woodStairsSouth, .stoneStairsSouth: 2
    case .woodStairsNorth, .stoneStairsNorth: 3
    default: nil
    }
  }
  public var stairMaterial: Block {
    switch self {
    case .stoneStairsEast, .stoneStairsWest, .stoneStairsSouth, .stoneStairsNorth: .stone
    default: .wood
    }
  }
  public func facing(_ direction: SIMD3<Float>) -> Block {
    guard isStair else { return self }
    let variants: [Block] = stairMaterial == .stone
      ? [.stoneStairsEast,.stoneStairsWest,.stoneStairsSouth,.stoneStairsNorth]
      : [.woodStairsEast,.woodStairsWest,.woodStairsSouth,.woodStairsNorth]
    return variants[abs(direction.x) > abs(direction.z) ? (direction.x > 0 ? 0:1) : (direction.z > 0 ? 2:3)]
  }
  public var collisionBoxes: [RocketBox] {
    guard let direction = stairDirection else { return [.init([1,1,1],[0.5,0.5,0.5])] }
    let upper: RocketBox
    switch direction {
    case 0: upper = .init([0.5,0.5,1],[0.75,0.75,0.5])
    case 1: upper = .init([0.5,0.5,1],[0.25,0.75,0.5])
    case 2: upper = .init([1,0.5,0.5],[0.5,0.75,0.75])
    default: upper = .init([1,0.5,0.5],[0.5,0.75,0.25])
    }
    return [.init([1,0.5,1],[0.5,0.25,0.5]),upper]
  }
}

extension BuildingDescriptor {
  /// Only floors with a full standing-height room count as destinations.
  public var floorCount: Int { max(1,(height-5)/storey+1) }
  public var hasStairs: Bool { !aquatic && floorCount > 1 && maximum-minimum >= storey+6 }
  public var hasElevator: Bool { !aquatic && floorCount >= 4 && maximum-minimum >= 22 }
  public var stairStartX: Int { minimum+3 }
  public var stairZ: ClosedRange<Int> { (maximum-5)...(maximum-3) }
  /// Nil outside the reserved circulation zone. A flight repeats in the same
  /// direction on each floor, leaving a landing at both ends and a real void
  /// above the high half of the previous flight.
  func circulationBlock(x: Int, y: Int, z: Int) -> Block? {
    if hasStairs && stairZ.contains(z) && (stairStartX-2...stairStartX+storey+2).contains(x) {
      let step = x-stairStartX
      let level = y/storey, localY = y%storey
      let material: Block = solar ? .stoneStairsEast : .woodStairsEast
      if (0..<storey).contains(step) {
        if y > 0 && localY == 0 && step == storey-1 && level < floorCount { return material }
        if level < floorCount-1 && localY == step+1 { return material }
        if localY == 0 && (level == 0 || step < storey-7) { return solar ? .basalt:.wood }
        return .air
      }
      return localY == 0 ? (solar ? .basalt:.wood) : .air
    }
    if hasElevator {
      let lowX=minimum+3, highX=minimum+9, lowZ=minimum+6, highZ=minimum+12
      if (lowX...highX).contains(x) && (lowZ...highZ).contains(z) {
        if y == 0 { return .stone }
        let edge = x == lowX || x == highX || z == lowZ || z == highZ
        if !edge { return .air }
        if z == lowZ && (lowX+2...highX-2).contains(x) && (1...5).contains(y%storey) { return .air }
        return (2...5).contains(y%storey) ? .glass : .stone
      }
    }
    return nil
  }
}
