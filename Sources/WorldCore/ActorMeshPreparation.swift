import Foundation

public enum ActorRecipe: Hashable, Sendable {
  case player
  case athlete(team:Int,baseball:Bool,batting:Bool)
  case animal(AnimalAppearance), dinosaur(DinosaurAppearance), resident(ResidentAppearance)
  public func sculpture() -> ActorSculpture {
    switch self {
    case .athlete(let team,let baseball,let batting): AthleteSculpture.make(team:team,baseball:baseball,batting:batting)
    case .player: PlayerSculpture.make()
    case .animal(let look): AnimalSculpture.make(look)
    case .dinosaur(let look): DinosaurSculpture.make(look)
    case .resident(let look): ResidentSculpture.make(look)
    }
  }
}
public struct PreparedActorGeometry: Sendable {
  public let sculpture: ActorSculpture
  /// Same order as sculpture.parts, including empty joints.
  public let parts: [PackedTerrainMesh]
  public let combined: PackedTerrainMesh
}

/// CPU mesh preparation has independent actor-owned caches. No Entity,
/// MeshResource or other RealityKit object crosses this boundary.
public actor ActorMeshPreparation {
  public static let shared = ActorMeshPreparation()
  private var parts: [[ActorBox]: PackedTerrainMesh] = [:]
  private var partOrder: [[ActorBox]] = []
  private var combined: [String: PackedTerrainMesh] = [:]
  private var combinedOrder: [String] = []
  public init() {}
  public func prepare(_ recipe: ActorRecipe) -> PreparedActorGeometry {
    let sculpture = recipe.sculpture()
    let meshes = sculpture.parts.map { part in
      if let mesh = parts[part.boxes] { return mesh }
      var source = VoxelMesh()
      for box in part.boxes { source.appendBox(size: box.size, center: box.center, material: UInt32(box.color)) }
      let mesh = PackedTerrainMesh(ActorPalette.textured(source))
      if partOrder.count >= 384 { parts.removeValue(forKey: partOrder.removeFirst()) }
      parts[part.boxes] = mesh; partOrder.append(part.boxes)
      return mesh
    }
    let key = sculpture.geometryKey
    let merged: PackedTerrainMesh
    if let cached = combined[key] { merged = cached }
    else {
      merged = PackedTerrainMesh(sculpture.combinedMesh())
      if combinedOrder.count >= 64 { combined.removeValue(forKey: combinedOrder.removeFirst()) }
      combined[key] = merged; combinedOrder.append(key)
    }
    return .init(sculpture: sculpture, parts: meshes, combined: merged)
  }
}
