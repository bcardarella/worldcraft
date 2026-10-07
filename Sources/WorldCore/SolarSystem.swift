import Foundation

public enum PlanetStyle: Int, Codable, CaseIterable, Sendable {
  case verdant, dune, frost, ember, aurora, solar
  public var assetSuffix: String { ["", "-dune", "-frost", "-ember", "-aurora", "-solar"][rawValue] }
  public var description: String {
    ["Emerald coasts", "Golden dunes", "Glacial seas", "Obsidian highlands", "Violet forests", "Molten seas"][
      rawValue]
  }
  public var skyTint: SIMD3<Float> {
    switch self {
    case .verdant: [1, 1, 1]
    case .dune: [1, 0.80, 0.65]
    case .frost: [0.78, 0.88, 1]
    case .ember: [1, 0.53, 0.38]
    case .aurora: [0.77, 0.66, 1]
    case .solar: [1, 0.44, 0.14]
    }
  }
  public var landColor: SIMD3<Float> {
    switch self {
    case .verdant: [0.23, 0.59, 0.24]
    case .dune: [0.88, 0.58, 0.25]
    case .frost: [0.79, 0.90, 0.98]
    case .ember: [0.28, 0.15, 0.12]
    case .aurora: [0.63, 0.30, 0.68]
    case .solar: [0.30, 0.08, 0.035]
    }
  }
  public var waterColor: SIMD3<Float> {
    switch self {
    case .verdant: [0.05, 0.42, 0.56]
    case .dune: [0.05, 0.53, 0.54]
    case .frost: [0.10, 0.46, 0.68]
    case .ember: [0.25, 0.18, 0.25]
    case .aurora: [0.13, 0.36, 0.67]
    case .solar: [1, 0.42, 0.025]
    }
  }
}

/// Circular Kepler orbits with a shared focus. Distances and periods are
/// compressed for play; T²/r³ is constant and all bodies orbit prograde.
public struct PlanetOrbit: Sendable {
  public let focus: SIMD3<Float>
  public let radius: Float
  public let inclination: Double
  public let initialPhase: Double
  public var period: Double { 2_400 * pow(Double(radius) / 4_000, 1.5) }
  public func position(at time: Double) -> SIMD3<Float> {
    let angle = initialPhase - time.truncatingRemainder(dividingBy: period) * 2 * .pi / period
    let side = Double(radius) * sin(angle)
    return focus + SIMD3(
      Float(Double(radius) * cos(angle)), Float(side * sin(inclination)),
      Float(side * cos(inclination)))
  }
}

public struct PlanetDescriptor: Sendable {
  public let index: Int
  public let seed: UInt64
  public let style: PlanetStyle
  public let name: String
  public let center: SIMD3<Float>
  public let radius: Float
  public let orbit: PlanetOrbit?
  public var isStar: Bool { style == .solar }
  public var terrain: TerrainGenerator { .init(seed: seed, style: style) }
  public init(
    index: Int, seed: UInt64, style: PlanetStyle, name: String,
    center: SIMD3<Float>, radius: Float, orbit: PlanetOrbit? = nil
  ) {
    self.index = index; self.seed = seed; self.style = style; self.name = name
    self.center = center; self.radius = radius; self.orbit = orbit
  }
  public func position(at time: Double) -> SIMD3<Float> { orbit?.position(at: time) ?? center }
}

public struct SolarSystem: Sendable {
  /// Height above local terrain, in half-metre world blocks.
  public static let departureAltitude: Float = WorldScale.blocks(1_000)
  public static func canDepart(height: Float, ground: Float, flying: Bool, mounted: Bool) -> Bool {
    flying && !mounted && height.isFinite && ground.isFinite && height-ground >= departureAltitude
  }
  public static func atmosphereDensity(height: Float) -> Float {
    // Even the tallest animal and mountain remain in the lower atmosphere.
    1-smoothstep(WorldScale.blocks(350), WorldScale.blocks(975), height-Float(TerrainGenerator.seaLevel))
  }
  public static let sunIndex = 5
  public let seed: UInt64
  public let planets: [PlanetDescriptor]
  public var sun: PlanetDescriptor { planets[Self.sunIndex] }
  public init(seed: UInt64) {
    self.seed = seed
    let generator = TerrainGenerator(seed: seed)
    let centers: [SIMD3<Float>] = [
      [0, 0, 0], [2_000, 450, -1_500], [-1_700, 600, -2_300], [600, -500, -3_000],
      [-2_500, -300, 900],
    ]
    let names = ["Mossmere", "Saffron", "Rime", "Cinder", "Aster", "Sun"]
    let sunCenter = SIMD3<Float>(0, 0, -4_000)
    // Radial clearance exceeds the diameters of neighboring bodies at any phase.
    let orbitRadii: [Float] = [4_000, 3_100, 2_300, 1_300, 5_200]
    planets = PlanetStyle.allCases.enumerated().map { index, style in
      let hash = generator.hash(index, 811, salt: 912)
      if style == .solar {
        return .init(index: index, seed: hash, style: style, name: names[index], center: sunCenter, radius: 430)
      }
      let offset =
        index == 0
        ? SIMD3<Float>.zero
        : SIMD3<Float>(
          Float(Int(hash % 201) - 100), Float(Int((hash >> 8) % 101) - 50),
          Float(Int((hash >> 16) % 201) - 100))
      let relative = centers[index] + offset - sunCenter
      let orbit = PlanetOrbit(
        focus: sunCenter, radius: orbitRadii[index],
        inclination: atan2(Double(relative.y), Double(relative.z)),
        initialPhase: atan2(sqrt(Double(relative.y * relative.y + relative.z * relative.z)), Double(relative.x)))
      return .init(
        index: index, seed: index == 0 ? seed : hash, style: style, name: names[index],
        center: orbit.position(at: 0), radius: Float(215 + hash % 65), orbit: orbit)
    }
  }
}

/// Analog 3D thrust changes momentum in the steering direction. Gentle inertial
/// damping makes travel controllable without gravity or an airplane lift model.
public struct SpaceFlight: Codable, Sendable {
  public var position: SIMD3<Float>
  public var velocity: SIMD3<Float>
  public var heading: Float
  public var originIndex: Int
  public var clearedOrigin = false
  public init(departing planet: PlanetDescriptor, heading: Float, time: Double = 0) {
    position = planet.position(at: time) + [0, planet.radius + 55, 0]
    velocity = .zero
    self.heading = heading
    originIndex = planet.index
  }
  public var speed: Float {
    sqrt(velocity.x * velocity.x + velocity.y * velocity.y + velocity.z * velocity.z)
  }
  public mutating func update(
    deltaTime: Float, movement: SIMD3<Float>, sprint: Bool = false, system: SolarSystem, time: Double = 0
  ) -> Int? {
    let dt = min(0.05, max(0, deltaTime))
    heading.formTruncatingRemainder(dividingBy: .pi * 2)
    let length = sqrt(movement.x * movement.x + movement.y * movement.y + movement.z * movement.z)
    let thrust = movement / max(1, length) * (sprint ? 170 : 85)
    let damping: Float = length > 0.001 ? 0.32 : 1.5
    let decay = exp(-damping * dt)
    velocity = velocity * decay + thrust * ((1 - decay) / damping)
    let limit: Float = sprint ? 240 : 140
    if speed > limit { velocity *= limit / speed }
    let start = position
    position += velocity * dt
    for planet in system.planets {
      let d = position - planet.position(at: time)
      let distance = sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
      if planet.index == originIndex && distance > planet.radius + 85 { clearedOrigin = true }
      // Test relative swept motion so moving planets cannot pass through the
      // arrival shell between simulation ticks.
      let previous = start - planet.position(at: time - Double(dt))
      let segment = d - previous
      let squared = segment.x * segment.x + segment.y * segment.y + segment.z * segment.z
      let fraction = squared > 0.000001
        ? min(1, max(0, -(previous.x * segment.x + previous.y * segment.y + previous.z * segment.z) / squared)) : 0
      let closest = previous + segment * fraction
      let approach = sqrt(closest.x * closest.x + closest.y * closest.y + closest.z * closest.z)
      if approach <= planet.radius + 20 && (planet.index != originIndex || clearedOrigin) {
        return planet.index
      }
    }
    return nil
  }
  public func distance(to planet: PlanetDescriptor, time: Double = 0) -> Float {
    let d = planet.position(at: time) - position
    return max(0, sqrt(d.x * d.x + d.y * d.y + d.z * d.z) - planet.radius)
  }
}
