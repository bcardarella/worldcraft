import Foundation
import simd

/// A short, swept camera boom. Head rotation stays native; only body/controller
/// look orbits the camera. Collision pulls in immediately and eases back out.
public struct ThirdPersonCamera: Sendable {
  public static let boom: SIMD3<Float> = [0, 1.3, 6.5]
  public static let clearance: Float = 0.28
  private var distance: Float?
  public init() {}
  public mutating func reset() { distance = nil }

  public mutating func offset(eye: SIMD3<Float>, heading: Float, pitch: Float,
    seconds: Float, block: (BlockPosition) -> Block,
    occupied: (SIMD3<Float>, Float) -> Bool = { _, _ in false }
  ) -> SIMD3<Float> {
    let rotation = simd_quatf(angle: heading, axis: [0, 1, 0])
      * simd_quatf(angle: pitch, axis: [1, 0, 0])
    let boom = rotation.act(Self.boom), length = simd_length(boom), direction = boom / length
    func blocked(_ distance: Float) -> Bool {
      let center = eye + direction * distance, radius = Self.clearance
      if occupied(center, radius) { return true }
      let low = center - SIMD3<Float>(repeating: radius)
      let high = center + SIMD3<Float>(repeating: radius)
      for x in Int(floor(low.x))...Int(floor(high.x)) {
        for y in Int(floor(low.y))...Int(floor(high.y)) {
          for z in Int(floor(low.z))...Int(floor(high.z)) {
            let position = BlockPosition(x, y, z), value = block(position)
            guard value.isSolid else { continue }
            let origin = SIMD3<Float>(Float(x), Float(y), Float(z))
            for box in value.collisionBoxes {
              let minimum = origin + box.center - box.size / 2, maximum = origin + box.center + box.size / 2
              if low.x < maximum.x && high.x > minimum.x && low.y < maximum.y
                && high.y > minimum.y && low.z < maximum.z && high.z > minimum.z { return true }
            }
          }
        }
      }
      return false
    }
    var safe: Float = 0
    // Sub-block steps cannot skip a solid wall, even during teleports or snap turns.
    for i in 1...Int(ceil(length / 0.2)) {
      let candidate = min(length, Float(i) * 0.2)
      if blocked(candidate) {
        var high = candidate
        for _ in 0..<5 {
          let middle = (safe + high) * 0.5
          if blocked(middle) { high = middle } else { safe = middle }
        }
        break
      }
      safe = candidate
    }
    let previous = distance ?? safe
    let next = safe < previous ? safe : previous + (safe - previous) * (1 - exp(-max(0, seconds) * 8))
    distance = next
    return direction * next
  }

  /// Converge the interaction ray on the camera's terrain target while keeping
  /// its origin at the character. Callers retain their ordinary reach/occlusion checks.
  public static func interactionDirection(eye: SIMD3<Float>, camera: SIMD3<Float>,
    forward: SIMD3<Float>, reach: Float = 6, block: (BlockPosition) -> Block
  ) -> SIMD3<Float> {
    let distance = simd_distance(eye, camera) + reach
    let direction = simd_normalize(forward)
    let hit = VoxelRaycast.cast(origin: camera, direction: direction, reach: distance, block: block)
    let target = camera + direction * (hit?.distance ?? distance)
    let delta = target - eye
    return simd_length_squared(delta) > 0.0001 ? simd_normalize(delta) : direction
  }
}
