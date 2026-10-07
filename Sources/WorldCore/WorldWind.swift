import Foundation

public enum CloudFormation: String, Sendable { case cirrus, cumulus, stratus, cumulonimbus }
public struct WindSample: Sendable {
  /// Metres per second, in world axes. Gusts are continuous in space and time.
  public let velocity: SIMD3<Float>
  public let gust: Float
  public var speed: Float { sqrt(velocity.x * velocity.x + velocity.z * velocity.z) }
}
public enum WorldWind {
  public static func sample(
    seed: UInt64, time: Double, position: SIMD3<Float>, weather: WorldWeather
  ) -> WindSample {
    guard time.isFinite, position.x.isFinite, position.z.isFinite else {
      return .init(velocity: .zero, gust: 0)
    }
    let t = Float(time.truncatingRemainder(dividingBy: 100_000))
    let phase = Float(seed % 1024) * 0.006135923
    let front = weather.storminess
    let angle = phase + 0.35 * sin(t * 0.002 + phase) + front * 0.6 * sin(t * 0.009 + phase)
    let direction = SIMD2<Float>(cos(angle), sin(angle))
    // Broad fronts advect over the land; nested eddies create patches of gusts,
    // rather than every tree reacting at once or independent random shaking.
    let along = (position.x * direction.x + position.z * direction.y) * WorldScale.metresPerBlock
    let across = (-position.x * direction.y + position.z * direction.x) * WorldScale.metresPerBlock
    let wave =
      sin(along * 0.026 - t * (0.22 + front * 0.28) + phase)
      * cos(across * 0.019 + t * 0.04)
    let gust = pow(max(0, wave), 2) * (0.4 + front * 0.6)
    let base = 1.4 + weather.cloudCover * 2.0 + front * 5
    let speed = base + gust * (2 + front * 9)
    let shift = (gust - 0.15) * front * 0.65 + sin(across * 0.013 - t * 0.07) * 0.12
    let altitude = 1 + min(0.8, max(0, position.y - 30) * 0.004)
    return .init(
      velocity: [cos(angle + shift) * speed * altitude, 0, sin(angle + shift) * speed * altitude],
      gust: gust)
  }
}
