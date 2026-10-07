import RealityKit
import UIKit
import WorldCore

/// Controller-driven voxel arms, with a held block and break/place animation.
@MainActor
final class PlayerHands {
  let root = Entity()
  private let left = Entity(), right = Entity(), held = Entity()
  private var meshes: [InventoryItem: MeshResource] = [:]
  private var selected: InventoryItem?
  private var swing: Float = 0
  private var bob: Float = 0

  func configure(parent: Entity, lighting: Entity) {
    root.removeFromParent()
    root.children.removeAll()
    left.children.removeAll()
    right.children.removeAll()
    held.children.removeAll()
    selected = nil
    swing = 0
    bob = 0
    let sleeve = SimpleMaterial(
      color: UIColor(red: 0.08, green: 0.53, blue: 0.57, alpha: 1), roughness: 0.9,
      isMetallic: false)
    let skin = SimpleMaterial(
      color: UIColor(red: 0.75, green: 0.47, blue: 0.29, alpha: 1), roughness: 0.85,
      isMetallic: false)
    let highlight = SimpleMaterial(
      color: UIColor(red: 0.88, green: 0.64, blue: 0.43, alpha: 1), roughness: 0.85,
      isMetallic: false)
    let builder = SculptureBuilder(materials: [sleeve, skin, highlight])
    for arm in [left, right] {
      builder.box([0.085, 0.09, 0.23], [0, -0.005, 0.09], 0, parent: arm)
      builder.box([0.09, 0.095, 0.105], [0, 0, -0.07], 1, parent: arm)
      for x: Float in [-0.03, 0, 0.03] {
        builder.box([0.022, 0.01, 0.025], [x, 0.049, -0.09], 2, parent: arm)
      }
      root.addChild(arm)
    }
    builder.finish()
    left.orientation = simd_quatf(angle: -0.10, axis: [1, 0, 0])
    held.position = [-0.012, 0.072, -0.13]
    held.scale = .init(repeating: 0.14)
    right.addChild(held)
    root.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lighting))
    parent.addChild(root)
  }

  func select(_ item: InventoryItem?, materials: [any Material]) throws {
    guard item != selected else { return }
    guard let item else { held.children.removeAll(); selected = nil; return }
    if meshes[item] == nil {
      let source = InventoryGeometry.mesh(for: item)
      var descriptor = MeshDescriptor(name: "Held \(item.name)")
      descriptor.positions = .init(source.positions)
      descriptor.normals = .init(source.normals)
      descriptor.textureCoordinates = .init(source.textureCoordinates)
      descriptor.primitives = .triangles(source.indices)
      descriptor.materials = .perFace(source.materials)
      meshes[item] = try MeshResource.generate(from: [descriptor])
    }
    held.children.removeAll()
    if let mesh = meshes[item] { held.addChild(ModelEntity(mesh: mesh, materials: materials)) }
    selected = item
  }
  func animateAction() { swing = 1 }
  func update(deltaTime: Float, movement: Float, visible: Bool) {
    if root.isEnabled != visible { root.isEnabled = visible }
    guard visible else { return }
    bob += deltaTime * movement * 9
    swing = max(0, swing - deltaTime * 4.5)
    let pulse = sin(swing * .pi)
    left.position = [-0.26, -0.29 + sin(bob) * movement * 0.009, -0.48]
    right.position = [
      0.27 - pulse * 0.075, -0.29 + sin(bob + .pi) * movement * 0.009 + pulse * 0.06,
      -0.48 - pulse * 0.085,
    ]
    right.orientation = simd_quatf(angle: -0.10 - pulse * 0.6, axis: [1, 0, 0])
  }
  func clear() {
    root.removeFromParent()
    root.children.removeAll()
    selected = nil
  }
}
