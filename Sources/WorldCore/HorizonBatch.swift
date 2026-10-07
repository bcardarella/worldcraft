public struct HorizonBatchKey: Hashable, Sendable {
  public let x: Int
  public let z: Int
  public let detail: ChunkDetail
  public var side: Int { detail == .reduced ? 2 : 4 }
  public var origin: SIMD3<Float> { [Float(x * side * 16), 0, Float(z * side * 16)] }
  public init(coordinate: ChunkCoordinate, detail: ChunkDetail) {
    self.detail = detail
    let side = detail == .reduced ? 2 : 4
    x = floorDivide(coordinate.x, by: side); z = floorDivide(coordinate.z, by: side)
  }
  public func merge(_ meshes: [ChunkCoordinate: VoxelMesh]) -> VoxelMesh {
    var result = VoxelMesh()
    for coordinate in meshes.keys.sorted(by: { ($0.z, $0.x) < ($1.z, $1.x) }) {
      var source = meshes[coordinate]!
      let offset = coordinate.origin - origin
      source.positions = source.positions.map { $0 + offset }
      result.append(source)
    }
    return result
  }
}
