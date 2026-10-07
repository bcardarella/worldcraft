/// Flat, joined voxel cloud shelves. Each shape is one culled mesh; instances
/// share a handful of resources instead of allocating an entity per cloud lobe.
public enum CloudMesher {
  public static func build(seed: UInt64, cellSize: Float = 7) -> VoxelMesh {
    let terrain = TerrainGenerator(seed: seed)
    var chunk = ChunkData(coordinate: .init(0, 0))
    for z in 0..<8 {
      for x in 0..<8 {
        let dx = Float(x) - 3.5
        let dz = Float(z) - 3.5
        let h = terrain.hash(x, z, salt: 7_710)
        let radius = dx * dx / 16 + dz * dz / 12
        guard radius < 1.0 + Float(h % 6) / 20,
          radius < 0.2 || h % 13 != 0 else { continue }
        let layers = radius < 0.7 && h % 3 == 0 ? 2 : 1
        for y in 0..<layers { chunk[x, y, z] = .snow }
      }
    }
    var mesh = VoxelMesher.build(chunk, includeWater: false)
    mesh.positions = mesh.positions.map { [$0.x * cellSize - cellSize * 4, $0.y * 1.6, $0.z * cellSize - cellSize * 4] }
    for i in mesh.materials.indices {
      let normal = mesh.normals[Int(mesh.indices[i * 3])]
      mesh.materials[i] = normal.y > 0 ? 0 : (normal.y < 0 ? 1 : 2)
    }
    return mesh
  }
}
