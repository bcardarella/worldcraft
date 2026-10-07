import XCTest
@testable import WorldCore

final class GreedyTerrainTests: XCTestCase {
  // Expand each merged rectangle back into unit faces. Include vertex order,
  // normals, material and all UV corners in the multiset, not just total area.
  private func faces(_ mesh: VoxelMesh) -> [[Int]: Int] {
    var result: [[Int]: Int] = [:]
    for start in stride(from: 0, to: mesh.positions.count, by: 4) {
      let repeated = mesh.materials[start / 2] == 6
      let width = repeated ? Int(mesh.textureCoordinates[start + 3].x) : 1
      let height = repeated ? Int(mesh.textureCoordinates[start + 1].y) : 1
      let du = (mesh.positions[start + 3] - mesh.positions[start]) / Float(width)
      let dv = (mesh.positions[start + 1] - mesh.positions[start]) / Float(height)
      for y in 0..<height { for x in 0..<width {
        let origin = mesh.positions[start] + Float(x) * du + Float(y) * dv
        let positions = repeated ? [origin, origin + dv, origin + du + dv, origin + du]
          : Array(mesh.positions[start..<(start + 4)])
        let uvs: [SIMD2<Float>]
        if repeated {
          let origin = TerrainAtlas.origin(tile: Int(mesh.repeatingAtlasTiles[start / 4]))
          let span = TerrainAtlas.repeatSpan
          uvs = [origin, origin + [0, span.y], origin + span, origin + [span.x, 0]]
        } else { uvs = Array(mesh.textureCoordinates[start..<(start + 4)]) }
        var signature = [Int(repeated ? 0 : mesh.materials[start / 2])]
        let n = mesh.normals[start]
        for i in 0..<4 {
          for value in [positions[i].x, positions[i].y, positions[i].z,
                        n.x, n.y, n.z, uvs[i].x, uvs[i].y] {
            signature.append(Int((value * 100_000).rounded()))
          }
        }
        result[signature, default: 0] += 1
      } }
    }
    return result
  }

  private func equivalent(_ chunk: ChunkData, file: StaticString = #filePath, line: UInt = #line) {
    let original = VoxelMesher.build(chunk, includeWater: false)
    let merged = VoxelMesher.build(chunk, includeWater: false, repeatAtlas: true)
    XCTAssertEqual(faces(original), faces(merged), file: file, line: line)
    XCTAssertEqual(original.lampPositions, merged.lampPositions, file: file, line: line)
    XCTAssertEqual(original.firePositions, merged.firePositions, file: file, line: line)
    for start in stride(from: 0, to: merged.indices.count, by: 3) {
      let a = Int(merged.indices[start]), b = Int(merged.indices[start + 1]), c = Int(merged.indices[start + 2])
      let u = merged.positions[b] - merged.positions[a], v = merged.positions[c] - merged.positions[a]
      let cross = SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
      let normal = merged.normals[a]
      XCTAssertGreaterThan(cross.x * normal.x + cross.y * normal.y + cross.z * normal.z, 0, file: file, line: line)
    }
  }

  func testFlatRoadCollapsesToSixQuadsWithoutLosingAnyFacesOrChangingUVs() {
    var chunk = ChunkData(coordinate: .init(-1, -2))
    for y in 4..<8 { for z in 0..<16 { for x in 0..<16 { chunk[x, y, z] = .stone } } }
    let original = VoxelMesher.build(chunk), greedy = VoxelMesher.build(chunk, repeatAtlas: true)
    XCTAssertEqual(greedy.faceCount, 6)
    XCTAssertLessThan(PackedTerrainMesh(greedy).byteCount * 100, PackedTerrainMesh(original).byteCount)
    equivalent(chunk)
  }

  func testFacesStayEquivalentAcrossMaterialsContactShadowsHolesAndChunkBorders() {
    var chunk = ChunkData(coordinate: .init(-17, 32))
    let choices: [Block] = [.stone, .grass, .dirt, .wood, .birchWood, .brick, .sand, .snow]
    for z in -1...16 { for x in -1...16 {
      chunk[x, 20, z] = choices[abs(x + z * 3) % choices.count]
      if (x * x + z * 5) % 9 == 0 { chunk[x, 21, z] = .stone }
      if (x + z * 2) % 7 == 0 { chunk[x, 20, z] = .air }
    } }
    for y in 21..<30 { chunk[15, y, 3] = .limestone; chunk[16, y, 3] = .limestone }
    equivalent(chunk)
  }

  func testFullVerticalRangeAndWorldFloorHaveEquivalentCoverage() {
    var chunk = ChunkData(coordinate: .init(0, 0))
    for y in ChunkData.minimumY..<ChunkData.height { chunk[3, y, 5] = .stone }
    let mesh = VoxelMesher.build(chunk, repeatAtlas: true)
    XCTAssertEqual(mesh.faceCount, 5)
    equivalent(chunk)
  }

  func testSpecialShapesGlassLiquidsFoliageAndFixturesAreUnchanged() {
    var chunk = ChunkData(coordinate: .init(0, 0))
    for (i, block) in Block.allCases.enumerated() {
      chunk[(i % 5) * 3, 2 + (i / 25) * 4, ((i / 5) % 5) * 3] = block
    }
    equivalent(chunk)
    let mesh = VoxelMesher.build(chunk, repeatAtlas: true)
    XCTAssertEqual(faces(VoxelMesher.build(chunk)), faces(mesh))
    let packed = PackedTerrainMesh(mesh), split = packed.separatingWind()
    XCTAssertFalse(split.stationary.parts.filter { $0.material == 6 }.isEmpty)
    XCTAssertTrue(split.animated!.parts.allSatisfy { $0.material == 4 })
    XCTAssertTrue(split.stationary.vertices.allSatisfy { $0.normal.w == 0 })
  }

  func testProceduralSurfaceEquivalenceIncludesCavesTreesAndEditsOnEveryPlanetStyle() {
    for style in PlanetStyle.allCases {
      let terrain = TerrainGenerator(seed: 1667327165707871140, style: style)
      for coordinate in [ChunkCoordinate(19, 51), .init(-2, -3)] {
        let origin = BlockPosition(coordinate.x * 16, 24, coordinate.z * 16)
        equivalent(terrain.generate(coordinate, edits: [origin: .air, origin + .init(1, 0, 0): .brick]))
      }
    }
  }

  func testRepeatCoordinatesKeepPerBlockPaddedSamplingAndFaceOrientation() {
    for block in [Block.grass, .dirt, .stone, .wood, .birchWood, .snow] {
      for face in 0..<6 {
        let tile = TerrainAtlas.tile(block: block, face: face)
        for integer in [SIMD2<Float>(0, 0), [15, 191], [-16, -2]] {
          for fraction: SIMD2<Float> in [[0.125, 0.375], [0.875, 0.625]] {
            let sample = TerrainAtlas.textureCoordinate(tile: tile, repeatedUV: integer + fraction)
            XCTAssertEqual(sample, TerrainAtlas.origin(tile: tile) + fraction * TerrainAtlas.repeatSpan)
          }
        }
      }
    }
  }

  func testPackedMetadataAliasesOnlyUnusedHalfAndRetainsFortyByteWindABI() {
    var chunk = ChunkData(coordinate: .init(0, 0))
    chunk[0, 3, 0] = .grass; chunk[1, 3, 0] = .grass
    let mesh = VoxelMesher.build(chunk, repeatAtlas: true), packed = PackedTerrainMesh(mesh)
    XCTAssertEqual(MemoryLayout<TerrainVertex>.stride, 40)
    XCTAssertEqual(MemoryLayout<TerrainVertex>.offset(of: \TerrainVertex.tangent), 24)
    XCTAssertEqual(MemoryLayout<TerrainVertex>.offset(of: \TerrainVertex.bitangent), 32)
    XCTAssertEqual(TerrainVertex.repeatingAtlasUVOffset % 4, 0)
    packed.vertices.withUnsafeBytes { bytes in
      for (i, vertex) in packed.vertices.enumerated() {
        let tile = Float16(bitPattern: bytes.load(fromByteOffset: i * 40 + TerrainVertex.repeatingAtlasUVOffset + 2, as: UInt16.self))
        XCTAssertEqual(Float(tile), Float(mesh.repeatingAtlasTiles[i / 4]))
        XCTAssertEqual(vertex.normal.w, 0)
      }
    }
    XCTAssertEqual(packed.byteCount, packed.vertices.count * 40 + packed.indices.count * 4)
  }

  func testLegacyAndGreedyCacheKeysNeverAliasAndArchiveRetainsMetadata() throws {
    let terrain = TerrainGenerator(seed: 867), tile = TerrainTile(x: 0, z: 0, size: 1, fullDetail: true)
    let legacy = TerrainPreparationRequest(id: .init(world: UUID(), tile: tile, revision: 0, lush: false),
      terrain: terrain, service: .detail, priority: 0)
    let greedy = TerrainPreparationRequest(id: .init(world: UUID(), tile: tile, revision: 0, lush: false, repeatAtlas: true),
      terrain: terrain, service: .detail, priority: 0)
    let key = TerrainPayloadKey(greedy)
    XCTAssertNotEqual(key, TerrainPayloadKey(legacy))
    XCTAssertNotEqual(TerrainPayloadCodec.filename(key), TerrainPayloadCodec.filename(TerrainPayloadKey(legacy)))
    let original = try XCTUnwrap(TerrainPreparation.build(greedy, collision: { _ in }))
    let encoded = try XCTUnwrap(TerrainPayloadCodec.encode(original, key: key))
    let decoded = try XCTUnwrap(TerrainPayloadCodec.decode(encoded, key: key, id: greedy.id))
    XCTAssertEqual(TerrainPayloadCodec.encode(decoded, key: key), encoded)
    XCTAssertNil(TerrainPayloadCodec.decode(encoded, key: key, id: legacy.id))
    XCTAssertNil(TerrainPayloadCodec.encode(original, key: TerrainPayloadKey(legacy)))
    XCTAssertTrue(decoded.mesh.parts.contains { $0.material == 6 })
  }

  func testOpaqueFixturesAndPlantsShareOneMaterialWithoutChangingTheirAppearanceOrWind() {
    var source = SurfaceDecorationMesher.shapes[PlantKind.sunflower.rawValue]
    source.windWeights = source.positions.map { max(0, min(1, $0.y)) }
    source.appendBox(size: [0.16, 0.76, 0.16], center: [2, 4, 6], material: 0)
    let old = PackedTerrainMesh(source), new = PackedTerrainMesh(source, repeatOpaqueAtlas: true)
    XCTAssertEqual(old.parts.count, new.parts.count)
    XCTAssertEqual(old.byteCount, new.byteCount)
    XCTAssertEqual(new.parts.map(\.material), [6])
    for i in new.vertices.indices {
      XCTAssertEqual(new.vertices[i].normal, old.vertices[i].normal)
      XCTAssertEqual(new.vertices[i].px, old.vertices[i].px)
      XCTAssertEqual(new.vertices[i].py, old.vertices[i].py)
      XCTAssertEqual(new.vertices[i].pz, old.vertices[i].pz)
      for axis in 0..<3 { XCTAssertEqual(new.vertices[i].tangent[axis], old.vertices[i].tangent[axis]) }
    }
    for start in stride(from: 0, to: source.positions.count, by: 4) {
      let tile = Int(Float16(bitPattern: new.vertices[start].tangent.w))
      let fraction = SIMD2<Float>(0.375, 0.625)
      let origin = source.textureCoordinates[start]
      let uv = origin + fraction.x * (source.textureCoordinates[start + 3] - origin)
        + fraction.y * (source.textureCoordinates[start + 1] - origin)
      XCTAssertEqual(TerrainAtlas.textureCoordinate(tile: tile, repeatedUV: fraction), uv)
    }
    let oldSplit = old.separatingWind(), newSplit = new.separatingWind()
    XCTAssertEqual(oldSplit.animated?.vertices.count, newSplit.animated?.vertices.count)
    XCTAssertEqual(oldSplit.stationary.vertices.count, newSplit.stationary.vertices.count)
  }
}
