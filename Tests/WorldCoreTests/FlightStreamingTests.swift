import XCTest
@testable import WorldCore

final class FlightStreamingTests: XCTestCase {
  func testCanceledWorkersKeepCapacityUntilTheyActuallyFinish() throws {
    var slots = PreparationSlots<Int>(limit: 2)
    let first = try XCTUnwrap(slots.reserve(1)), second = try XCTUnwrap(slots.reserve(2))
    slots.invalidate(1); slots.invalidate(2)
    for key in 3..<10_000 { XCTAssertNil(slots.reserve(key)) }
    XCTAssertEqual(slots.count, 2)
    XCTAssertFalse(slots.isCurrent(first))
    slots.finish(first)
    let replacement = try XCTUnwrap(slots.reserve(1))
    slots.finish(first) // Duplicate/stale completion cannot release the replacement.
    XCTAssertTrue(slots.isCurrent(replacement)); XCTAssertEqual(slots.count, 2)
    slots.finish(second); slots.finish(replacement)
    XCTAssertEqual(slots.available, 2)
  }

  func testPlanetResetCannotBypassWorkerLimitOrPublishOldResult() throws {
    var slots = PreparationSlots<Int>(limit: 2)
    let old = try XCTUnwrap(slots.reserve(1))
    slots.invalidateAll()
    let next = try XCTUnwrap(slots.reserve(1))
    XCTAssertFalse(slots.isCurrent(old)); XCTAssertTrue(slots.isCurrent(next))
    XCTAssertNil(slots.reserve(2))
    slots.finish(old)
    XCTAssertTrue(slots.contains(1)); XCTAssertTrue(slots.isCurrent(next))
    slots.finish(next)
    XCTAssertEqual(slots.count, 0)
  }

  func testWindSplitPreservesEveryTriangleAttributeAndMaterial() {
    var source = VoxelMesh()
    source.appendBox(size: [5, 1, 5], center: .zero, material: 0)
    source.appendBox(size: [1, 4, 1], center: [0, 2, 0], material: 0)
    source.appendBox(size: [3, 3, 3], center: [0, 5, 0], material: 4)
    source.appendBox(size: [0.1, 1, 0.1], center: [3, 1, 0], material: 0)
    source.windWeights = Array(repeating: 0, count: source.positions.count)
    for i in (source.positions.count - 24)..<source.positions.count {
      source.windWeights[i] = source.positions[i].y > 1 ? 1 : 0
    }
    let packed = PackedTerrainMesh(source), split = packed.separatingWind()
    let animated = try! XCTUnwrap(split.animated)
    func triangles(_ mesh: PackedTerrainMesh) -> [[UInt32]: Int] {
      var result: [[UInt32]: Int] = [:]
      for part in mesh.parts {
        for start in stride(from: part.offset, to: part.offset + part.count, by: 3) {
          var signature = [UInt32(part.material)]
          for index in mesh.indices[start..<(start + 3)] {
            let v = mesh.vertices[Int(index)]
            signature += [v.px.bitPattern, v.py.bitPattern, v.pz.bitPattern, UInt32(v.u), UInt32(v.v)]
            for axis in 0..<4 { signature += [UInt32(v.normal[axis]), UInt32(v.tangent[axis]), UInt32(v.bitangent[axis])] }
            XCTAssertGreaterThanOrEqual(v.px, part.minimum.x); XCTAssertLessThanOrEqual(v.px, part.maximum.x)
            XCTAssertGreaterThanOrEqual(v.py, part.minimum.y); XCTAssertLessThanOrEqual(v.py, part.maximum.y)
            XCTAssertGreaterThanOrEqual(v.pz, part.minimum.z); XCTAssertLessThanOrEqual(v.pz, part.maximum.z)
          }
          result[signature, default: 0] += 1
        }
      }
      return result
    }
    XCTAssertEqual(triangles(packed), triangles(split.stationary).merging(triangles(animated), uniquingKeysWith: +))
    XCTAssertTrue(split.stationary.vertices.allSatisfy { $0.normal.w == 0 })
    XCTAssertLessThan(animated.vertices.count, packed.vertices.count)
    XCTAssertNil(split.stationary.separatingWind().animated)
    XCTAssertNil(PackedTerrainMesh(VoxelMesh()).separatingWind().animated)
  }

  func testForestWindUploadsExcludeStationaryTerrain() {
    let terrain = TerrainGenerator(seed: 1667327165707871140)
    var total = 0, moving = 0
    for coordinate in [ChunkCoordinate(18,51), .init(19,51), .init(19,52), .init(20,52)] {
      let chunk = terrain.generate(coordinate)
      var source = VoxelMesher.build(chunk, includeWater: false)
      let plants = SurfaceDecorationMesher.instances(in: chunk, terrain: terrain, lush: true, changes: [:])
      source.append(SurfaceDecorationMesher.mesh(plants, chunk: coordinate))
      let mesh = PackedTerrainMesh(source), split = mesh.separatingWind()
      XCTAssertEqual(mesh.indices.count, split.stationary.indices.count + (split.animated?.indices.count ?? 0))
      total += mesh.vertices.count; moving += split.animated?.vertices.count ?? 0
    }
    XCTAssertGreaterThan(total, 0)
    XCTAssertLessThan(moving, total)
    print("WORLDCRAFT_WIND_FIXTURE original_vertices=\(total) animated_vertices=\(moving) bytes_per_vertex=40")
  }
}
