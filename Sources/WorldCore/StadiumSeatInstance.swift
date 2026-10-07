import simd

/// A complete chair wholly inside its terrain tile. Coordinates use the same
/// local block space as the tile mesh; no camera-facing or per-frame state.
public struct StadiumSeatInstance: Sendable, Equatable {
  public let position: SIMD3<Float>
  public let forward: SIMD2<Float>
  public let color: UInt8
  public static let vertexCount = 72
  public static let triangleCount = 36
  public static let transformBytes = MemoryLayout<simd_float4x4>.stride

  public var transform: simd_float4x4 {
    .init(columns: (SIMD4(forward.y, 0, -forward.x, 0), [0, 1, 0, 0],
      SIMD4(forward.x, 0, forward.y, 0), SIMD4(position, 1)))
  }
  // A conservative bound for all rotated seat parts, small enough to preserve
  // the existing tile culling unit. No bound reaches outside its owning tile.
  public var minimum: SIMD3<Float> { position - [1, 0, 1] }
  public var maximum: SIMD3<Float> { position + [1, 1.9, 1] }
  func isValid(in tile: TerrainTile) -> Bool {
    tile.fullDetail && (color == 13 || color == 21)
      && position.x.isFinite && position.y.isFinite && position.z.isFinite
      && forward.x.isFinite && forward.y.isFinite
      && abs(simd_length_squared(forward) - 1) < 0.0001
      && minimum.x > 0 && minimum.z > 0
      && maximum.x < Float(tile.blockSize) && maximum.z < Float(tile.blockSize)
      && position.y >= Float(ChunkData.minimumY) && maximum.y <= Float(ChunkData.height)
  }

  public static func template(color: UInt8, repeatAtlas: Bool) -> PackedTerrainMesh {
    precondition(color == 13 || color == 21)
    return .init(SportsGroundMesher.seatTemplate(color: color), repeatOpaqueAtlas: repeatAtlas)
  }
}
