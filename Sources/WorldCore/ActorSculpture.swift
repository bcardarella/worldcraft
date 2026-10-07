import Foundation

public enum ActorJoint: String, CaseIterable, Codable, Sendable {
  case body, head, eyes, mouth, limb0, limb1, limb2, limb3, tail, prop
  public var parent: Self? {
    switch self { case .eyes, .mouth: .head; case .prop: .limb1; default: nil }
  }
}

public struct ActorBox: Hashable, Codable, Sendable {
  public let size: SIMD3<Float>
  public let center: SIMD3<Float>
  public let color: Int
  public init(_ size: SIMD3<Float>, _ center: SIMD3<Float>, _ color: Int) {
    self.size = size; self.center = center; self.color = color
  }
}

public struct ActorPart: Codable, Sendable {
  public let joint: ActorJoint
  public var pivot: SIMD3<Float>
  public var boxes: [ActorBox]
  public init(_ joint: ActorJoint, at pivot: SIMD3<Float> = .zero, boxes: [ActorBox] = []) {
    self.joint = joint; self.pivot = pivot; self.boxes = boxes
  }
  public mutating func box(_ size: SIMD3<Float>, _ center: SIMD3<Float>, _ color: Int) {
    boxes.append(.init(size, center, color))
  }
}

/// Geometry is in metres. Palettes are independent of shape, so many coats and
/// outfits share the same mesh. Every joint uses ONE material, regardless of colors.
public struct ActorSculpture: Codable, Sendable {
  public let name: String
  public let geometryKey: String
  public var colors: [SIMD3<Float>]
  public var parts: [ActorPart]
  public init(name: String, key: String, colors: [SIMD3<Float>], parts: [ActorPart]) {
    self.name = name; geometryKey = key; self.colors = colors; self.parts = parts
  }
  public func worldPivot(_ joint: ActorJoint) -> SIMD3<Float> {
    let local = parts.first { $0.joint == joint }?.pivot ?? .zero
    return local + (joint.parent.map(worldPivot) ?? .zero)
  }
  public func mesh(for part: ActorPart) -> VoxelMesh {
    var mesh = VoxelMesh()
    for box in part.boxes { mesh.appendBox(size: box.size, center: box.center, material: UInt32(box.color)) }
    return ActorPalette.textured(mesh)
  }
  /// Same silhouette/markings at distance, with joints baked into a single draw.
  public func combinedMesh() -> VoxelMesh {
    var result = VoxelMesh()
    for part in parts {
      var mesh = mesh(for: part)
      let pivot = worldPivot(part.joint)
      mesh.positions = mesh.positions.map { $0 + pivot }
      result.append(mesh)
    }
    return result
  }
  public var bounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
    var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
    for part in parts {
      let pivot = worldPivot(part.joint)
      for box in part.boxes { for axis in 0..<3 {
        low[axis] = min(low[axis], pivot[axis] + box.center[axis] - box.size[axis] / 2)
        high[axis] = max(high[axis], pivot[axis] + box.center[axis] + box.size[axis] / 2)
      } }
    }
    return (low, high)
  }
}

public enum ActorPalette {
  public static let width = 64
  public static let capacity = 16
  /// A tiny padded 4×4 palette with subtle woven/fur grain. Face UVs use each
  /// tile's interior; nearest filtering and bounded mip levels prevent bleeding.
  public static func pixels(_ colors: [SIMD3<Float>]) -> [UInt8] {
    var result = [UInt8](repeating: 255, count: width * width * 4)
    for y in 0..<width { for x in 0..<width {
      let slot = (y / 16) * 4 + x / 16
      let rgb = slot < colors.count ? colors[slot] : .zero
      let u = max(2, min(13, x % 16)), v = max(2, min(13, y % 16))
      let variation = Float((u * 13 + v * 7 + slot * 3) % 7 - 3) * 0.008
      for c in 0..<3 { result[(y * width + x) * 4 + c] = UInt8(max(0, min(255, ((rgb[c] + variation) * 255).rounded()))) }
    } }
    return result
  }
  public static func textured(_ source: VoxelMesh) -> VoxelMesh {
    var mesh = source
    for face in 0..<mesh.faceCount {
      let slot = Int(source.materials[face * 2]) % capacity
      let u = Float(slot % 4) / 4, v = 1 - Float(slot / 4) / 4
      let inset: Float = 2.5 / Float(width)
      let uv: [SIMD2<Float>] = [[u + inset, v - 0.25 + inset], [u + inset, v - inset],
        [u + 0.25 - inset, v - inset], [u + 0.25 - inset, v - 0.25 + inset]]
      for corner in 0..<4 { mesh.textureCoordinates[face * 4 + corner] = uv[corner] }
    }
    mesh.materials = Array(repeating: 0, count: mesh.materials.count)
    return mesh
  }
}

/// SplitMix64 decouples visual traits from role, species selection and each other.
public struct AppearanceRandom: Sendable {
  private var state: UInt64
  public init(_ seed: UInt64) { state = seed }
  public mutating func pick(_ count: Int) -> Int {
    precondition(count > 0)
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return Int((value ^ (value >> 31)) % UInt64(count))
  }
}
