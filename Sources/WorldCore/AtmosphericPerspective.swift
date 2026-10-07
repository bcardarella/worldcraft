import Foundation

/// Distance haze is applied in shared material bands on visionOS. It retains
/// crisp nearby blocks while distant hills converge toward the current sky.
public enum AtmosphericPerspective {
  public static func strength(distance: Float, altitude: Float) -> Float {
    let air = SolarSystem.atmosphereDensity(height:altitude)
    return min(0.78, 1 - exp(-max(0, distance - 48) * 0.0012)) * air
  }

  public static func color(environment: WorldEnvironment, style: PlanetStyle) -> SIMD3<Float> {
    if style == .solar { return [0.84, 0.25, 0.04] }
    let night = SIMD3<Float>(0.025, 0.055, 0.115)
    let day = SIMD3<Float>(0.39, 0.79, 0.91)
    let gold = SIMD3<Float>(1, 0.72, 0.34)
    let daylight = night + (day - night) * environment.daylight
    let sky = daylight + (gold - daylight) * environment.twilight
    return sky * style.skyTint
  }
}
