import Foundation

/// Exercise stable planning/coverage and queue churn during a sustained flight.
@main struct BenchmarkStreaming {
  static func main() {
    let terrain = TerrainGenerator(seed: 8192)
    let start = BlockPosition(terrain.spawn()).chunk
    for radius in [32, 128] {
      var previous: Set<TerrainTile> = []
      var previousAnchor: ChunkCoordinate?
      var times: [Double] = []
      var newTiles = 0
      var fullJobs = 0
      var farJobs = 0
      var changes = 0
      var samples = 0
      var preparationTime = 0.0
      var packedBytes = 0
      var visibilityPublications: [Int] = []
      for step in 0..<96 {
        let center = ChunkCoordinate(start.x + step, start.z + step / 4)
        let began = Date()
        let anchor = TerrainStreamingPlan.anchor(
          for: center, radius: radius, previous: previousAnchor)
        let needsPlan = anchor != previousAnchor
        let ahead = TerrainStreamingPlan.lookAhead(from: anchor, velocity: [43.2, 0, 10.8])
        let desired = needsPlan
          ? TerrainStreamingPlan(center: anchor, radius: radius, lookAhead: ahead).tiles : previous
        if needsPlan { _ = TerrainCoverage(desired: desired, available: previous).visible.count }
        let added = desired.subtracting(previous)
        times.append(Date().timeIntervalSince(began) * 1_000)
        if step > 0 {
          newTiles += added.count
          for tile in added { if tile.fullDetail { fullJobs += 1 } else { farJobs += 1 } }
          if !added.isEmpty { changes += 1 }
          if !added.isEmpty {
            let ranks = TerrainWorkPriority.ranks(desired: desired, available: previous,
              center: center, lookAhead: ahead)
            let queue = added.sorted {
              TerrainWorkPriority.precedes($0, $1, ranks: ranks, center: center)
            }
            let nearby = desired.filter { $0.fullDetail && $0.distanceSquared(to: center) <= 9 }
            var available = previous
            var count = 0
            for tile in queue {
              if nearby.isSubset(of: TerrainCoverage(desired: desired, available: available).visible) { break }
              available.insert(tile)
              count += 1
            }
            visibilityPublications.append(count)
          }
          // Sample actual changes: a periodic route sample may otherwise always
          // hit an unchanged anchor and incorrectly report zero preparation.
          if !added.isEmpty && changes % 4 == 0 {
            samples += 1
            let preparation = Date()
            for tile in added {
              let mesh: VoxelMesh
              if tile.fullDetail {
                let chunk = terrain.generate(tile.coordinate)
                var full = VoxelMesher.build(chunk, includeWater: false)
                full.append(
                  SurfaceDecorationMesher.build(
                    chunk, terrain: terrain,
                    lush: VegetationDetail.isLush(tile.coordinate, center: anchor)))
                mesh = full
              } else {
                mesh = TerrainSurface.build(tile, terrain: terrain).mesh
              }
              packedBytes += PackedTerrainMesh(mesh).byteCount
            }
            preparationTime += Date().timeIntervalSince(preparation)
          }
        }
        previous = desired
        previousAnchor = anchor
      }
      let sorted = times.sorted()
      let data: [String: Any] = [
        "radius_chunks": radius, "moves": 95, "anchor_changes": changes,
        "mean_new_tiles": Double(newTiles) / 95,
        "mean_new_voxel_jobs": Double(fullJobs) / 95,
        "mean_new_surface_jobs": Double(farJobs) / 95,
        "plan_and_coverage_p95_ms": sorted[Int(Double(sorted.count) * 0.95)],
        "plan_and_coverage_max_ms": sorted.last!,
        "sampled_changes": samples, "sampled_packed_bytes": packedBytes,
        "mean_publications_until_nearby_visible": Double(visibilityPublications.reduce(0, +))
          / Double(max(1, visibilityPublications.count)),
        "max_publications_until_nearby_visible": visibilityPublications.max() ?? 0,
        "mean_sampled_terrain_preparation_ms": preparationTime / Double(max(1, samples)) * 1_000,
      ]
      print(
        String(
          decoding: try! JSONSerialization.data(withJSONObject: data, options: .sortedKeys),
          as: UTF8.self))
    }
  }
}
