import Foundation

/// Compact, world-space optical data shared by the GPU and CPU water paths.
/// Four half values add no geometry or per-foam entities to the scene.
public enum WaterAppearance {
  /// R: depth absorption, G: foam, B: detail normal strength, A: transmission opacity.
  /// Depth is in blocks; one block is half a metre.
  public static func optics(depth: Float, body: WaterBody, sample: WaterSample) -> SIMD4<Float> {
    let wetDepth = max(0, depth + sample.height - body.level)
    let absorption = 1 - exp(-wetDepth * 0.16)
    let opacity = (0.12 + 0.80 * absorption) * smoothstep(0, 0.65, wetDepth)
    return [absorption, sample.foam, body.kind == .lake ? 0.24 : 0.70, opacity]
  }

  /// Visibility remains useful for exploring underwater settlements. Entering
  /// the water fades smoothly instead of switching to a constant blue screen.
  public static func immersion(depth: Float, daylight: Float, lava: Bool) -> SIMD4<Float> {
    let fade = smoothstep(0.02, 0.65, max(0, depth))
    if lava { return [0.90, 0.13, 0.015, 0.50 * fade] }
    let deep = 1 - exp(-max(0, depth) * 0.065)
    let light = 0.22 + 0.78 * min(1, max(0, daylight))
    let shallow = SIMD3<Float>(0.025, 0.39, 0.43)
    let abyss = SIMD3<Float>(0.008, 0.075, 0.20)
    let color = (shallow + (abyss - shallow) * deep) * light
    return [color.x, color.y, color.z, fade * (0.10 + 0.45 * deep)]
  }
}
