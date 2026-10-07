import XCTest

@testable import WorldCore

final class VisualWorldTests: XCTestCase {
  func testVoxelPlantsAreSeededAndOnlyGrowOnExposedSuitableSurfaces() {
    var chunk = ChunkData(coordinate: .init(-2, 3))
    for x in 0..<16 {
      for z in 0..<16 {
        chunk[x, 30, z] = x < 8 ? .grass : .stone
        if z == 0 { chunk[x, 31, z] = .brick }
      }
    }
    let terrain = TerrainGenerator(seed: 8192)
    let plants = SurfaceDecorationMesher.build(chunk, terrain: terrain)
    let repeated = SurfaceDecorationMesher.build(chunk, terrain: terrain)
    XCTAssertGreaterThan(plants.faceCount, 100)
    XCTAssertLessThan(plants.faceCount, 8 * 15 * 150)
    XCTAssertEqual(plants.positions, repeated.positions)
    XCTAssertEqual(plants.textureCoordinates, repeated.textureCoordinates)
    // Taller bamboo and sunflowers still remain inside their supporting column's neighborhood.
    XCTAssertTrue(plants.positions.allSatisfy { $0.x < 8.2 && $0.y >= 31 && $0.y < 33.3 })
    XCTAssertEqual(Set(plants.materials), [0])
    XCTAssertNotEqual(
      plants.positions,
      SurfaceDecorationMesher.build(chunk, terrain: .init(seed: 19)).positions)
    // Water, bare rock and covered grass cannot sprout decorative cards.
    var bare = ChunkData(coordinate: .init(0, 0))
    bare[0, 25, 0] = .water
    bare[1, 25, 0] = .stone
    bare[2, 25, 0] = .grass
    bare[2, 26, 0] = .glass
    XCTAssertTrue(SurfaceDecorationMesher.build(bare, terrain: terrain).positions.isEmpty)
  }

  func testFoliageUsesCutoutsNearbyAndOpaqueSilhouettesAtDistance() {
    var chunk = ChunkData(coordinate: .init(0, 0))
    chunk[0, 30, 0] = .cherryLeaves
    XCTAssertEqual(Set(VoxelMesher.build(chunk).materials), [4])
    XCTAssertFalse(TerrainLOD.build(chunk, sampleStride: 4).materials.contains(4))
    let blocks = VoxelMesher.build(chunk)
    var combined = blocks
    let cards = SurfaceDecorationMesher.build(chunk, terrain: .init(seed: 8192))
    combined.append(cards)
    XCTAssertEqual(combined.faceCount, blocks.faceCount + cards.faceCount)
    XCTAssertTrue(combined.indices.allSatisfy { Int($0) < combined.positions.count })
  }

  func testCloudShelvesAreStableBoundedAndHaveDistinctFaceShading() {
    let cloud = CloudMesher.build(seed: 8192)
    XCTAssertEqual(cloud.positions, CloudMesher.build(seed: 8192).positions)
    XCTAssertNotEqual(cloud.positions, CloudMesher.build(seed: 19).positions)
    XCTAssertLessThan(cloud.faceCount, 400)
    XCTAssertTrue(cloud.positions.allSatisfy { abs($0.x) <= 28 && abs($0.z) <= 28 && $0.y <= 3.2 })
    XCTAssertEqual(Set(cloud.materials), [0, 1, 2])
    XCTAssertEqual(cloud.materials.count, cloud.indices.count / 3)
  }

  func testHazePreservesForegroundAndFadesOutAboveAtmosphere() {
    XCTAssertEqual(AtmosphericPerspective.strength(distance: 40, altitude: 30), 0)
    let middle = AtmosphericPerspective.strength(distance: 256, altitude: 30)
    let far = AtmosphericPerspective.strength(distance: 512, altitude: 30)
    // Clearer air preserves detail across the extended kilometre horizon.
    XCTAssertGreaterThan(middle, 0.20)
    XCTAssertLessThan(middle, 0.35)
    XCTAssertGreaterThan(far, middle)
    XCTAssertLessThan(far, 1)
    XCTAssertGreaterThan(AtmosphericPerspective.strength(distance: 512, altitude: 300), 0)
    XCTAssertEqual(AtmosphericPerspective.strength(distance: 512, altitude: SolarSystem.departureAltitude+128), 0)
    let day = AtmosphericPerspective.color(environment: .init(elapsed: 600), style: .verdant)
    let sunset = AtmosphericPerspective.color(environment: .init(elapsed: 900), style: .verdant)
    let night = AtmosphericPerspective.color(environment: .init(elapsed: 0), style: .verdant)
    XCTAssertGreaterThan(day.z, day.x)
    XCTAssertGreaterThan(sunset.x, sunset.z)
    XCTAssertLessThan(night.z, day.z)
    XCTAssertNotEqual(day, AtmosphericPerspective.color(environment: .init(elapsed: 600), style: .aurora))
  }
}
