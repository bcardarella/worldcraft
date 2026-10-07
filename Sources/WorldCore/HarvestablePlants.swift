import Foundation
import simd

extension PlantKind {
  public var name: String {
    ["Grass", "Fern", "Daisy", "Golden flower", "Lavender", "Berry bush", "Mushroom", "Reed", "Succulent", "Coral",
     "Poppy", "Sunflower", "Clover", "Bluebell", "Heather", "Bamboo", "Broadleaf", "Orchid", "Dry grass", "Aloe", "Kelp", "Seagrass"][rawValue]
  }
  public var aquatic: Bool { self == .kelp || self == .seagrass || self == .coral }
  public func canPlant(at position: BlockPosition, block: (BlockPosition) -> Block) -> Bool {
    guard position.y > ChunkData.minimumY && position.y + 2 < ChunkData.height else { return false }
    let below = block(position + .init(0, -1, 0))
    let medium: Block = aquatic ? .water : .air
    guard block(position) == medium && block(position + .init(0, 1, 0)) == medium else { return false }
    if aquatic { return [.sand, .dirt, .stone, .limestone, .coral].contains(below) }
    if self == .mushroom && [.wood, .birchWood, .spruceWood, .stone].contains(below) { return true }
    return [.grass, .dirt, .sand, .snow].contains(below)
  }
}

/// A nil kind suppresses natural generation at this root, across streaming,
/// reloads and planet travel. A kind stores a replanted specimen.
public struct PlantEdit: Codable, Equatable, Sendable {
  public let position: BlockPosition
  public let kind: PlantKind?
  public init(position: BlockPosition, kind: PlantKind?) { self.position = position; self.kind = kind }
  public var isValid: Bool {
    (-100_000_000...100_000_000).contains(position.x) && (-100_000_000...100_000_000).contains(position.z)
      && (ChunkData.minimumY..<ChunkData.height).contains(position.y)
  }
}

public struct PlantInstance: Equatable, Sendable {
  public let position: BlockPosition
  public let kind: PlantKind
  public let scale: Float
  public init(position: BlockPosition, kind: PlantKind, scale: Float = 1) {
    self.position = position; self.kind = kind; self.scale = scale
  }
  public var origin: SIMD3<Float> { [Float(position.x) + 0.5, Float(position.y), Float(position.z) + 0.5] }
  private static let bounds = SurfaceDecorationMesher.shapes.map { mesh in
    (mesh.positions.reduce(SIMD3<Float>(repeating: .infinity), simd_min),
     mesh.positions.reduce(SIMD3<Float>(repeating: -.infinity), simd_max))
  }
  public var minimum: SIMD3<Float> { origin + Self.bounds[kind.rawValue].0 * scale }
  public var maximum: SIMD3<Float> { origin + Self.bounds[kind.rawValue].1 * scale }
  public var center: SIMD3<Float> { (minimum + maximum) / 2 }
  public func overlaps(_ cell: BlockPosition) -> Bool {
    let lo = minimum, hi = maximum, corner = cell.center - SIMD3<Float>(repeating: 0.5)
    return (0..<3).allSatisfy { hi[$0] > corner[$0] + 0.001 && lo[$0] < corner[$0] + 0.999 }
  }
  public func hitDistance(origin: SIMD3<Float>, direction: SIMD3<Float>, reach: Float) -> Float? {
    let length = simd_length(direction)
    guard length > 0.0001 else { return nil }
    let ray = direction / length, lo = minimum - SIMD3<Float>(repeating: 0.08), hi = maximum + SIMD3<Float>(repeating: 0.08)
    var near: Float = 0, far = reach
    for axis in 0..<3 {
      if abs(ray[axis]) < 0.00001 {
        if origin[axis] < lo[axis] || origin[axis] > hi[axis] { return nil }
      } else {
        let a = (lo[axis] - origin[axis]) / ray[axis], b = (hi[axis] - origin[axis]) / ray[axis]
        near = max(near, min(a, b)); far = min(far, max(a, b))
        if far < near { return nil }
      }
    }
    return near <= reach ? near : nil
  }
}

public enum InventoryGeometry {
  public static func mesh(for item: InventoryItem) -> VoxelMesh {
    switch item {
    case .baseball:
      var chunk=ChunkData(coordinate:.init(0,0))
      for y in -3...3 {for z in -3...3 {for x in -3...3 where x*x+y*y+z*z<=11 {
        chunk[x+4,y+4,z+4]=abs(x)==2 && abs(z)==1 ? .brick:.limestone
      }}}
      var mesh=VoxelMesher.build(chunk)
      mesh.positions=mesh.positions.map {($0-[4.5,4.5,4.5])*0.1}
      return mesh
    case .plant(let kind): return SurfaceDecorationMesher.shapes[kind.rawValue]
    case .block(let block):
      var chunk = ChunkData(coordinate: .init(0, 0)); chunk[1, 1, 1] = block
      var mesh = VoxelMesher.build(chunk)
      mesh.positions = mesh.positions.map { $0 - [1.5, 1.5, 1.5] }
      return mesh
    }
  }
}
