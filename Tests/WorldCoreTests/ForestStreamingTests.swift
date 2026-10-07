import XCTest
@testable import WorldCore

final class ForestStreamingTests: XCTestCase {
  func testDenseForestsRetainOriginalTrees() throws {
    let terrain = TerrainGenerator(seed: 8192)
    let points=stride(from:-4096,through:4096,by:128)
    let center=try XCTUnwrap(points.lazy.flatMap { x in points.map { z in BlockPosition(x,0,z) } }
      .first { terrain.biome(atX:$0.x,z:$0.z).hasDenseForest && terrain.height(atX:$0.x,z:$0.z)<49 })
    var forest = 0, originalForest = 0
    for z in center.z-256..<center.z+256 {
      for x in center.x-256..<center.x+256 {
        guard let tree = terrain.tree(atX: x, z: z) else { continue }
        let biome = terrain.biome(atX: x, z: z)
        if biome.hasDenseForest {
          forest += 1
          if terrain.hash(x, z, salt: 67) % 89 == 0 { originalForest += 1 }
        }
        XCTAssertEqual(tree.block(at: .init(x, tree.ground + 1, z)), tree.trunk)
        XCTAssertLessThan(tree.top + 2, ChunkData.height)
      }
    }
    XCTAssertGreaterThan(originalForest, 100)
    XCTAssertGreaterThan(forest, originalForest * 2)
  }

  func testMeadowTreesStaySparse() throws {
    let terrain = TerrainGenerator(seed: 8192)
    let points = stride(from: -1_800, through: 1_800, by: 64)
    let center = try XCTUnwrap(points.lazy.flatMap { x in points.map { z in BlockPosition(x, 0, z) } }
      .first { terrain.biome(atX: $0.x, z: $0.z) == .meadow })
    var trees = 0
    for z in (center.z - 64)..<(center.z + 64) {
      for x in (center.x - 64)..<(center.x + 64) {
        guard terrain.tree(atX: x, z: z) != nil, terrain.biome(atX: x, z: z) == .meadow else { continue }
        trees += 1
        XCTAssertEqual(terrain.hash(x, z, salt: 67) % 89, 0)
        XCTAssertEqual(terrain.hash(x, z, salt: 67) % 3, 0)
      }
    }
    XCTAssertGreaterThan(trees, 0)
  }

  func testForestFloorPlantsGrowBelowCanopy() {
    var chunk = ChunkData(coordinate: .init(8, 8))
    for z in -1...16 { for x in -1...16 {
      chunk[x, 10, z] = .grass
      chunk[x, 20, z] = .leaves
    } }
    let mesh = SurfaceDecorationMesher.build(chunk, terrain: .init(seed: 8192))
    XCTAssertGreaterThan(mesh.faceCount, 0)
    XCTAssertTrue(mesh.positions.allSatisfy { $0.y >= 11 && $0.y < 20 })
  }

  func testWideCanopiesAgreeAcrossChunkHalo() throws {
    let terrain = TerrainGenerator(seed: 8192)
    var checked = 0
    for x in stride(from: -4085, through: 4091, by: 16) {
      for z in -4096..<4096 {
        guard let tree = terrain.tree(atX: x, z: z),
          [.willow, .palm, .acacia].contains(tree.species) else { continue }
        let y = tree.species == .palm ? tree.top - 1 : tree.top
        let p = BlockPosition(x + 4, y, z)
        guard terrain.block(at: p) == tree.leaves else { continue }
        let coordinate = (p + .init(1, 0, 0)).chunk
        let chunk = terrain.generate(coordinate)
        XCTAssertEqual(p.x - coordinate.x * 16, -1)
        XCTAssertEqual(chunk[-1, p.y, p.z - coordinate.z * 16], terrain.block(at: p))
        checked += 1
        if checked == 8 { return }
      }
    }
    XCTAssertGreaterThan(checked, 0)
  }

  func testDetailRangeAndPredictionKeepApproachingTerrainReadyEarly() {
    let center = ChunkCoordinate(2, 2)
    let ahead = TerrainStreamingPlan.lookAhead(from: center, velocity: [43.2, 0, 0])
    XCTAssertEqual(ahead, .init(8, 2))
    XCTAssertEqual(TerrainStreamingPlan.lookAhead(from: center, velocity: .zero), center)
    let stationary = TerrainStreamingPlan(center: center, radius: 128)
    let moving = TerrainStreamingPlan(center: center, radius: 128, lookAhead: ahead)
    let approaching = ChunkCoordinate(15, 2)
    XCTAssertFalse(stationary.tiles.contains { $0.fullDetail && $0.contains(approaching) })
    XCTAssertTrue(moving.tiles.contains { $0.fullDetail && $0.contains(approaching) })
    XCTAssertTrue(moving.tiles.contains { $0.fullDetail && $0.contains(center) })
    let maximum = TerrainStreamingPlan(center: center, radius: 128, detailRadius: 16, lookAhead: ahead)
    XCTAssertLessThan(maximum.tiles.filter(\.fullDetail).count, 1_100)
    XCTAssertLessThan(maximum.tiles.count, 1_500)
    XCTAssertEqual(DrawDistance.clampDetail(-100), 6)
    XCTAssertEqual(DrawDistance.clampDetail(100), 16)
  }

  func testDetailUpgradeCompletesParentGroupBeforeUnrelatedChunks() {
    let parent = TerrainTile(x: 0, z: 0, size: 2)
    let children: Set<TerrainTile> = [.init(x: 0, z: 0, fullDetail: true),
      .init(x: 1, z: 0), .init(x: 0, z: 1), .init(x: 1, z: 1)]
    let unrelated = TerrainTile(x: 2, z: 0, fullDetail: true)
    let desired = children.union([unrelated])
    let center = ChunkCoordinate(0, 0)
    let ranks = TerrainWorkPriority.ranks(desired: desired, available: [parent],
      center: center, lookAhead: center)
    let queue = desired.sorted { TerrainWorkPriority.precedes($0, $1, ranks: ranks, center: center) }
    let completed = Set(queue.prefix(4))
    XCTAssertEqual(completed, children)
    XCTAssertEqual(TerrainCoverage(desired: desired, available: completed.union([parent])).visible, children)
  }

  func testPlantDetailUpgradesOnApproachWithHysteresis() {
    let chunk = ChunkCoordinate(6, 0)
    XCTAssertFalse(VegetationDetail.isLush(chunk, center: .init(0, 0)))
    XCTAssertTrue(VegetationDetail.isLush(chunk, center: .init(2, 0)))
    XCTAssertTrue(VegetationDetail.isLush(chunk, center: .init(1, 0), previouslyLush: true))
    XCTAssertFalse(VegetationDetail.isLush(chunk, center: .init(0, 0), previouslyLush: true))
  }

  func testMiddleDistanceTerrainKeepsFlatBlockTopsAndOutwardSteps() {
    let terrain = TerrainGenerator(seed: 8192)
    let tile = TerrainTile(x: 8, z: 8, size: 2)
    let mesh = TerrainSurface.build(tile, terrain: terrain).mesh
    let side = tile.blockSize / tile.sampleStride
    XCTAssertEqual(tile.sampleStride, 1)
    for face in 0..<(side * side) {
      let vertices = mesh.positions[(face * 4)..<(face * 4 + 4)]
      XCTAssertEqual(Set(vertices.map(\.y)).count, 1)
      XCTAssertEqual(mesh.normals[face * 4], [0, 1, 0])
    }
    for face in 0..<mesh.faceCount {
      let i = face * 4
      let normal = cross(mesh.positions[i + 1] - mesh.positions[i], mesh.positions[i + 2] - mesh.positions[i])
      let outward = mesh.normals[i]
      XCTAssertGreaterThan(normal.x * outward.x + normal.y * outward.y + normal.z * outward.z, 0)
    }
  }
}
