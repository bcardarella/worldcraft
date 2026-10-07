import Foundation

/// Host CPU only: procedural reef/Sun chunk work, two bounded swimming searches
/// per tick, and eighteen moving car bodies. Excludes RealityKit and the GPU.
@main struct BenchmarkHabitats {
  static func main() throws {
    let terrain = TerrainGenerator(seed: 8192)
    var reef: Settlement?
    search: for z in -8...8 { for x in -8...8 {
      if let site = SettlementGenerator.site(in: .init(x, z), terrain: terrain), site.habitat == .aquatic {
        reef = site; break search
      }
    } }
    guard let reef else { fatalError("Expected a reef village") }
    var generation: [String: Double] = [:]
    var reefChunks: [ChunkCoordinate: ChunkData] = [:]
    for (name, world, point) in [("reef", terrain, reef.center), ("sun", SolarSystem(seed: 8192).sun.terrain, SolarSystem(seed: 8192).sun.terrain.spawn())] {
      let center = BlockPosition(point).chunk
      let start = Date()
      var chunks: [ChunkCoordinate: ChunkData] = [:]
      for z in -2...2 { for x in -2...2 {
        let coordinate = ChunkCoordinate(center.x + x, center.z + z)
        chunks[coordinate] = world.generate(coordinate)
      } }
      generation[name + "_25_chunks_ms"] = Date().timeIntervalSince(start) * 1000
      if name == "reef" { reefChunks = chunks }
    }
    let block: (BlockPosition) -> Block = { p in
      guard let chunk = reefChunks[p.chunk] else { return .stone }
      return chunk[p.x - p.chunk.x * 16, p.y, p.z - p.chunk.z * 16]
    }
    var swimTimes: [Double] = [], carTimes: [Double] = []
    var waypoints = 0
    var cars = (0..<18).map { i in VehiclePhysics(position: [Float(i % 6 * 12), 0, Float(i / 6 * 16)]) }
    for tick in 0..<180 {
      var start = Date()
      for i in 0..<2 {
        let origin = reef.meetingPoint(index: (tick + i) % 10, purpose: .home)
        let target = reef.meetingPoint(index: (tick * 3 + i) % 10, purpose: .work)
        waypoints += ResidentNavigation.path(from: origin, to: target, swimming: true, block: block).count
      }
      if tick >= 10 { swimTimes.append(Date().timeIntervalSince(start) * 1000) }
      start = Date()
      for i in cars.indices {
        cars[i].update(deltaTime: 1/90, throttle: 0.6, turn: 0.25, brake: 0,
          block: { p in p.y < 0 ? .stone : .air })
      }
      if tick >= 10 { carTimes.append(Date().timeIntervalSince(start) * 1000) }
    }
    swimTimes.sort(); carTimes.sort()
    let result: [String: Any] = ["measurement": "Host CPU only; no headset/GPU timing",
      "generation": generation, "two_swim_paths_p95_ms": swimTimes[Int(Double(swimTimes.count - 1) * 0.95)],
      "eighteen_car_updates_p95_ms": carTimes[Int(Double(carTimes.count - 1) * 0.95)],
      "swim_waypoints": waypoints, "reef_name": reef.name,
      "reef_blocks": [reef.x, reef.floor, reef.z]]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
  }
}
