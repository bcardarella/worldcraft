import Foundation

/// Same far-horizon leaves and incoming meshes, comparing the old pairwise
/// coverage scan to the spatial index. Includes index construction; no GPU/FPS.
@main struct BenchmarkCoverage {
  static func main() throws {
    for detail in [10, 16] {
      let previous = TerrainStreamingPlan(center: .init(-14, -10), radius: 128, detailRadius: detail).tiles
      var before: [Double] = [], after: [Double] = [], checksum = 0
      for step in 0..<80 {
        let shift = [4, 8, 12, 16][step % 4]
        let desired = TerrainStreamingPlan(center: .init(-14 + shift, -10), radius: 128, detailRadius: detail,
          lookAhead: .init(-8 + shift, -8)).tiles
        let ordered = desired.sorted { ($0.x, $0.z, $0.size) < ($1.x, $1.z, $1.size) }
        let available = previous.union(ordered.enumerated().filter { $0.offset % 4 < step % 4 }.map(\.element))
        var old: (Set<TerrainTile>, Set<TerrainTile>) = ([], [])
        var actual: TerrainCoverage?
        func legacy() {
          let start = Date()
          let retired = Set(available.filter { tile in
            !desired.contains(tile) && desired.filter { $0.overlaps(tile) }.allSatisfy { available.contains($0) }
          })
          let remaining = available.subtracting(retired), blockers = remaining.subtracting(desired)
          let visible = Set(remaining.filter { tile in !desired.contains(tile) || !blockers.contains { $0.overlaps(tile) } })
          before.append(Date().timeIntervalSince(start) * 1_000); old = (retired, visible)
        }
        func indexed() {
          let start = Date()
          actual = TerrainCoverage(desired: desired, available: available)
          after.append(Date().timeIntervalSince(start) * 1_000)
        }
        if step % 2 == 0 { legacy(); indexed() } else { indexed(); legacy() }
        precondition(actual!.retired == old.0 && actual!.visible == old.1)
        checksum += actual!.visible.count
      }
      before.sort(); after.sort()
      let result: [String: Any] = ["horizon_metres": 1024, "detail_chunks": detail, "previous_tiles": previous.count,
        "samples": before.count, "identical_coverage_checksum": checksum,
        "old_p50_ms": before[40], "indexed_p50_ms": after[40], "old_p95_ms": before[76], "indexed_p95_ms": after[76],
        "measurement": "Host Release CPU coverage only. Same geometry and visibility; not headset FPS."]
      print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
  }
}
