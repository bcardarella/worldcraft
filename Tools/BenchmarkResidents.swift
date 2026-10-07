import Foundation

/// Host CPU checks for the bounded navigation and request-preparation work.
/// Excludes RealityKit, rendering, animation and network/model latency.
@main struct BenchmarkResidents {
  static func main() throws {
    let terrain = TerrainGenerator(seed: 8192)
    var city: Settlement?
    for x in -15...15 {
      for z in -15...15 {
        if let site = SettlementGenerator.site(in: .init(x, z), terrain: terrain), site.kind == .city {
          city = site; break
        }
      }
      if city != nil { break }
    }
    let site = city!
    let center = BlockPosition(site.center).chunk
    let plan = TerrainStreamingPlan(center: TerrainStreamingPlan.anchor(for: center, radius: 128), radius: 128)
    let chunks = Dictionary(uniqueKeysWithValues: plan.tiles.filter(\.fullDetail).map {
      ($0.coordinate, terrain.generate($0.coordinate))
    })
    let block: (BlockPosition) -> Block = { p in
      guard let chunk = chunks[p.chunk] else { return .stone }
      return chunk[p.x - p.chunk.x * 16, p.y, p.z - p.chunk.z * 16]
    }
    var people = (0..<site.population).map { ResidentState(index: $0, site: site) }
    var samples: [Double] = []
    var paths = 0
    for tick in 0..<250 {
      let started = Date()
      for i in people.indices { people[i].advanceNeeds(seconds: 1 / 15, arrived: true, time: Double(tick) / 15) }
      for offset in 0..<2 {
        let i = (tick * 2 + offset) % people.count
        let result = ResidentNavigation.path(from: people[i].position,
          to: site.meetingPoint(index: (i * 17 + tick) % 48, purpose: .work), block: block)
        paths += result.count
      }
      if tick >= 10 { samples.append(Date().timeIntervalSince(started) * 1_000) }
    }
    let requestStart = Date()
    var encodedBytes = 0
    for _ in 0..<100 {
      let contexts = Dictionary(uniqueKeysWithValues: people.prefix(6).map {
        ($0.id, NPCDecisionContext(resident: $0, neighbors: Array(people.suffix(4))))
      })
      let options = Dictionary(uniqueKeysWithValues: people.prefix(6).map {
        ($0.id, ["work": NPCDecisionOption(activity: .work, description: $0.role.work),
          "rest": NPCDecisionOption(activity: .rest, description: "Rest at home"),
          "eat": NPCDecisionOption(activity: .eat, description: "Visit the market for a meal")])
      })
      encodedBytes = try JSONEncoder().encode(JevNPCRequest(settlement: site.name, biome: site.biome.name,
        dayFraction: 0.5, contexts: contexts, options: options)).count
    }
    let requestMilliseconds = Date().timeIntervalSince(requestStart) * 10
    samples.sort()
    let result: [String: Any] = ["residents": people.count, "samples": samples.count,
      "two_paths_and_needs_p50_ms": samples[samples.count / 2],
      "two_paths_and_needs_p95_ms": samples[Int(Double(samples.count - 1) * 0.95)],
      "two_paths_and_needs_max_ms": samples.last!, "path_waypoints": paths,
      "six_resident_request_mean_ms": requestMilliseconds, "six_resident_request_bytes": encodedBytes,
      "measurement": "Host CPU only; excludes rendering and live Jev"]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
  }
}
