import XCTest
import simd

@testable import WorldCore

final class DrainageTests: XCTestCase {
  private let terrain = TerrainGenerator(seed: 8192)

  private func network() -> (rivers: [ChunkCoordinate: RiverReach], lakes: [UInt64: InlandLake]) {
    var rivers: [ChunkCoordinate: RiverReach] = [:]
    var lakes: [UInt64: InlandLake] = [:]
    for x in -6...6 {
      for z in -6...6 {
        let patch = WorldDrainage.patch(atX: x * 512, z: z * 512, terrain: terrain)
        for reach in patch.rivers { rivers[reach.origin] = reach }
        for lake in patch.lakes { lakes[lake.id] = lake }
      }
    }
    return (rivers, lakes)
  }

  func testOceansSpanKilometresAndLakesAreBroadDeepBasins() throws {
    // Sample a much larger area than the view radius: geography must not depend
    // on render settings. Four-connected cells exclude isolated coastal ponds.
    var ocean = Set<ChunkCoordinate>()
    for x in -32...32 {
      for z in -32...32 {
        if terrain.rawHeight(atX: x * 256, z: z * 256) < TerrainGenerator.seaLevel - 2 {
          ocean.insert(.init(x, z))
        }
      }
    }
    var largest = 0
    var longest: Float = 0
    while let start = ocean.first {
      var queue = [start]
      var cursor = 0
      ocean.remove(start)
      var low = start
      var high = start
      while cursor < queue.count {
        let p = queue[cursor]
        cursor += 1
        low = .init(min(low.x, p.x), min(low.z, p.z))
        high = .init(max(high.x, p.x), max(high.z, p.z))
        for q in [
          ChunkCoordinate(p.x - 1, p.z), .init(p.x + 1, p.z), .init(p.x, p.z - 1),
          .init(p.x, p.z + 1),
        ] {
          if ocean.remove(q) != nil { queue.append(q) }
        }
      }
      largest = max(largest, queue.count)
      longest = max(longest, Float(max(high.x - low.x, high.z - low.z)) * 128)
    }
    XCTAssertGreaterThan(largest * 128 * 128, 500_000)
    XCTAssertGreaterThan(longest, 1_500)
    let lakes = network().lakes.values
    XCTAssertGreaterThan(lakes.count, 4)
    for lake in lakes {
      XCTAssertGreaterThanOrEqual(min(lake.radiusX, lake.radiusZ), 160)  // full width in metres
      let center = terrain.column(atX: lake.x, z: lake.z)
      XCTAssertEqual(center.water?.kind, .lake)
      XCTAssertGreaterThan(lake.body.level - Float(center.height), 16)
      XCTAssertEqual(center.surface, .sand)
    }
  }

  func testMountainTributariesMergeAndDescendToLakesAndOceans() throws {
    let rivers = network().rivers
    XCTAssertGreaterThan(rivers.count, 20)
    XCTAssertTrue(rivers.values.contains { $0.points.first!.y >= 58 })
    XCTAssertTrue(rivers.values.contains(where: \.endsInLake))
    XCTAssertTrue(rivers.values.contains(where: \.endsInOcean))
    let junctions = Dictionary(grouping: rivers.values, by: \.destination).filter {
      $0.value.count > 1
    }
    XCTAssertGreaterThanOrEqual(junctions.count, 2)
    for reach in rivers.values {
      for pair in zip(reach.points, reach.points.dropFirst()) {
        XCTAssertGreaterThanOrEqual(pair.0.y, pair.1.y)
      }
      if let downstream = rivers[reach.destination] {
        XCTAssertEqual(reach.points.last!, downstream.points.first!)
        XCTAssertEqual(reach.id, downstream.id)
        XCTAssertGreaterThan(downstream.catchment, reach.catchment)
        XCTAssertGreaterThanOrEqual(downstream.halfWidth, reach.halfWidth)
      }
      var seen = Set<ChunkCoordinate>()
      var current: RiverReach? = reach
      while let step = current {
        XCTAssertTrue(seen.insert(step.origin).inserted, "Drainage cycle")
        if seen.count > rivers.count { break }
        current = rivers[step.destination]
      }
    }
  }

  func testLakeInletsOutletsAndConfluencesHaveContinuousOpenWater() {
    let plan = network()
    var inlets = 0
    var outlets = 0
    for reach in plan.rivers.values {
      let touching = plan.lakes.values.filter { lake in
        lake.distance(x: Int(reach.points.first!.x), z: Int(reach.points.first!.z)) < 1
          || lake.distance(x: Int(reach.points.last!.x), z: Int(reach.points.last!.z)) < 1
      }
      for lake in touching {
        let source = lake.distance(x: Int(reach.points.first!.x), z: Int(reach.points.first!.z)) < 1
        if source { outlets += 1 } else { inlets += 1 }
        for pair in zip(reach.points, reach.points.dropFirst()) {
          let steps = max(1, Int(ceil(simd_distance(pair.0, pair.1))))
          for i in 0...steps {
            let p = pair.0 + (pair.1 - pair.0) * Float(i) / Float(steps)
            let x = Int(p.x.rounded())
            let z = Int(p.z.rounded())
            let distance = lake.distance(x: x, z: z)
            guard distance < 1.15 else { continue }
            let column = terrain.column(atX: x, z: z)
            XCTAssertNotNil(column.water, "Dry channel at \(x),\(z)")
            XCTAssertLessThan(Float(column.height) + 1, column.water?.level ?? 0)
            if distance < 1.02 {
              XCTAssertEqual(column.water?.level ?? 0, lake.body.level, accuracy: 0.25)
            }
          }
        }
      }
    }
    XCTAssertGreaterThan(inlets, 0)
    XCTAssertGreaterThan(outlets, 0)
  }

  func testPatchBoundariesAgreeAndCurrentFollowsTheChannel() {
    let rivers = network().rivers
    var crossings = 0
    for reach in rivers.values {
      for pair in zip(reach.points, reach.points.dropFirst()) {
        let a = BlockPosition(pair.0)
        let b = BlockPosition(pair.1)
        guard
          floorDivide(a.x, by: 512) != floorDivide(b.x, by: 512)
            || floorDivide(a.z, by: 512) != floorDivide(b.z, by: 512)
        else { continue }
        let p = (pair.0 + pair.1) * 0.5
        let left = WorldDrainage.patch(atX: a.x, z: a.z, terrain: terrain).river(atX: p.x, z: p.z)
        let right = WorldDrainage.patch(atX: b.x, z: b.z, terrain: terrain).river(atX: p.x, z: p.z)
        XCTAssertEqual(left?.body, right?.body)
        XCTAssertEqual(left?.bed, right?.bed)
        if let current = left?.current {
          XCTAssertGreaterThan(simd_dot(current, pair.1 - pair.0), 0)
        }
        crossings += 1
      }
    }
    XCTAssertGreaterThan(crossings, 10)
  }

  func testEveryMountainChannelUltimatelyReachesALakeOrOcean() {
    for seed: UInt64 in [8192, 42, 967_252_643] {
      let terrain = TerrainGenerator(seed: seed)
      for x in -4...4 {
        for z in -4...4 {
          let patch = WorldDrainage.patch(atX: x * 512, z: z * 512, terrain: terrain)
          for origin in patch.rivers {
            var river = origin
            var seen = Set<ChunkCoordinate>()
            while !river.endsInLake && !river.endsInOcean {
              guard seen.insert(river.origin).inserted, seen.count < 256 else {
                XCTFail("River never reaches a water body")
                break
              }
              let next = WorldDrainage.patch(
                atX: river.destination.x * 512, z: river.destination.z * 512, terrain: terrain)
              guard let downstream = next.rivers.first(where: { $0.origin == river.destination })
              else {
                XCTFail("Channel ends on dry ground at \(river.destination), seed \(seed)")
                break
              }
              XCTAssertEqual(river.points.last, downstream.points.first)
              river = downstream
            }
          }
        }
      }
    }
  }

  func testFractionalRiverSurfaceHasTheSameWetVoxelsAsCollisionQueries() {
    var checked = 0
    for river in network().rivers.values.sorted(by: {
      ($0.origin.x, $0.origin.z) < ($1.origin.x, $1.origin.z)
    }) {
      for point in river.points {
        let p = BlockPosition(point)
        let column = terrain.column(atX: p.x, z: p.z)
        guard let water = column.water, water.kind == .river,
          water.level - water.level.rounded(.down) > 0.15,
          water.level - water.level.rounded(.down) < 0.85
        else { continue }
        let surface = BlockPosition(p.x, Int(ceil(water.level)) - 1, p.z)
        guard terrain.block(at: surface) == .water else { continue }
        let chunk = terrain.generate(surface.chunk)
        XCTAssertEqual(
          chunk[surface.x - surface.chunk.x * 16, surface.y, surface.z - surface.chunk.z * 16],
          .water)
        checked += 1
        if checked == 4 { return }
      }
    }
    XCTAssertEqual(checked, 4)
  }

  func testSettlementsAndLandmarksDoNotDamTheChannels() {
    var checked = 0
    for river in network().rivers.values {
      for index in stride(from: 0, to: river.points.count - 1, by: 4) {
        let point = river.points[index]
        let delta = river.points[index + 1] - point
        let perpendicular = simd_normalize(SIMD2(-delta.z, delta.x)) * 3
        let open = [Float(-1), 0, 1].contains { offset in
          let x = Int(point.x + perpendicular.x * offset)
          let z = Int(point.z + perpendicular.y * offset)
          guard let water = terrain.column(atX: x, z: z).water else { return false }
          return terrain.block(at: .init(x, Int(ceil(water.level)) - 1, z)) == .water
        }
        XCTAssertTrue(open, "Waterway blocked near \(point)")
        checked += 1
      }
    }
    XCTAssertGreaterThan(checked, 100)
  }
}
