import Foundation

/// Game time is independent of wall time: pausing freezes sky, tides and wildlife.
public struct WorldEnvironment: Sendable {
  public static let dayDuration: Double = 1_200
  public static let meanWaterLevel = Float(TerrainGenerator.seaLevel + 1)
  public var elapsed: Double
  public private(set) var disturbances: [WaterDisturbance] = []
  /// Change identity for presentation reuse; never controls physics or expiry.
  public private(set) var waterDisturbanceRevision: UInt64 = 0
  public var waterAnimationSample: WaterAnimationSchedule.Sample {
    .init(elapsed: elapsed, disturbances: waterDisturbanceRevision)
  }
  public init(elapsed: Double = dayDuration * 0.38) { self.elapsed = elapsed }
  public mutating func advance(_ seconds: Double) {
    elapsed += max(0, seconds)
    let count = disturbances.count
    disturbances.removeAll { elapsed - $0.onset > 5 }
    if disturbances.count != count { waterDisturbanceRevision &+= 1 }
  }
  public mutating func disturbWater(atX x: Float, z: Float, body: WaterBody, energy: Float = 0.13) {
    waterDisturbanceRevision &+= 1
    disturbances.append(
      .init(x: x, z: z, bodyID: body.id, onset: elapsed,
        energy: min(WaterWaveEnvelope.maximumDisturbanceEnergy, max(0, energy))))
    let limit = WaterWaveEnvelope.maximumDisturbanceCount
    if disturbances.count > limit { disturbances.removeFirst(disturbances.count - limit) }
  }
  public var dayFraction: Double {
    let fraction = elapsed / Self.dayDuration
    return fraction - floor(fraction)
  }
  public var sunDirection: SIMD3<Float> {
    let angle = Float(dayFraction) * .pi * 2 - .pi / 2
    return [cos(angle) * 0.8, sin(angle), cos(angle) * 0.6]
  }
  public var moonDirection: SIMD3<Float> { -sunDirection }
  public var sunVisibility: Float { smoothstep(-0.025, 0.015, sunDirection.y) }
  public var moonVisibility: Float { smoothstep(-0.025, 0.015, moonDirection.y) }
  public var daylight: Float { smoothstep(-0.12, 0.28, sunDirection.y) }
  public var twilight: Float {
    (1 - smoothstep(0.05, 0.38, abs(sunDirection.y))) * smoothstep(-0.22, -0.04, sunDirection.y)
  }
  public var tide: Float { 0.65 * sin(Float(dayFraction) * .pi * 4 + 0.45) }
  public var waterLevel: Float { Self.meanWaterLevel + tide }
  public var clock: String {
    let minutes = Int(dayFraction * 24 * 60)
    return String(format: "%02d:%02d", minutes / 60, minutes % 60)
  }

  /// Analytic wave slopes provide stable reflection normals without mesh regeneration.
  public func water(atX x: Float, z: Float, depth: Float = 20, body: WaterBody = .ocean)
    -> WaterSample
  {
    let attenuation = min(1, max(0.08, depth / 5))
    let t = Float(elapsed.truncatingRemainder(dividingBy: 10_000))
    let phases: [(Float, Float, Float, Float)] = body.kind == .lava ? [
      (0.085, 0.26, 0.12, 0.11), (0.045, -0.18, 0.37, 0.16), (0.025, 0.82, 0.61, 0.30),
    ] : [
      (0.42, 0.075, 0.035, 0.52), (0.22, 0.19, 0.08, 0.83),
      (0.13, -0.09, 0.31, 1.22), (0.045, 0.73, 0.49, 2.0),
    ]
    var height = body.level + (body.kind == .ocean ? tide : 0)
    var dx: Float = 0
    var dz: Float = 0
    var wake: Float = 0
    for (amplitude, kx, kz, speed) in body.kind == .lake || body.kind == .river ? [] : phases {
      let phase = x * kx + z * kz - t * speed
      let a = amplitude * attenuation
      height += a * sin(phase)
      dx += a * kx * cos(phase)
      dz += a * kz * cos(phase)
      if body.kind == .ocean {
        // A small second harmonic gives swells rounded troughs and sharper
        // crests without horizontal displacement or changing shoreline topology.
        height -= a * 0.18 * cos(2 * phase)
        let slope = a * 0.36 * sin(2 * phase)
        dx += slope * kx; dz += slope * kz
      }
    }
    if body.kind == .lava {
      // Slow local upwellings stretch the crust; no ocean swell or tide.
      let phase = x * 0.31 + z * 0.27 - t * 0.43
      let crest = max(0, sin(phase))
      height += 0.12 * attenuation * pow(crest, 12)
      let slope = 1.44 * attenuation * pow(crest, 11) * cos(phase)
      dx += slope * 0.31; dz += slope * 0.27
    }
    for ripple in disturbances where ripple.bodyID == body.id {
      let age = Float(elapsed - ripple.onset)
      let rx = x - ripple.x
      let rz = z - ripple.z
      // After five seconds the wave front cannot reach beyond 16 blocks with
      // visible energy. Avoid exponentials for distant disturbances.
      guard rx * rx + rz * rz <= 256 else { continue }
      let radius = sqrt(rx * rx + rz * rz)
      let speed: Float = body.kind == .lava ? 0.65 : 2.3
      let damping: Float = body.kind == .lava ? 1.8 : 0.8
      let frequency: Float = body.kind == .lava ? 3 : 5
      let front = radius - age * speed
      let envelope =
        ripple.energy * exp(-age * damping) * exp(-front * front / 1.8) / (1 + radius * 0.2)
      let phase = front * frequency
      height += envelope * sin(phase)
      wake += envelope * 5
      let derivative =
        envelope * (frequency * cos(phase) + sin(phase) * (-front / 0.9 - 0.2 / (1 + radius * 0.2)))
      if radius > 0.001 {
        dx += derivative * rx / radius
        dz += derivative * rz / radius
      }
    }
    let length = sqrt(dx * dx + 1 + dz * dz)
    let localDepth = max(0, depth + height - body.level)
    let shore = (1 - smoothstep(0.2, 2.6, localDepth))
      * (0.55 + 0.45 * sin(x * 0.18 + z * 0.13 - t * 0.9))
    let crest = body.kind == .ocean
      ? smoothstep(0.30, 0.66, height - body.level - tide) * 0.65 : 0
    let foam = body.kind == .lava ? 0 : min(1, shore * (body.kind == .lake ? 0.22 : 0.88) + crest + wake)
    return .init(height: height, normal: [-dx / length, 1 / length, -dz / length], foam: foam)
  }
}

public struct WaterSample: Sendable {
  public var height: Float
  public var normal: SIMD3<Float>
  public var foam: Float = 0
}

public func smoothstep(_ a: Float, _ b: Float, _ value: Float) -> Float {
  let t = min(1, max(0, (value - a) / (b - a)))
  return t * t * (3 - 2 * t)
}
