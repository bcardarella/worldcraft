import Foundation

/// Conservative vertical bounds for the current CPU/Metal water equations.
/// These are all-clock bounds, not a claim that every extremum is attainable.
/// As with gameplay, disturbance time must only advance after insertion.
public enum WaterWaveEnvelope {
  public static let maximumDisturbanceCount = 24
  public static let maximumDisturbanceEnergy: Float = 0.35

  /// Includes every admitted disturbance even if it belongs to another body
  /// or is too far away. A batch's bounds stay valid as new ripples arrive.
  /// Keep the amplitudes in step with WorldEnvironment and WaterAnimation.
  public static func verticalRange(depth: Float, body: WaterBody,
    includingDisturbances: Bool = true) -> ClosedRange<Float> {
    precondition(depth.isFinite && depth >= 0 && body.level.isFinite)
    let attenuation = Double(min(1, max(0.08, depth / 5)))
    let low: Double, high: Double
    switch body.kind {
    case .ocean:
      // Bound each fundamental and second harmonic separately. This avoids
      // relying on exact trigonometric identities under Float evaluation.
      let swell = (0.42 + 0.22 + 0.13 + 0.045) * 1.18 * attenuation
      low = -0.65-swell; high = 0.65+swell
    case .lava:
      let waves = (0.085 + 0.045 + 0.025) * attenuation
      low = -waves; high = waves+0.12*attenuation
    case .lake, .river:
      low = 0; high = 0
    }
    // Each ripple has |sin| <= 1, nonnegative age/radius, exponential
    // attenuation <= 1 and a denominator >= 1.
    let ripple = includingDisturbances
      ? Double(maximumDisturbanceCount)*Double(maximumDisturbanceEnergy) : 0
    let level = Double(body.level)
    // Outward rounding and slack for the short chain of Float additions in
    // both implementations. At supported terrain heights this is 1/1024 block.
    let slack = max(1.0/1024, abs(level)*Double(Float.ulpOfOne)*64)
    return Float(level+low-ripple-slack).nextDown...Float(level+high+ripple+slack).nextUp
  }
}
