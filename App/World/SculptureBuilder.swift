import RealityKit
import WorldCore

/// One mesh per moving joint, shared across every copy of a creature/person.
/// Small fixed decorations no longer require individual ModelEntity objects.
@MainActor final class SculptureBuilder {
  private struct Box: Hashable {
    let size: SIMD3<Float>
    let position: SIMD3<Float>
    let material: UInt32
  }
  private struct Part {
    let parent: Entity
    var boxes: [Box] = []
  }
  private static var meshes: [[Box]: MeshResource] = [:]
  private static let fallbackCube = MeshResource.generateBox(size: 1)
  private let materials: [any Material]
  private var parts: [ObjectIdentifier: Part] = [:]
  init(materials: [any Material]) { self.materials = materials }
  func box(_ size: SIMD3<Float>, _ position: SIMD3<Float>, _ material: UInt32, parent: Entity) {
    parts[ObjectIdentifier(parent), default: .init(parent: parent)].boxes.append(
      .init(size: size, position: position, material: material))
  }
  func finish() {
    for part in parts.values {
      if let mesh = Self.meshes[part.boxes] {
        part.parent.addChild(ModelEntity(mesh: mesh, materials: materials))
        continue
      }
      var source = VoxelMesh()
      for box in part.boxes {
        source.appendBox(size: box.size, center: box.position, material: box.material)
      }
      do {
        let mesh = try TerrainMeshResource.make(PackedTerrainMesh(source))
        Self.meshes[part.boxes] = mesh
        part.parent.addChild(ModelEntity(mesh: mesh, materials: materials))
      } catch {
        // A failed merge must not make an animal disappear.
        for box in part.boxes {
          let model = ModelEntity(
            mesh: Self.fallbackCube, materials: [materials[Int(box.material)]])
          model.scale = box.size
          model.position = box.position
          part.parent.addChild(model)
        }
      }
    }
  }
}
