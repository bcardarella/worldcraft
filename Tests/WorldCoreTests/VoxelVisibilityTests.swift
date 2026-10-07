import XCTest
@testable import WorldCore

final class VoxelVisibilityTests: XCTestCase {
  private func same(_ a: VoxelMesh, _ b: VoxelMesh, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.positions, b.positions, file: file, line: line)
    XCTAssertEqual(a.normals, b.normals, file: file, line: line)
    XCTAssertEqual(a.textureCoordinates, b.textureCoordinates, file: file, line: line)
    XCTAssertEqual(a.indices, b.indices, file: file, line: line)
    XCTAssertEqual(a.materials, b.materials, file: file, line: line)
    XCTAssertEqual(a.repeatingAtlasTiles, b.repeatingAtlasTiles, file: file, line: line)
    XCTAssertEqual(a.windWeights, b.windWeights, file: file, line: line)
    XCTAssertEqual(a.lampPositions, b.lampPositions, file: file, line: line)
    XCTAssertEqual(a.firePositions, b.firePositions, file: file, line: line)
    for repeated in [false, true] {
      let pa = PackedTerrainMesh(a, repeatOpaqueAtlas: repeated), pb = PackedTerrainMesh(b, repeatOpaqueAtlas: repeated)
      XCTAssertEqual(pa.vertices.withUnsafeBytes { Data($0) }, pb.vertices.withUnsafeBytes { Data($0) }, file: file, line: line)
      XCTAssertEqual(pa.indices, pb.indices, file: file, line: line)
      XCTAssertEqual(pa.parts.map(\.minimum), pb.parts.map(\.minimum), file: file, line: line)
      XCTAssertEqual(pa.parts.map(\.maximum), pb.parts.map(\.maximum), file: file, line: line)
    }
  }

  func testCandidateMaskMatchesCellOracleThroughFullHeightHaloAndEveryMaterial() throws {
    var chunk = ChunkData(coordinate: .init(-31, 17))
    var random: UInt64 = 1984
    for y in ChunkData.minimumY..<ChunkData.height { for z in -1...16 { for x in -1...16 {
      random = random &* 6364136223846793005 &+ 1442695040888963407
      // Dense strata and mixed seams exercise both skipped interiors and every
      // classification, rather than a mostly transparent random volume.
      chunk[x,y,z] = y % 13 < 7 ? .stone : Block.allCases[Int(random >> 32) % Block.allCases.count]
    } } }
    for wet in [false, true] {
      let mask = try XCTUnwrap(VoxelVisibility(chunk, includeWater: wet))
      XCTAssertEqual(mask.byteCount, 16 * (ChunkData.height - ChunkData.minimumY) * 2)
      var skipped = 0
      for y in ChunkData.minimumY...chunk.maximumFilledY { for z in 0..<16 { for x in 0..<16 {
        let block = chunk[x,y,z]
        let enclosed = block.isOpaque && VoxelMesher.offsets.allSatisfy {
          chunk[x+$0.x,y+$0.y,z+$0.z].isOpaque
        }
        let expected = block != .air && (wet || !block.isLiquid) && !enclosed
        XCTAssertEqual(mask.candidates(y:y,z:z) & (1 << x) != 0, expected)
        if enclosed { skipped += 1 }
      } } }
      XCTAssertGreaterThan(skipped, 10_000)
    }
  }

  func testExactOutputOnEditedProceduralWorldsIncludingAllSixStyles() {
    for style in PlanetStyle.allCases {
      let terrain = TerrainGenerator(seed: 1667327165707871140, style: style)
      for coordinate in [ChunkCoordinate(19,51), .init(-2,-3)] {
        let o = BlockPosition(coordinate.x*16, 24, coordinate.z*16)
        let chunk = terrain.generate(coordinate, edits: [o:.air, o + .init(1,0,0):.brick,
          o + .init(-1,-3,2):.air, o + .init(16,2,0):.glass, o + .init(15,3,15):.lantern])
        for wet in [false,true] { for repeatAtlas in [false,true] {
          same(VoxelMesher.build(chunk, includeWater: wet, repeatAtlas: repeatAtlas, cullHidden: false),
            VoxelMesher.build(chunk, includeWater: wet, repeatAtlas: repeatAtlas))
        } }
      }
    }
  }

  func testEnclosedFixturesAndLiquidRoofsKeepGeometryAndEmitterOrder() throws {
    for roof in [Block.stone, .water, .lava] {
      var chunk = ChunkData(coordinate: .init(0,0))
      for y in 0...20 { for z in -1...16 { for x in -1...16 { chunk[x,y,z] = .stone } } }
      for (i,block) in Block.allCases.enumerated() {
        let x = (i % 5) * 3, z = ((i / 5) % 5) * 3, y = 2 + i / 25 * 6
        chunk[x,y,z] = block; chunk[x,y+1,z] = roof
      }
      for wet in [false,true] { for repeatAtlas in [false,true] {
        same(VoxelMesher.build(chunk, includeWater: wet, repeatAtlas: repeatAtlas, cullHidden: false),
          VoxelMesher.build(chunk, includeWater: wet, repeatAtlas: repeatAtlas))
      } }
      let mesh = VoxelMesher.build(chunk)
      XCTAssertEqual(mesh.lampPositions.count, 1)
      XCTAssertEqual(mesh.firePositions.count, roof.isLiquid ? 0 : 1)
    }
  }

  func testEmptyChunkConservativeMaximumAndWorldBorders() throws {
    var chunk = ChunkData(coordinate: .init(0,0))
    XCTAssertEqual(try XCTUnwrap(VoxelVisibility(chunk, includeWater: true)).byteCount, 0)
    XCTAssertTrue(VoxelMesher.build(chunk).positions.isEmpty)
    for y in ChunkData.minimumY..<ChunkData.height { for z in -1...16 { for x in -1...16 { chunk[x,y,z] = .stone } } }
    // Removing the highest layer leaves maximumFilledY deliberately stale.
    for z in -1...16 { for x in -1...16 { chunk[x,ChunkData.height-1,z] = .air } }
    same(VoxelMesher.build(chunk, includeWater: true, repeatAtlas: true, cullHidden: false),
      VoxelMesher.build(chunk, repeatAtlas: true))
    XCTAssertEqual(VoxelMesher.build(chunk, repeatAtlas: true).faceCount, 1)
  }

  func testCompletePreparedArchiveAndWarmCacheAreIdentical() throws {
    let terrain = TerrainGenerator(seed: 1667327165707871140, style: .verdant)
    for coordinate in [ChunkCoordinate(19,51), .init(-2,-3)] {
      let request = TerrainPreparationRequest(id: .init(world: UUID(), tile: .init(x: coordinate.x, z: coordinate.z, fullDetail:true),
        revision: 0, lush: true, repeatAtlas:true), terrain: terrain, service:.detail, priority:0)
      let cache = TerrainPayloadCache()
      let original = try XCTUnwrap(TerrainPreparation.build(request, cache: TerrainPayloadCache(), cullHidden:false, collision:{ _ in }))
      let new = try XCTUnwrap(TerrainPreparation.build(request, cache: cache, cullHidden:true, collision:{ _ in }))
      let warm = try XCTUnwrap(TerrainPreparation.build(request, cache: cache, cullHidden:false, collision:{ _ in }))
      let key = TerrainPayloadKey(request)
      XCTAssertNotNil(new.stages["meshing"])
      XCTAssertNotNil(warm.stages["memory_cache_hit"])
      XCTAssertEqual(try XCTUnwrap(TerrainPayloadCodec.encode(new,key:key)), try XCTUnwrap(TerrainPayloadCodec.encode(original,key:key)))
      XCTAssertEqual(TerrainPayloadCodec.encode(warm,key:key), TerrainPayloadCodec.encode(original,key:key))
    }
  }
}
