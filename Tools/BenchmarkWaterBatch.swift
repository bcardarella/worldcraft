import Foundation

/// Reconstructs the log's unedited Mossmere coastline. Measures preparation and
/// structural work counts, not RealityKit CPU, GPU time, memory footprint or FPS.
@main struct BenchmarkWaterBatch {
  static func main() throws {
    let terrain = TerrainGenerator(seed: 967252643)
    let eye = SIMD3<Float>(263.43787, 27, 2.43876)
    let plan = TerrainStreamingPlan(center: BlockPosition(eye).chunk, radius: 128, detailRadius: 16)
    var geometry: [TerrainTile: WaterGeometry] = [:]
    var bands: [TerrainTile: Int] = [:]
    var originalParts = 0
    for tile in plan.tiles {
      let water: WaterGeometry
      if tile.fullDetail {
        water = .init(WaterPatch.build(terrain.generate(tile.coordinate), terrain: terrain))
      } else { water = TerrainSurface.build(tile, terrain: terrain).water }
      geometry[tile] = water
      originalParts += (water.shallowIndices.isEmpty ? 0 : 1) + (water.deepIndices.isEmpty ? 0 : 1)
      let delta = tile.center + [0, eye.y, 0] - eye
      let distance = (delta.x * delta.x + delta.y * delta.y + delta.z * delta.z).squareRoot()
      bands[tile] = min(20, Int(AtmosphericPerspective.strength(distance: distance, altitude: eye.y) * 20))
    }
    let groups = Dictionary(grouping: plan.tiles, by: WaterBatchKey.init)
    let oldVertices = geometry.values.reduce(0) { $0 + $1.samples.count }
    let oldIndices = geometry.values.reduce(0) { $0 + $1.shallowIndices.count + $1.deepIndices.count }
    let oldWaterTiles = geometry.values.filter { !$0.isEmpty }.count
    for run in 1...3 {
      var newParts = 0, opticalParts = 0, batches = 0, vertices = 0, indices = 0
      var packing = DurationTiming(capacity: groups.count), visibility = DurationTiming(capacity: groups.count)
      for (key, tiles) in groups {
        let water = Dictionary(uniqueKeysWithValues: tiles.map { ($0, geometry[$0]!) })
        let start = Date()
        let batch = WaterMeshBatch(key: key, geometry: water)
        let initial = batch.vertices(environment: .init(elapsed: 560))
        packing.record(seconds: Date().timeIntervalSince(start))
        vertices += initial.count; indices += batch.indices.count
        if !batch.indices.isEmpty { batches += 1 }
        let partsStart = Date()
        let parts = batch.parts(visible: plan.tiles, bands: bands)
        visibility.record(seconds: Date().timeIntervalSince(partsStart))
        newParts += parts.count
        let continuous = batch.parts(visible: plan.tiles, bands: bands, continuousDepth: true)
        opticalParts += continuous.count
        precondition(continuous.reduce(0) { $0 + $1.indexCount } == batch.indices.count)
        precondition(parts.reduce(0) { $0 + $1.indexCount } == batch.indices.count)
      }
      precondition(vertices == oldVertices && indices == oldIndices)
      let report: [String: Any] = [
        "run": run, "seed": 967252643, "draw_metres": 1024, "detail_metres": 128,
        "terrain_tiles": plan.tiles.count, "old_water_meshes": oldWaterTiles, "new_water_meshes": batches,
        "old_water_parts": originalParts, "new_water_parts": newParts,
        "continuous_depth_water_parts": opticalParts,
        "vertex_stride_bytes": MemoryLayout<WaterMeshVertex>.stride,
        "old_replacements_per_second_30hz": oldWaterTiles * 30, "new_replacements_per_second_30hz": batches * 30,
        "unchanged_vertices": vertices, "unchanged_triangles": indices / 3,
        "batch_prepare_p95_ms": packing.snapshot.p95Milliseconds!,
        "batch_prepare_max_ms": packing.snapshot.maxMilliseconds!,
        "parts_p95_ms": visibility.snapshot.p95Milliseconds!,
        "scope": "Host CPU preparation and geometry counts only; no device FPS or GPU measurement",
      ]
      print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: .sortedKeys), as: UTF8.self))
    }
  }
}
