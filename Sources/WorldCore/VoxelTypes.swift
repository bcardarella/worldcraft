import Foundation

public enum Block: UInt8, CaseIterable, Codable, Sendable {
  case air, grass, dirt, stone, sand, wood, leaves, water, brick, glass, snow, lamp
  case birchWood, spruceWood, cherryLeaves, mapleLeaves, spruceLeaves, willowLeaves
  case lava
  case basalt, coral, limestone
  case torch
  case woodStairsEast, woodStairsWest, woodStairsSouth, woodStairsNorth
  case stoneStairsEast, stoneStairsWest, stoneStairsSouth, stoneStairsNorth

  case lantern

  public static let palette: [Block] = [.grass, .stone, .wood, .sand, .brick, .glass, .leaves]
  public var isLiquid: Bool { self == .water || self == .lava }
  public var isSolid: Bool { self != .air && !isLiquid }
  public var isOpaque: Bool { isSolid && self != .glass && self != .torch && self != .lantern && !isStair }
  public var isFoliage: Bool {
    switch self {
    case .leaves, .cherryLeaves, .mapleLeaves, .spruceLeaves, .willowLeaves: true
    default: false
    }
  }
  public var name: String {
    switch self {
    case .air: "Air"
    case .grass: "Grass"
    case .dirt: "Earth"
    case .stone: "Stone"
    case .sand: "Sand"
    case .wood: "Timber"
    case .leaves: "Leaves"
    case .water: "Water"
    case .brick: "Brick"
    case .glass: "Glass"
    case .snow: "Snow"
    case .lamp: "Lantern"
    case .torch: "Torch"
    case .lantern: "Light fixture"
    case .woodStairsEast, .woodStairsWest, .woodStairsSouth, .woodStairsNorth: "Timber stairs"
    case .stoneStairsEast, .stoneStairsWest, .stoneStairsSouth, .stoneStairsNorth: "Stone stairs"
    case .birchWood: "Birch timber"
    case .spruceWood: "Spruce timber"
    case .cherryLeaves: "Cherry blossoms"
    case .mapleLeaves: "Maple leaves"
    case .spruceLeaves: "Spruce needles"
    case .willowLeaves: "Willow leaves"
    case .basalt: "Basalt"
    case .coral: "Coral stone"
    case .limestone: "Limestone"
    case .lava: "Lava"
    }
  }
  public func tile(face: Int) -> Int {
    switch self {
    case .grass: face == 2 ? 0 : (face == 3 ? 2 : 1)
    case .dirt: 2
    case .stone: 3
    case .sand: 4
    case .wood: (face == 2 || face == 3) ? 6 : 5
    case .leaves: 7
    case .water: 8
    case .brick: 9
    case .glass: 10
    case .snow: 11
    case .lamp, .torch, .lantern: 14
    case .birchWood: (face == 2 || face == 3) ? 17 : 16
    case .spruceWood: (face == 2 || face == 3) ? 19 : 18
    case .cherryLeaves: 20
    case .mapleLeaves: 21
    case .spruceLeaves: 22
    case .willowLeaves: 23
    case .basalt: 12
    case .coral: 13
    case .limestone: 15
    case .lava: 28
    case .woodStairsEast, .woodStairsWest, .woodStairsSouth, .woodStairsNorth: 5
    case .stoneStairsEast, .stoneStairsWest, .stoneStairsSouth, .stoneStairsNorth: 3
    case .air: 2
    }
  }
}

public struct BlockPosition: Hashable, Codable, Sendable {
  public var x: Int
  public var y: Int
  public var z: Int
  public init(_ x: Int, _ y: Int, _ z: Int) {
    self.x = x
    self.y = y
    self.z = z
  }
  public init(_ point: SIMD3<Float>) {
    self.init(Int(floor(point.x)), Int(floor(point.y)), Int(floor(point.z)))
  }
  public var center: SIMD3<Float> { [Float(x) + 0.5, Float(y) + 0.5, Float(z) + 0.5] }
  public var chunk: ChunkCoordinate { .init(floorDivide(x, by: 16), floorDivide(z, by: 16)) }
  public static func + (lhs: Self, rhs: Self) -> Self {
    .init(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
  }
}

public struct ChunkCoordinate: Hashable, Codable, Sendable {
  public var x: Int
  public var z: Int
  public init(_ x: Int, _ z: Int) {
    self.x = x
    self.z = z
  }
  public var origin: SIMD3<Float> { [Float(x * 16), 0, Float(z * 16)] }
  public func distanceSquared(to other: Self) -> Int {
    (x - other.x) * (x - other.x) + (z - other.z) * (z - other.z)
  }
}

public func floorDivide(_ value: Int, by divisor: Int) -> Int {
  let quotient = value / divisor
  return value < 0 && value % divisor != 0 ? quotient - 1 : quotient
}

public struct ChunkData: Sendable {
  public static let minimumY = -64
  public static let height = 128
  public let coordinate: ChunkCoordinate
  public private(set) var maximumFilledY = minimumY - 1
  // A one-block border ensures faces agree across chunk seams.
  private var cells: [UInt8]
  public init(coordinate: ChunkCoordinate) {
    self.coordinate = coordinate
    cells = .init(repeating: 0, count: 18 * 18 * (Self.height - Self.minimumY))
  }
  var archiveCells: [UInt8] { cells }
  init?(coordinate: ChunkCoordinate, archiveCells: [UInt8], maximumFilledY: Int) {
    guard archiveCells.count == 18 * 18 * (Self.height - Self.minimumY),
      (Self.minimumY - 1..<Self.height).contains(maximumFilledY),
      archiveCells.allSatisfy({ Block(rawValue: $0) != nil }) else { return nil }
    // The maximum can conservatively exceed the highest occupied cell after an
    // edit, but must never omit cells from collision/meshing traversal.
    if let last = archiveCells.lastIndex(where: { $0 != Block.air.rawValue }),
      Self.minimumY + last / (18 * 18) > maximumFilledY { return nil }
    self.coordinate = coordinate; cells = archiveCells; self.maximumFilledY = maximumFilledY
  }
  public subscript(_ x: Int, _ y: Int, _ z: Int) -> Block {
    get {
      guard (-1...16).contains(x), (Self.minimumY..<Self.height).contains(y), (-1...16).contains(z)
      else {
        return .air
      }
      return Block(rawValue: cells[((y - Self.minimumY) * 18 + z + 1) * 18 + x + 1]) ?? .air
    }
    set {
      guard (-1...16).contains(x), (Self.minimumY..<Self.height).contains(y), (-1...16).contains(z)
      else {
        return
      }
      cells[((y - Self.minimumY) * 18 + z + 1) * 18 + x + 1] = newValue.rawValue
      if newValue != .air { maximumFilledY = max(maximumFilledY, y) }
    }
  }
}
