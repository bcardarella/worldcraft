import Foundation
import simd

/// A reserved street-side plot. The pad is part of the voxel settlement, while
/// the reusable ship is a small articulated mesh in the same block coordinates.
public struct RocketPort: Codable, Equatable, Sendable {
  public let settlementID: UInt64
  public let town: String
  public let x: Int
  public let z: Int
  public let floor: Int
  public var center: SIMD3<Float> { [Float(x), Float(floor), Float(z)] }
  public var exit: SIMD3<Float> { center + [0, 0.02, 6] }
  /// Reserve the hull and landing fins for street traffic, including while the
  /// arriving ship is still aloft. This does not modify terrain or player edits.
  public func blocksTraffic(_ p: BlockPosition) -> Bool {
    (x - 6...x + 5).contains(p.x) && (z - 5...z + 4).contains(p.z)
      && (floor..<floor + 15).contains(p.y)
  }
  public func contains(x: Int, z: Int) -> Bool {
    (self.x - 8..<self.x + 8).contains(x) && (self.z - 8..<self.z + 8).contains(z)
  }
  public var chunks: Set<ChunkCoordinate> {
    Set((-8...7).flatMap { dx in [-8, 7].map { dz in BlockPosition(x + dx, floor, z + dz).chunk } })
  }
  public var isValid: Bool {
    (-99_000_000..<99_000_000).contains(x) && (-99_000_000..<99_000_000).contains(z) && (1..<ChunkData.height - 25).contains(floor)
      && !town.isEmpty && town.count < 100
  }
  /// Never erase construction to make room for a rocket or a landing.
  public func accepts(edits: [SavedEdit]) -> Bool {
    !edits.contains { edit in
      guard contains(x: edit.position.x, z: edit.position.z) else { return false }
      let y = edit.position.y - floor
      return y == -1 ? !edit.block.isSolid : y >= 0 && edit.block != .air
    }
  }
  public func welcomePosition(_ index: Int) -> SIMD3<Float> {
    let positions: [SIMD2<Float>] = [[-6.5, -6.5], [0, -6.5], [6.5, -6.5], [-6.5, -2], [6.5, -2], [-6.5, 3], [6.5, 3], [5, 6.5]]
    let p = positions[((index % positions.count) + positions.count) % positions.count]
    return center + [p.x, 0.02, p.y]
  }
  /// Bounded, deterministic search; run on a background task, never per frame.
  public static func nearest(to point: SIMD3<Float>, terrain: TerrainGenerator,
    edits: [SavedEdit] = [], maximumRegionRadius: Int = 7) -> RocketPort? {
    let origin = ChunkCoordinate(floorDivide(Int(point.x), by: SettlementGenerator.regionSize),
      floorDivide(Int(point.z), by: SettlementGenerator.regionSize))
    var best: RocketPort?
    var distance = Float.infinity
    for ring in 0...max(0, min(12, maximumRegionRadius)) {
      for dz in -ring...ring {
        for dx in -ring...ring where max(abs(dx), abs(dz)) == ring {
          guard let port = SettlementGenerator.site(in: .init(origin.x + dx, origin.z + dz), terrain: terrain)?.rocketPort,
            port.accepts(edits: edits) else { continue }
          let d = SIMD2(port.center.x - point.x, port.center.z - point.z)
          if simd_length_squared(d) < distance { best = port; distance = simd_length_squared(d) }
        }
      }
      // Beyond this ring every region is farther than the best possible pad.
      if best != nil && Float(max(0, ring - 1) * SettlementGenerator.regionSize) > sqrt(distance) { break }
    }
    return best
  }
}

extension Settlement {
  public var rocketPort: RocketPort? {
    guard habitat != .aquatic, kind != .village, id % 3 != 0 else { return nil }
    let offset = spacing / 2
    return .init(settlementID: id, town: name, x: x + offset, z: z + offset, floor: floor)
  }
}

public struct RocketBox: Sendable {
  public let size: SIMD3<Float>
  public let center: SIMD3<Float>
  public init(_ size: SIMD3<Float>, _ center: SIMD3<Float>) { self.size = size; self.center = center }
  public func overlaps(center point: SIMD3<Float>, radius: Float) -> Bool {
    let delta = abs(point - center), extent = size / 2 + SIMD3<Float>(repeating: radius)
    return delta.x < extent.x && delta.y < extent.y && delta.z < extent.z
  }
  public func overlaps(feet: SIMD3<Float>) -> Bool {
    let a = feet + [-PlayerPhysics.radius, 0.001, -PlayerPhysics.radius]
    let b = feet + [PlayerPhysics.radius, PlayerPhysics.height - 0.001, PlayerPhysics.radius]
    let lo = center - size / 2, hi = center + size / 2
    return a.x < hi.x && b.x > lo.x && a.y < hi.y && b.y > lo.y && a.z < hi.z && b.z > lo.z
  }
}

public enum RocketCabin {
  // Shared with the mesh builder, including transparent but solid windows.
  public static let walls: [RocketBox] = [
    .init([0.5, 6.5, 8.5], [-4, 3.25, 0]), .init([0.5, 6.5, 8.5], [4, 3.25, 0]),
    .init([8, 6.5, 0.5], [0, 3.25, -4]),
    .init([2.4, 6.5, 0.5], [-2.8, 3.25, 4]), .init([2.4, 6.5, 0.5], [2.8, 3.25, 4]),
    .init([3.2, 1, 0.5], [0, 6, 4]), .init([8.5, 0.25, 8.5], [0, -0.125, 0]),
    .init([8.5, 0.5, 8.5], [0, 6.75, 0]),
  ]
  public static let door = RocketBox([3.2, 5.5, 0.4], [0, 2.75, 4])
  public static let nose: [RocketBox] = (0..<7).map { i in
    let width = 8.5 - Float(i) * 1.1
    return .init([width, 1, width], [0, 7.5 + Float(i), 0])
  }
  public static let fins: [RocketBox] = [-4.6, 4.6].flatMap { x in
    [-3.4, 3.4].flatMap { z in [RocketBox([1.2, 4.5, 1.2], [x, 2.25, z]),
      RocketBox([1.7, 0.25, 1.7], [x, 0.125, z])] }
  }
  public static let button = SIMD3<Float>(0, 1.85, -3.27)
  public static let previousPlanet = SIMD3<Float>(-1.2, 2.65, -3.27)
  public static let nextPlanet = SIMD3<Float>(1.2, 2.65, -3.27)
  public static let outerDoorPanel = SIMD3<Float>(2.35, 2.8, 4.35)
  public static let innerDoorPanel = SIMD3<Float>(2.35, 2.8, 3.65)
  public static func contains(_ localFeet: SIMD3<Float>) -> Bool {
    abs(localFeet.x) <= 3.1 && abs(localFeet.z) <= 3.1 && (-0.1...2.8).contains(localFeet.y)
  }
  public static func obstructs(_ feet: SIMD3<Float>, doorOpen: Float) -> Bool {
    walls.contains { $0.overlaps(feet: feet) } || nose.contains { $0.overlaps(feet: feet) }
      || fins.contains { $0.overlaps(feet: feet) } || (doorOpen < 0.98 && door.overlaps(feet: feet))
  }
  public static func inDoorway(_ feet: SIMD3<Float>) -> Bool { door.overlaps(feet: feet) }
  public static func passenger(_ feet: SIMD3<Float>, movement: SIMD3<Float>, deltaTime: Float) -> SIMD3<Float> {
    let v = movement / max(1, simd_length(movement)) * 3.5 * max(0, min(0.05, deltaTime))
    let p = feet + v
    return [min(3.1, max(-3.1, p.x)), 0.02, min(3.1, max(-3.1, p.z))]
  }
}

public enum RocketPhase: String, Codable, Sendable, CaseIterable {
  case countdown, ascent, cruise, descent, landed
  public var duration: Double {
    switch self { case .countdown: 3; case .ascent: 14; case .cruise: 28; case .descent: 14; case .landed: 0 }
  }
}

/// Autopilot advances only during active, tracked play. Surface coordinates and
/// the solar-system coordinate space have an explicit handoff; the passenger's
/// cabin-relative position is identical on both sides of it.
public struct RocketJourney: Codable, Sendable {
  public let originPlanet: Int
  public let destinationPlanet: Int
  public let origin: RocketPort
  public let destination: RocketPort
  public private(set) var phase: RocketPhase = .countdown
  public private(set) var elapsed: Double = 0
  public var passenger: SIMD3<Float>
  public init(originPlanet: Int, destinationPlanet: Int, origin: RocketPort, destination: RocketPort,
    passenger: SIMD3<Float>) {
    self.originPlanet = originPlanet; self.destinationPlanet = destinationPlanet
    self.origin = origin; self.destination = destination
    self.passenger = RocketCabin.passenger(passenger, movement: .zero, deltaTime: 0)
  }
  public var usesDestination: Bool { [.cruise, .descent, .landed].contains(phase) }
  public var port: RocketPort { usesDestination ? destination : origin }
  public var isValid: Bool {
    (0..<6).contains(originPlanet) && (0..<6).contains(destinationPlanet) && originPlanet != destinationPlanet
      && origin.isValid && destination.isValid && elapsed.isFinite && (0...phase.duration).contains(elapsed)
      && passenger.x.isFinite && passenger.y.isFinite && passenger.z.isFinite && RocketCabin.contains(passenger)
  }
  public mutating func advance(seconds: Double, doorClosed: Bool, landingReady: Bool) {
    guard seconds.isFinite, seconds > 0, phase != .landed else { return }
    if phase == .countdown && !doorClosed { return }
    if phase == .descent && !landingReady { return }
    elapsed = min(phase.duration, elapsed + min(0.05, seconds))
    guard elapsed >= phase.duration else { return }
    if phase == .cruise && !landingReady { return }
    phase = [.countdown: .ascent, .ascent: .cruise, .cruise: .descent, .descent: .landed][phase] ?? .landed
    elapsed = 0
  }
  public var fraction: Float { phase.duration > 0 ? Float(elapsed / phase.duration) : 1 }
  public var surfacePosition: SIMD3<Float> {
    let height = Float(port.floor)+SolarSystem.departureAltitude+100
    let t = Self.ease(fraction)
    switch phase {
    case .ascent: return origin.center + [0, (height - Float(origin.floor)) * t, 0]
    case .descent: return destination.center + [0, (height - Float(destination.floor)) * (1 - t), 0]
    default: return port.center
    }
  }
  public func spacePosition(system: SolarSystem, time: Double) -> SIMD3<Float> {
    let a = system.planets[originPlanet], b = system.planets[destinationPlanet]
    let start = a.position(at: time) + [0, a.radius + 55, 0]
    let end = b.position(at: time) + [0, b.radius + 55, 0]
    // Fly vertically above the orbital planes, then across and down. This lane
    // clears every moving planet (including the Sun), even on long crossings.
    let lane = system.planets.map { p in
      (p.orbit.map { $0.focus.y + $0.radius * abs(Float(sin($0.inclination))) } ?? p.center.y) + p.radius
    }.max()! + 900
    let highStart = SIMD3(start.x, lane, start.z), highEnd = SIMD3(end.x, lane, end.z)
    let f = fraction
    if f < 0.22 { return simd_mix(start, highStart, SIMD3(repeating: Self.ease(f / 0.22))) }
    if f < 0.78 { return simd_mix(highStart, highEnd, SIMD3(repeating: Self.ease((f - 0.22) / 0.56))) }
    return simd_mix(highEnd, end, SIMD3(repeating: Self.ease((f - 0.78) / 0.22)))
  }
  private static func ease(_ x: Float) -> Float { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
}
