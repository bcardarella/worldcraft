import Foundation

/// Host Release CPU measurements. Excludes RealityKit, Jev/network, and the GPU.
/// Build alongside Sources/WorldCore/*.swift, as with BenchmarkHabitats.swift.
@main struct BenchmarkDinosaurs {
  static func main() throws {
    let terrain = TerrainGenerator(seed: 8192)
    var sites: [ColossalRexSite] = [], survey: [Double] = []
    for x in -10...10 { for z in -10...10 {
      let start = Date()
      if let site = ColossalRexSite.candidate(in: .init(x, z), terrain: terrain) { sites.append(site) }
      survey.append(Date().timeIntervalSince(start) * 1_000)
    } }
    guard let site = sites.first else { fatalError("No colossal habitat found") }
    var animals: [RexState] = []
    for i in 0..<16 {
      let position = SIMD3<Float>(Float(i * 8), 30, 0)
      let kind = DinosaurKind.allCases[i % 8]
      animals.append(RexState(id: UInt64(i), color: .pink, baby: i % 3 == 0, position: position, kind: kind))
    }
    var giant = ColossalRexState(site: site), physics: [Double] = [], giantTimes: [Double] = []
    let goals = animals.map { AnimalDecisionOption(.explore, at: .init($0.position + [0,0,-200]), description: "Explore") }
    let giantGoal = AnimalDecisionOption(.patrol, at: .init(site.position + [0,0,-200]), description: "Survey territory")
    var probes = 0
    for frame in 0..<900 {
      let time = Double(frame) / 30
      var start = Date()
      for i in animals.indices {
        _ = animals[i].update(deltaTime: 1 / 30, time: time, player: [1_000,100,1_000], directive: goals[i]) {
          $0.y < 30 ? .grass : .air
        }
      }
      if frame > 30 { physics.append(Date().timeIntervalSince(start) * 1_000) }
      start = Date()
      giant.update(deltaTime: 1 / 30, time: time, player: [100_000,100,100_000], directive: giantGoal) { x,z in
        probes += 1
        let c = terrain.column(atX: Int(x), z: Int(z))
        return .init(height: Float(c.height + 1), waterDepth: max(0, (c.water?.level ?? Float(c.height)) - Float(c.height)))
      }
      if frame > 30 { giantTimes.append(Date().timeIntervalSince(start) * 1_000) }
    }
    func percentile(_ values: [Double], _ fraction: Double) -> Double {
      values.sorted()[min(values.count - 1, Int(Double(values.count) * fraction))]
    }
    var mesh: [String: Int] = [:]
    for kind in DinosaurKind.allCases {
      mesh[kind.rawValue] = DinosaurSculpture.make(.init(kind: kind, color: .pink, id: 172, juvenile: false)).combinedMesh().faceCount
    }
    let result: [String: Any] = [
      "scope": "Host optimized CPU only; excludes scene updates, perception, networking, rendering and GPU",
      "sixteen_dinosaur_motors_p95_ms": percentile(physics, 0.95),
      "giant_terrain_movement_p95_ms": percentile(giantTimes, 0.95),
      "giant_ground_probes_over_30_seconds": probes,
      "candidate_region_p95_ms": percentile(survey, 0.95),
      "candidate_region_max_ms": survey.max()!, "sites_in_441_regions": sites.count,
      "example_site_world_blocks": [Int(site.position.x),Int(site.position.y),Int(site.position.z)],
      "faces_per_adult": mesh, "motor_checksum": animals.map(\.position.z).reduce(0,+) + giant.position.z
    ]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self))
  }
}
