/// Distant surface meshes preserve terrain, roof and treetop silhouettes without
/// retaining voxel volumes or rendering hidden underground cave faces.
public enum TerrainLOD {
  public static func build(_ chunk: ChunkData, sampleStride step: Int) -> VoxelMesh {
    precondition(step > 0 && step <= 16 && 16 % step == 0)
    let side = 16 / step + 1
    var heights = [Float](repeating: Float(ChunkData.minimumY), count: side * side)
    var blocks = [Block](repeating: .stone, count: side * side)
    for z in 0..<side {
      for x in 0..<side {
        let i = z * side + x
        for y in stride(from: ChunkData.height - 1, through: ChunkData.minimumY, by: -1) {
          let block = chunk[x * step, y, z * step]
          if block.isSolid {
            heights[i] = Float(y + 1)
            blocks[i] = block
            break
          }
        }
      }
    }
    func point(_ x: Int, _ z: Int) -> SIMD3<Float> {
      [Float(x * step), heights[z * side + x], Float(z * step)]
    }
    var mesh = VoxelMesh()
    for z in 0..<(side - 1) {
      for x in 0..<(side - 1) {
        mesh.appendQuad(
          [point(x, z), point(x, z + 1), point(x + 1, z + 1), point(x + 1, z)],
          normal: [0, 1, 0], block: blocks[z * side + x], face: 2,
          materialIndex: blocks[z * side + x].isFoliage ? 0 : nil)
      }
    }
    // Skirts cover small differences at transitions between sampling densities.
    func skirt(_ a: SIMD3<Float>, _ b: SIMD3<Float>, block: Block, face: Int) {
      let bottom = min(a.y, b.y) - 32
      let d = VoxelMesher.offsets[face]
      mesh.appendQuad(
        [[a.x, bottom, a.z], a, b, [b.x, bottom, b.z]],
        normal: [Float(d.x), Float(d.y), Float(d.z)], block: block, face: face,
        materialIndex: block.isFoliage ? 0 : nil)
    }
    for i in 0..<(side - 1) {
      skirt(point(0, i + 1), point(0, i), block: blocks[i * side], face: 1)
      skirt(point(side - 1, i), point(side - 1, i + 1), block: blocks[i * side + side - 1], face: 0)
      skirt(point(i, 0), point(i + 1, 0), block: blocks[i], face: 5)
      skirt(
        point(i + 1, side - 1), point(i, side - 1), block: blocks[(side - 1) * side + i], face: 4)
    }
    return mesh
  }
}
