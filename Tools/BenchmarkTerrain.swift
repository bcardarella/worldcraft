import Foundation

/// Compile with swiftc -O Sources/WorldCore/*.swift Tools/BenchmarkTerrain.swift.
/// This measures serial host preparation, not headset rendering or total memory.
@main struct BenchmarkTerrain {
  static func measure(
    center: ChunkCoordinate, radius: Int, terrain: TerrainGenerator, label: String
  ) {
    let start = Date()
    let anchor = TerrainStreamingPlan.anchor(for: center, radius: radius)
    let plan = TerrainStreamingPlan(center: anchor, radius: radius)
    let planTime = Date().timeIntervalSince(start)
    var faces = 0
    var waterTriangles = 0
    var waterEntities = 0
    var full = 0
    var plants = 0
    var meshBytes = 0
    var packedBytes = 0
    var packedTime = 0.0
    var parts = 0
    var maximumJobTime = 0.0
    var facesByDetail: [String: Int] = [:]
    for tile in plan.tiles.sorted(by: { ($0.z, $0.x, $0.size) < ($1.z, $1.x, $1.size) }) {
      let jobStart = Date()
      let mesh: VoxelMesh
      let water: WaterGeometry
      if tile.fullDetail {
        let chunk = terrain.generate(tile.coordinate)
        var m = VoxelMesher.build(chunk, includeWater: false)
        let decoration = SurfaceDecorationMesher.build(
          chunk, terrain: terrain, lush: VegetationDetail.isLush(tile.coordinate, center: anchor))
        plants += decoration.faceCount
        m.append(decoration)
        mesh = m
        water = .init(WaterPatch.build(chunk, terrain: terrain))
        full += 1
      } else {
        let result = TerrainSurface.build(tile, terrain: terrain)
        mesh = result.mesh
        water = result.water
      }
      faces += mesh.faceCount
      facesByDetail[tile.fullDetail ? "voxel" : "surface_\(tile.size)", default: 0] += mesh.faceCount
      meshBytes +=
        mesh.positions.count * 16 + mesh.normals.count * 16 + mesh.textureCoordinates.count * 8
        + (mesh.indices.count + mesh.materials.count) * 4
      waterTriangles += (water.shallowIndices.count + water.deepIndices.count) / 3
      if !water.isEmpty { waterEntities += 1 }
      let packingStart = Date()
      let packed = PackedTerrainMesh(mesh)
      packedTime += Date().timeIntervalSince(packingStart)
      packedBytes += packed.byteCount
      parts += packed.parts.count
      maximumJobTime = max(maximumJobTime, Date().timeIntervalSince(jobStart))
    }
    let total = Date().timeIntervalSince(start)
    let result: [String: Any] = [
      "scene": label, "radius_chunks": radius, "radius_metres": radius * 8,
      "tiles": plan.tiles.count,
      "equivalent_chunks": plan.tiles.reduce(0) { $0 + $1.size * $1.size },
      "full_chunks": full, "terrain_quads": faces, "plant_quads": plants, "terrain_parts": parts,
      "quads_by_detail": facesByDetail,
      "water_triangles": waterTriangles, "water_entities": waterEntities,
      "surface_mesh_MiB": Double(meshBytes) / 1_048_576,
      "packed_upload_MiB": Double(packedBytes) / 1_048_576,
      "retained_voxel_MiB": Double(full * 18 * 18 * 192) / 1_048_576,
      "plan_ms": planTime * 1_000, "prepare_seconds": total - packedTime,
      "pack_seconds": packedTime, "total_seconds": total, "largest_job_ms": maximumJobTime * 1_000,
    ]
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  }
  static func main() {
    let terrain = TerrainGenerator(seed: 8192)
    let radii = CommandLine.arguments.dropFirst().compactMap(Int.init)
    for radius in radii.isEmpty ? [16, 32, 48, 128] : radii {
      measure(
        center: BlockPosition(terrain.spawn()).chunk, radius: radius, terrain: terrain,
        label: "Home village")
    }
    for x in -15...15 {
      for z in -15...15 {
        if let site = SettlementGenerator.site(in: .init(x, z), terrain: terrain),
          site.kind == .city
        {
          measure(
            center: BlockPosition(site.center).chunk, radius: radii.last ?? 128, terrain: terrain,
            label: "Metropolitan city")
          return
        }
      }
    }
  }
}
