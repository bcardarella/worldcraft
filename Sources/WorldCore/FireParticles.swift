import Foundation
import simd

/// One shared particle draw for nearby torches. Shapes, lifetime fades and heat
/// colours live in FireParticles.png; motion is evaluated from time rather than
/// accumulating simulation steps when rendering falls behind.
public enum FireParticles {
  public static let sourceLimit = 20
  public static let radius: Float = 96
  public static let particlesPerSource = 40 // 12 smoke, 24 flame, 4 embers
  public static let vertexCapacity = sourceLimit * particlesPerSource * 4
  public static let atlasFrames = 32
  public static let atlasRows = 4

  public static let indices: [UInt32] = (0..<(sourceLimit * particlesPerSource)).flatMap { i in
    let v = UInt32(i * 4)
    return [v, v + 1, v + 2, v, v + 2, v + 3]
  }

  public static func clock(_ time: Double) -> Float {
    Float(max(0, time).truncatingRemainder(dividingBy: 4_096))
  }

  private static func random(_ seed: UInt32) -> Float {
    var n = seed
    n ^= n >> 16; n &*= 0x7feb352d; n ^= n >> 15; n &*= 0x846ca68b; n ^= n >> 16
    return Float(n & 65_535) / 65_536
  }

  /// CPU reference and off-actor fallback for devices without the compute path.
  /// Always initializes the entire replacement buffer, including unused slots.
  public static func vertices(sources: [FireParticleSource], time: Float, eye: SIMD3<Float>) -> [FireParticleVertex] {
    var result = Array(repeating: FireParticleVertex(), count: vertexCapacity)
    for (sourceIndex, source) in sources.prefix(sourceLimit).enumerated() {
      for slot in 0..<particlesPerSource {
        let seed = UInt32(source.positionAndSeed.w) &+ UInt32(slot) &* 7_919
        let r = random(seed), r2 = random(seed &+ 1), r3 = random(seed &+ 2)
        let smoke = slot < 12, ember = slot >= 36
        let life: Float = smoke ? 2.1 + r * 0.4 : ember ? 0.75 + r * 0.3 : 0.5 + r * 0.3
        let progress = time / life + r2
        let age = progress - floor(progress), seconds = age * life
        let spin = time * (smoke ? 1.1 : 3.5) + r3 * 6.2831853
        let drift = (smoke ? Float(1.7) : ember ? 0.8 : 1) * seconds * seconds * 0.5
        var center = SIMD3<Float>(source.positionAndSeed.x, source.positionAndSeed.y, source.positionAndSeed.z)
        center += SIMD3<Float>((r2 - 0.5) * 0.17, smoke ? 0.32 : 0.08, (r3 - 0.5) * 0.17)
        center += SIMD3<Float>(source.wind.x, 0, source.wind.z) * drift
        center.y += seconds * (smoke ? 0.6 : ember ? 1.2 + r * 0.5 : 0.6 + r * 0.3) + 0.35 * seconds * seconds
        let curl: Float = smoke ? 0.14 : ember ? 0.015 : 0.035
        center += SIMD3<Float>(sin(spin), 0, cos(spin * 0.9)) * curl * age
        let width: Float = smoke ? 0.22 + age * 0.62 : ember ? 0.015 + r * 0.013 : (0.25 + r * 0.12) * (1 - age * 0.8)
        let height = width * (smoke ? 1 : ember ? 2.8 : 2.4)
        var facing = eye - center
        facing = simd_length_squared(facing) > 0.000001 ? simd_normalize(facing) : [0, 0, 1]
        var right = simd_cross([0, 1, 0], facing)
        right = simd_length_squared(right) > 0.000001 ? simd_normalize(right) : [1, 0, 0]
        let up = simd_cross(facing, right)
        let row = smoke ? 2 : ember ? 3 : slot % 2
        let frame = min(atlasFrames - 1, Int(age * Float(atlasFrames)))
        for corner in 0..<4 {
          let u: Float = corner == 1 || corner == 2 ? 1 : 0
          let v: Float = corner >= 2 ? 1 : 0
          let p = center + right * ((u - 0.5) * width) + up * ((v - 0.5) * height)
          // Four pixels of transparent padding per 64px cell avoid atlas bleed.
          let uv = SIMD2<Float>((Float(frame) + 0.0625 + u * 0.875) / Float(atlasFrames),
            1 - (Float(row) + 0.9375 - v * 0.875) / Float(atlasRows))
          result[(sourceIndex * particlesPerSource + slot) * 4 + corner] = .init(position: p, uv: uv)
        }
      }
    }
    return result
  }
}

/// Matches the Metal source structure; no Swift SIMD3 alignment ambiguity.
public struct FireParticleSource: Sendable {
  public var positionAndSeed: SIMD4<Float>
  public var wind: SIMD4<Float>
  public init(position: SIMD3<Float>, breeze: SIMD3<Float>) {
    let key = BlockPosition(position)
    let seed = UInt32(truncatingIfNeeded: key.x) &* 73_856_093
      ^ UInt32(truncatingIfNeeded: key.y) &* 19_349_663 ^ UInt32(truncatingIfNeeded: key.z) &* 83_492_791
    positionAndSeed = [position.x, position.y, position.z, Float(seed & 65_535)]
    // Keep smoke inside conservative draw bounds, even in severe storms.
    wind = [max(-0.8, min(0.8, breeze.x)), 0, max(-0.8, min(0.8, breeze.z)), 0]
  }
}

public struct FireParticleFrame: Sendable {
  public var eyeAndTime: SIMD4<Float>
  public var counts: SIMD4<UInt32>
  public init(eye: SIMD3<Float>, time: Float, sources: Int) {
    eyeAndTime = [eye.x, eye.y, eye.z, time]
    counts = [UInt32(max(0, min(FireParticles.sourceLimit, sources))), UInt32(FireParticles.vertexCapacity), 0, 0]
  }
}

/// 20-byte position/UV vertex shared by the CPU fallback and Metal kernel.
public struct FireParticleVertex: Sendable, Equatable {
  public var px: Float = 0, py: Float = 0, pz: Float = 0, u: Float = 0, v: Float = 0
  public init() {}
  public init(position: SIMD3<Float>, uv: SIMD2<Float>) {
    px = position.x; py = position.y; pz = position.z; u = uv.x; v = uv.y
  }
}
