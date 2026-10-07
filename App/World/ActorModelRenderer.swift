import Metal
import RealityKit
import UIKit
import WorldCore

/// Articulated up close; the identical sculpture is baked into one draw at range.
/// Switching changes neither colors nor silhouette, and hysteresis prevents flicker.
@MainActor final class ActorRig {
  let root = Entity()
  let detailed = Entity()
  let distant: Entity?
  let joints: [ActorJoint: Entity]
  let height: Float
  private var isDistant = false
  subscript(_ joint: ActorJoint) -> Entity { joints[joint]! }

  init(_ prepared: PreparedActorGeometry, library: ActorModelLibrary) {
    let sculpture = prepared.sculpture
    height = sculpture.bounds.maximum.y
    var nodes: [ActorJoint: Entity] = [:]
    for joint in ActorJoint.allCases { let node = Entity(); node.name = joint.rawValue; nodes[joint] = node }
    joints = nodes
    let material = library.material(sculpture.colors)
    for (index, part) in sculpture.parts.enumerated() {
      let node = nodes[part.joint]!
      node.position = part.pivot
      if !part.boxes.isEmpty { library.attach(part, prepared: prepared.parts[index], material: material, colors: sculpture.colors, to: node) }
    }
    for joint in ActorJoint.allCases {
      (joint.parent.flatMap { nodes[$0] } ?? detailed).addChild(nodes[joint]!)
    }
    root.name = sculpture.name
    root.scale = .init(repeating: WorldScale.blocks(1))
    root.addChild(detailed)
    if let mesh = library.combined(sculpture, prepared: prepared.combined) {
      let model = ModelEntity(mesh: mesh, materials: [material])
      model.name = "Distant sculpture"; model.isEnabled = false
      root.addChild(model); distant = model
    } else { distant = nil }
  }
  @discardableResult func updateDetail(distanceSquared: Float) -> Bool {
    let far = distant != nil && distanceSquared > (isDistant ? 44 * 44 : 52 * 52)
    if far != isDistant {
      isDistant = far; detailed.isEnabled = !far; distant?.isEnabled = far
    }
    return !far
  }
  func face(time: Double, id: UInt64, asleep: Bool, talking: Bool) {
    let phase = Float((time + Double(id % 997) * 0.037).truncatingRemainder(dividingBy: 4.7))
    self[.eyes].scale.y = asleep ? 0.12 : phase < 0.12 ? 0.15 : 1
    self[.mouth].scale.y = talking ? 1.2 + abs(sin(Float(time.truncatingRemainder(dividingBy: 100)) * 11)) * 1.8 : 1
  }
}

/// Bounded caches share immutable GPU resources even when every resident wears
/// different colors. Evicted resources remain alive in their visible entities.
@MainActor final class ActorModelLibrary {
  static let shared = ActorModelLibrary()
  private var meshes: [[ActorBox]: MeshResource] = [:]
  private var meshOrder: [[ActorBox]] = []
  private var combinedMeshes: [String: MeshResource] = [:]
  private var combinedOrder: [String] = []
  private var materials: [[SIMD3<Float>]: PhysicallyBasedMaterial] = [:]
  private var materialOrder: [[SIMD3<Float>]] = []
  private var prepared: [ActorRecipe: PreparedActorGeometry] = [:]
  private var preparedOrder: [ActorRecipe] = []
  private var preparation: Task<Void, Never>?
  private var uploadsRemaining = 1
  func beginFrame() { uploadsRemaining = 1 }
  private var reportedFailure = false

  /// A cache miss schedules at most one CPU job. Callers keep rendering their
  /// current scene and retry on a later frame; no semaphore or actor wait here.
  func geometry(for recipe: ActorRecipe) -> PreparedActorGeometry? {
    if let cached = prepared[recipe] {
      guard uploadsRemaining > 0 else { return nil }
      uploadsRemaining -= 1; return cached
    }
    if preparation == nil {
      preparation = Task { [weak self] in
        let geometry = await ActorMeshPreparation.shared.prepare(recipe)
        guard let self else { return }
        if self.preparedOrder.count >= 64 { self.prepared.removeValue(forKey: self.preparedOrder.removeFirst()) }
        self.prepared[recipe] = geometry; self.preparedOrder.append(recipe)
        self.preparation = nil
      }
    }
    return nil
  }
  private static let cube = MeshResource.generateBox(size: 1)

  func attach(_ part: ActorPart, prepared: PackedTerrainMesh, material: PhysicallyBasedMaterial, colors: [SIMD3<Float>], to node: Entity) {
    if let mesh = meshes[part.boxes] { node.addChild(ModelEntity(mesh: mesh, materials: [material])); return }
    do {
      let mesh = try TerrainMeshResource.make(prepared)
      if meshOrder.count >= 384 { meshes.removeValue(forKey: meshOrder.removeFirst()) }
      meshes[part.boxes] = mesh; meshOrder.append(part.boxes)
      node.addChild(ModelEntity(mesh: mesh, materials: [material]))
    } catch {
      report(error)
      // Preserve a visible, correctly colored actor if RealityKit rejects a mesh.
      for box in part.boxes {
        let rgb = colors[box.color]
        let model = ModelEntity(mesh: Self.cube, materials: [SimpleMaterial(color: UIColor(
          red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1), roughness: 0.9, isMetallic: false)])
        model.scale = box.size; model.position = box.center; node.addChild(model)
      }
    }
  }
  func combined(_ sculpture: ActorSculpture, prepared: PackedTerrainMesh) -> MeshResource? {
    if let mesh = combinedMeshes[sculpture.geometryKey] { return mesh }
    do {
      let mesh = try TerrainMeshResource.make(prepared)
      if combinedOrder.count >= 64 { combinedMeshes.removeValue(forKey: combinedOrder.removeFirst()) }
      combinedMeshes[sculpture.geometryKey] = mesh; combinedOrder.append(sculpture.geometryKey)
      return mesh
    } catch { report(error); return nil }
  }
  func material(_ colors: [SIMD3<Float>]) -> PhysicallyBasedMaterial {
    if let material = materials[colors] { return material }
    var material = PhysicallyBasedMaterial()
    material.roughness = .init(floatLiteral: 0.88)
    material.specular = .init(floatLiteral: 0.2)
    do {
      let width = ActorPalette.width
      guard let provider = CGDataProvider(data: Data(ActorPalette.pixels(colors)) as CFData),
        let image = CGImage(width: width, height: width, bitsPerComponent: 8, bitsPerPixel: 32,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
          decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw CocoaError(.fileReadCorruptFile) }
      let texture = try TextureResource(image: image, options: .init(semantic: .color))
      let sampler = MTLSamplerDescriptor()
      sampler.minFilter = .nearest; sampler.magFilter = .nearest; sampler.mipFilter = .linear
      sampler.lodMaxClamp = 1; sampler.maxAnisotropy = 1
      material.baseColor = .init(tint: .white, texture: .init(texture, sampler: .init(sampler)))
    } catch { report(error); material.baseColor = .init(tint: .white) }
    if materialOrder.count >= 128 { materials.removeValue(forKey: materialOrder.removeFirst()) }
    materials[colors] = material; materialOrder.append(colors)
    return material
  }
  private func report(_ error: Error) {
    guard !reportedFailure else { return }
    reportedFailure = true
    print("WORLDCRAFT_ACTOR model resource fallback: \(error)")
  }
}
