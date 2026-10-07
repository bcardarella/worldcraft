/// Horizontal edges where a column-owned voxel patch meets another surface.
/// The ownership callback includes neighbouring chunks: a chunk edge alone is
/// not a patch edge. Faces at these edges are supplied by a transition mesh.
public struct VoxelColumnBoundary: Sendable {
  public struct Edge: Sendable, Hashable {
    public let x, z, face: Int
    public var neighbor: BlockPosition {
      let d = VoxelMesher.offsets[face]
      return .init(x + d.x, 0, z + d.z)
    }
    public var horizontalAxis: Int { face < 2 ? 2 : 0 }
  }
  public let columns: VoxelColumnMask
  private var positiveX = VoxelColumnMask(), negativeX = VoxelColumnMask()
  private var positiveZ = VoxelColumnMask(), negativeZ = VoxelColumnMask()

  /// Coordinates are local to this chunk, including -1 and 16 in the halo.
  /// The callback must describe the complete patch's column ownership.
  public init(columns: VoxelColumnMask, ownsNeighbor: (Int, Int) -> Bool) {
    self.columns = columns
    for z in 0..<16 { for x in 0..<16 where columns.contains(x: x, z: z) {
      if !ownsNeighbor(x + 1, z) { positiveX.include(x: x..<(x + 1), z: z..<(z + 1)) }
      if !ownsNeighbor(x - 1, z) { negativeX.include(x: x..<(x + 1), z: z..<(z + 1)) }
      if !ownsNeighbor(x, z + 1) { positiveZ.include(x: x..<(x + 1), z: z..<(z + 1)) }
      if !ownsNeighbor(x, z - 1) { negativeZ.include(x: x..<(x + 1), z: z..<(z + 1)) }
    } }
  }
  public func contains(x: Int, z: Int, face: Int) -> Bool {
    switch face {
    case 0: positiveX.contains(x: x, z: z)
    case 1: negativeX.contains(x: x, z: z)
    case 4: positiveZ.contains(x: x, z: z)
    case 5: negativeZ.contains(x: x, z: z)
    default: false
    }
  }
  public var edges: [Edge] {
    var result: [Edge] = []
    for z in 0..<16 { for x in 0..<16 {
      for face in [0, 1, 4, 5] where contains(x: x, z: z, face: face) {
        result.append(.init(x: x, z: z, face: face))
      }
    } }
    return result
  }
}
