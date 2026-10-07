import XCTest
@testable import WorldCore

final class CaveColumnTests: XCTestCase {
  func testBulkColumnsMatchScalarAcrossSeedsLayersEntrancesAndWater() {
    let coordinates = [-1_000_003, -97, -49, -48, -47, -26, -25, -24, -1, 0, 1, 20, 21, 24, 25, 26, 47, 48, 49, 97, 1_000_003]
    let heights = [ChunkData.minimumY - 2, -60, -55, -20, 0, 23, 28, 29, 35, 63, 127, 160]
    for seed: UInt64 in [0, 17, 8192, 1667327165707871140, UInt64.max] {
      let caves = CaveGenerator(seed: seed)
      for x in coordinates {
        let z = x * 17 + 7
        for surface in heights {
          for wet in [false, true] {
            let column = caves.column(x: x, z: z, surface: surface, waterCovered: wet)
            for y in ChunkData.minimumY..<ChunkData.height {
              XCTAssertEqual(column.isCarved(y: y), caves.isCarved(at: .init(x, y, z), surface: surface, waterCovered: wet),
                "seed=\(seed) position=\(x),\(y),\(z) surface=\(surface) wet=\(wet)")
            }
            XCTAssertFalse(column.isCarved(y: ChunkData.minimumY - 1))
            XCTAssertFalse(column.isCarved(y: ChunkData.height))
          }
        }
      }
    }
  }

  func testGeneratedCellsHaloAndEditsAreIdenticalForBothCaveAlgorithms() {
    for style in PlanetStyle.allCases {
      let bulk = TerrainGenerator(seed: 8192, style: style), scalar = TerrainGenerator(seed: 8192, style: style, bulkCaves: false)
      for coordinate in [ChunkCoordinate(6, -3), .init(7, -3), .init(-17, 16), .init(0, 0)] {
        let p = BlockPosition(coordinate.x * 16, -25, coordinate.z * 16)
        let edits: [BlockPosition: Block] = [p: .glass, p + .init(0, 1, 0): .air,
          p + .init(-1, 0, 1): .stone, .init(p.x + 8, 80, p.z + 8): .wood]
        let a = bulk.generate(coordinate, edits: edits), b = scalar.generate(coordinate, edits: edits)
        XCTAssertEqual(a.archiveCells, b.archiveCells)
        XCTAssertEqual(a.maximumFilledY, b.maximumFilledY)
      }
    }
  }

  func testDisablingCavesStillBypassesCarvingAndColumnStorageIsBounded() {
    let bulk = TerrainGenerator(seed: 8192), scalar = TerrainGenerator(seed: 8192, bulkCaves: false)
    let coordinate = ChunkCoordinate(6, -3)
    XCTAssertEqual(bulk.generate(coordinate, includeCaves: false).archiveCells,
      scalar.generate(coordinate, includeCaves: false).archiveCells)
    XCTAssertNotEqual(bulk.generate(coordinate, includeCaves: false).archiveCells,
      bulk.generate(coordinate).archiveCells)
    XCTAssertLessThanOrEqual(MemoryLayout<CaveGenerator.Column>.stride, 32)
  }

  func testCaveAlgorithmPreservesCacheIdentityAndCompletePreparedArchive() throws {
    let tile = TerrainTile(x: 6, z: -3, fullDetail: true)
    let p = BlockPosition(104, -25, -40)
    let id = TerrainWorkID(world: UUID(), tile: tile, revision: 2, lush: false, repeatAtlas: true)
    let a = TerrainPreparationRequest(id: id, terrain: .init(seed: 8192), edits: [p: .glass], service: .detail, priority: 0)
    let b = TerrainPreparationRequest(id: id, terrain: .init(seed: 8192, bulkCaves: false), edits: [p: .glass], service: .detail, priority: 0)
    XCTAssertEqual(TerrainPayloadKey(a), TerrainPayloadKey(b))
    // Supplied authoritative snapshots bypass shared payload-cache reuse.
    func prepared(_ r: TerrainPreparationRequest) -> PreparedTerrainTile {
      TerrainPreparation.build(.init(id: r.id, terrain: r.terrain, edits: r.edits,
        cachedChunk: r.terrain.generate(tile.coordinate, edits: r.edits), service: .detail, priority: 0), collision: { _ in })!
    }
    let first = prepared(a), second = prepared(b)
    XCTAssertEqual(try XCTUnwrap(TerrainPayloadCodec.encode(first, key: .init(a))),
      try XCTUnwrap(TerrainPayloadCodec.encode(second, key: .init(b))))
  }

  func testDistantSolidEditsHaveStableMeshOrderAndTargetedCacheInvalidation() {
    let tile = TerrainTile(x: -4, z: -4, size: 4), terrain = TerrainGenerator(seed: 8192, style: .dune)
    let entries: [(BlockPosition, Block)] = [(.init(-62, 100, -62), .wood), (.init(-58, 103, -60), .brick),
      (.init(-59, 101, -62), .glass), (.init(-64, 25, -64), .air)]
    var expected: [UInt8]?
    for rotation in 0..<entries.count {
      var edits: [BlockPosition: Block] = [:]
      for i in entries.indices { let e = entries[(i + rotation) % entries.count]; edits[e.0] = e.1 }
      let surface = TerrainSurface.build(tile, terrain: terrain, edits: edits, measureError: false)
      let packed = PackedTerrainMesh(surface.mesh)
      let bytes = packed.vertices.withUnsafeBytes { Array($0) } + packed.indices.withUnsafeBytes { Array($0) }
      if let expected { XCTAssertEqual(bytes, expected) } else { expected = bytes }
      let request = TerrainPreparationRequest(id: .init(world: UUID(), tile: tile, revision: 0, lush: false),
        terrain: terrain, edits: edits, service: .refinement, priority: 0)
      XCTAssertEqual(TerrainPayloadKey(request).representationVersion, 14)
    }
    for profile in [false, true] {
      let addition = TerrainPreparationRequest(id: .init(world: UUID(), tile: tile, revision: 0, lush: false, profileSurface: profile),
        terrain: terrain, edits: [.init(-62, 100, -62): .wood], service: .refinement, priority: 0)
      XCTAssertEqual(TerrainPayloadKey(addition).representationVersion, profile ? 16 : 14)
      for edits: [BlockPosition: Block] in [[:], [.init(-62, 20, -62): .air], [.init(500, 90, 500): .wood]] {
        let request = TerrainPreparationRequest(id: .init(world: UUID(), tile: tile, revision: 0, lush: false, profileSurface: profile),
          terrain: terrain, edits: edits, service: .refinement, priority: 0)
        XCTAssertEqual(TerrainPayloadKey(request).representationVersion, profile ? 15 : 13)
      }
    }
  }
}
