import Foundation
import simd

/// Parked cars belong to individual garage bays, independently of AI racers.
/// Distances use the car's position, never the much more distant track center.
public enum RaceGarage {
  public static let bayCount = 3
  public static let arrivalDistance: Float = 240
  public static let departureDistance: Float = 340
  public static func carID(track: UInt64, bay: Int) -> UInt64 {
    track &+ UInt64(bay + 1) &* 0x5241_4345_4341_5201
  }
  public static func contains(car: UInt64, track: UInt64) -> Bool {
    (0..<bayCount).contains { carID(track: track, bay: $0) == car }
  }
  public static func isNear(_ point: SIMD3<Float>, player: SIMD3<Float>, retaining: Bool = false) -> Bool {
    let distance = retaining ? departureDistance : arrivalDistance
    return simd_distance_squared(point, player) < distance * distance
  }
  public static func requiredChunks(at point: SIMD3<Float>) -> Set<ChunkCoordinate> {
    // Include body corners and ground support on both sides of a chunk seam.
    let low = BlockPosition(point - [VehicleKind.race.halfWidth + 1, 0, VehicleKind.race.halfLength + 1]).chunk
    let high = BlockPosition(point + [VehicleKind.race.halfWidth + 1, 0, VehicleKind.race.halfLength + 1]).chunk
    return Set((low.x...high.x).flatMap { x in (low.z...high.z).map { ChunkCoordinate(x, $0) } })
  }
}
