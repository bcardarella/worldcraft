import CryptoKit
import simd
import XCTest
@testable import WorldCore

final class StadiumSeatInstanceTests: XCTestCase {
  private func expanded(_ mesh: VoxelMesh) -> VoxelMesh {
    var result = mesh; result.stadiumSeats = []
    for seat in mesh.stadiumSeats {
      var template = SportsGroundMesher.seatTemplate(color: seat.color)
      template.positions = template.positions.map { (seat.transform * SIMD4($0, 1)).xyz }
      template.normals = template.normals.map { (seat.transform * SIMD4($0, 0)).xyz }
      result.append(template)
    }
    return result
  }
  private func sameSurface(_ a: VoxelMesh, _ b: VoxelMesh, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.indices.count, b.indices.count, file: file, line: line)
    XCTAssertEqual(a.positions.count, b.positions.count, file: file, line: line)
    // Spatial buckets avoid order dependence. Search adjacent buckets at rounding
    // boundaries, then compare all four corners and attributes, not only area.
    func cell(_ p: SIMD3<Float>) -> SIMD3<Int> { .init(Int(floor(p.x * 4)), Int(floor(p.y * 4)), Int(floor(p.z * 4))) }
    var quads: [SIMD3<Int>: [Int]] = [:]
    for i in stride(from: 0, to: a.positions.count, by: 4) { quads[cell(a.positions[i]), default: []].append(i) }
    for i in stride(from: 0, to: b.positions.count, by: 4) {
      let key = cell(b.positions[i])
      var matched = false
      search: for x in -1...1 { for y in -1...1 { for z in -1...1 {
        let bucket = key &+ SIMD3(x, y, z)
        guard let candidates = quads[bucket] else { continue }
        for (index, j) in candidates.enumerated() where a.materials[j / 2] == b.materials[i / 2] {
          let same = (0..<4).allSatisfy {
            simd_distance(a.positions[j + $0], b.positions[i + $0]) < 0.0005
              && simd_distance(a.normals[j + $0], b.normals[i + $0]) < 0.002
              && a.textureCoordinates[j + $0] == b.textureCoordinates[i + $0]
          }
          if same { quads[bucket]?.remove(at: index); matched = true; break search }
        }
      } } }
      if !matched { XCTFail("Missing quad at \(b.positions[i])", file: file, line: line); return }
    }
    XCTAssertTrue(quads.values.allSatisfy(\.isEmpty), file: file, line: line)
  }

  func testExtractionPreservesWindingUVsColorsAndSeamsInBothWingsAndCorner() throws {
    var count = 0
    for (x, z) in [(0, 0), (-513, -897)] {
      let site = Settlement(id: 1, kind: .city, name: "Seats", x: x, z: z, floor: 30, ground: .grass)
      let field = site.sportsGrounds[1], stadium = try XCTUnwrap(field.stadium)
      let points = [stadium.point(along: 40, depth: 35, y: 0),
        stadium.point(along: 85, depth: 61, y: 0, thirdBase: true),
        SIMD3(field.homePlate.x - 39, 0, field.homePlate.y + 32)]
      for point in points {
        let chunk = BlockPosition(point).chunk
        for offset in [ChunkCoordinate(0, 0), .init(1, 0)] {
          let tile = TerrainTile(x: chunk.x + offset.x, z: chunk.z + offset.z, fullDetail: true)
          let baked = SportsGroundMesher.build(field, floor: site.floor, tile: tile)
          let instanced = SportsGroundMesher.build(field, floor: site.floor, tile: tile, instanceSeats: true)
          count += instanced.stadiumSeats.count
          XCTAssertTrue(instanced.stadiumSeats.allSatisfy { $0.isValid(in: tile) })
          XCTAssertEqual(baked.positions.count, instanced.positions.count + instanced.stadiumSeats.count * 72)
          sameSurface(baked, expanded(instanced))
        }
      }
    }
    XCTAssertGreaterThan(count, 50)
  }

  func testCoarseRepresentationsAndNonStadiumFieldsStayIdentical() {
    let city = Settlement(id: 1, kind: .city, name: "Seats", x: 0, z: 0, floor: 30, ground: .grass)
    for field in city.sportsGrounds {
      for size in [1, 2, 4, 16, 32] {
        let tile = TerrainTile(x: floorDivide(Int(field.center.x), by: 16 * size) * size,
          z: floorDivide(Int(field.center.y), by: 16 * size) * size, size: size)
        let baked = SportsGroundMesher.build(field, floor: city.floor, tile: tile)
        let enabled = SportsGroundMesher.build(field, floor: city.floor, tile: tile, instanceSeats: true)
        XCTAssertTrue(enabled.stadiumSeats.isEmpty)
        XCTAssertEqual(baked.positions, enabled.positions); XCTAssertEqual(baked.indices, enabled.indices)
      }
    }
  }

  func testSharedPackedTemplatePreservesTangentBasisBothMaterialPathsAndBounds() {
    for color: UInt8 in [13, 21] { for repeating in [false, true] {
      let packed = StadiumSeatInstance.template(color: color, repeatAtlas: repeating)
      XCTAssertEqual(packed.vertices.count, 72); XCTAssertEqual(packed.indices.count, 108)
      XCTAssertEqual(packed.parts.map(\.material), [repeating ? 6 : 0])
      let directions: [SIMD2<Float>] = [[1, 0], [0, -1], simd_normalize(SIMD2<Float>(0.37, -0.85))]
      for forward in directions {
        let seat = StadiumSeatInstance(position: [8, 30, 8], forward: forward, color: color)
        var expanded = SportsGroundMesher.seatTemplate(color: color)
        expanded.positions = expanded.positions.map { (seat.transform * SIMD4($0, 1)).xyz }
        expanded.normals = expanded.normals.map { (seat.transform * SIMD4($0, 0)).xyz }
        let baked = PackedTerrainMesh(expanded, repeatOpaqueAtlas: repeating)
        for (v, original) in zip(packed.vertices, baked.vertices) {
          let p = (seat.transform * SIMD4(v.px, v.py, v.pz, 1)).xyz
          XCTAssertTrue(all(p .>= seat.minimum)); XCTAssertTrue(all(p .<= seat.maximum))
          func vector(_ v: SIMD4<UInt16>) -> SIMD3<Float> {
            (seat.transform * SIMD4(Float(Float16(bitPattern: v.x)), Float(Float16(bitPattern: v.y)),
              Float(Float16(bitPattern: v.z)), 0)).xyz
          }
          let n = vector(v.normal), t = vector(v.tangent), b = vector(v.bitangent)
          XCTAssertEqual(simd_length(n), 1, accuracy: 0.001)
          XCTAssertEqual(simd_dot(n, t), 0, accuracy: 0.001)
          XCTAssertEqual(simd_dot(n, b), 0, accuracy: 0.001)
          XCTAssertLessThan(simd_distance(p, SIMD3(original.px, original.py, original.pz)), 0.00001)
          XCTAssertEqual(v.u, original.u); XCTAssertEqual(v.v, original.v)
          XCTAssertEqual(v.normal.w, original.normal.w); XCTAssertEqual(v.tangent.w, original.tangent.w)
          for (transformed, expected) in [(n, original.normal), (t, original.tangent), (b, original.bitangent)] {
            let unpacked = SIMD3(Float(Float16(bitPattern: expected.x)), Float(Float16(bitPattern: expected.y)),
              Float(Float16(bitPattern: expected.z)))
            XCTAssertLessThan(simd_distance(transformed, unpacked), 0.001)
          }
        }
      }
    } }
  }

  func testPreparationPreservesCollisionWindWaterAndLogicalTriangles() throws {
    let terrain = TerrainGenerator(seed: 8192)
    let site = try XCTUnwrap((-8...8).lazy.flatMap { x in (-8...8).lazy.compactMap { z in
      SettlementGenerator.site(in: .init(x, z), terrain: terrain)
    }}.first { $0.sportsGrounds.contains(where: \.hasStadium) })
    let stadium = try XCTUnwrap(site.sportsGrounds.last?.stadium)
    let coordinate = BlockPosition(stadium.point(along: 40, depth: 35, y: 0)).chunk
    let tile = TerrainTile(x: coordinate.x, z: coordinate.z, fullDetail: true)
    let chunk = terrain.generate(coordinate)
    func build(_ enabled: Bool) throws -> PreparedTerrainTile {
      try XCTUnwrap(TerrainPreparation.build(.init(id: .init(world: UUID(), tile: tile, revision: 0,
        lush: true, repeatAtlas: true, instanceSeats: enabled), terrain: terrain, cachedChunk: chunk,
        service: .detail, priority: 0), collision: { _ in }))
    }
    let baked = try build(false), instanced = try build(true)
    XCTAssertGreaterThan(instanced.stadiumSeats.count, 0)
    XCTAssertEqual(baked.chunk?.archiveCells, instanced.chunk?.archiveCells)
    XCTAssertEqual(baked.windAdmissionVertexCount, instanced.windAdmissionVertexCount)
    XCTAssertEqual(baked.animated?.vertices.withUnsafeBytes { Data($0) }, instanced.animated?.vertices.withUnsafeBytes { Data($0) })
    XCTAssertEqual(baked.animated?.indices, instanced.animated?.indices)
    XCTAssertEqual(baked.mesh.indices.count, instanced.mesh.indices.count + instanced.stadiumSeats.count * 108)
    XCTAssertEqual(baked.water.shallowIndices, instanced.water.shallowIndices)
    XCTAssertEqual(baked.water.deepIndices, instanced.water.deepIndices)
    XCTAssertEqual(baked.plants, instanced.plants); XCTAssertEqual(baked.fires, instanced.fires)
    XCTAssertEqual(baked.lamps, instanced.lamps)
    let key = TerrainPayloadKey(.init(id: instanced.id, terrain: terrain, service: .detail, priority: 0))
    let data = try XCTUnwrap(TerrainPayloadCodec.encode(instanced, key: key))
    let restored = try XCTUnwrap(TerrainPayloadCodec.decode(data, key: key, id: instanced.id))
    XCTAssertEqual(restored.stadiumSeats, instanced.stadiumSeats)
  }

  func testCacheIdentityRoundTripAndMalformedInstances() throws {
    let tile = TerrainTile(x: -3, z: -4, fullDetail: true), world = UUID()
    func request(_ enabled: Bool) -> TerrainPreparationRequest {
      .init(id: .init(world: world, tile: tile, revision: 1, lush: false, repeatAtlas: true, instanceSeats: enabled),
        terrain: .init(seed: 9), service: .detail, priority: 0)
    }
    let enabled = request(true), disabled = request(false), key = TerrainPayloadKey(enabled)
    XCTAssertNotEqual(enabled.id, disabled.id)
    XCTAssertNotEqual(key, TerrainPayloadKey(disabled))
    XCTAssertNotEqual(TerrainPayloadCodec.filename(key), TerrainPayloadCodec.filename(TerrainPayloadKey(disabled)))
    let valid = StadiumSeatInstance(position: [8, 30, 8], forward: [0, -1], color: 13)
    func payload(_ seat: StadiumSeatInstance, id: TerrainWorkID) -> PreparedTerrainTile {
      .init(id: id, chunk: .init(coordinate: tile.coordinate), mesh: .init(.init()),
        windAdmissionVertexCount: 72, stadiumSeats: [seat])
    }
    let value = payload(valid, id: enabled.id)
    let bytes = try XCTUnwrap(TerrainPayloadCodec.encode(value, key: key))
    let restored = try XCTUnwrap(TerrainPayloadCodec.decode(bytes, key: key, id: enabled.id))
    XCTAssertEqual(restored.stadiumSeats, [valid]); XCTAssertEqual(restored.windAdmissionVertexCount, 72)
    XCTAssertEqual(restored.byteCount, value.byteCount)
    XCTAssertEqual(value.reissued(id: enabled.id, stages: [:]).stadiumSeats, [valid])
    XCTAssertNil(TerrainPayloadCodec.decode(bytes, key: key, id: disabled.id))
    for seat in [StadiumSeatInstance(position: [0.5, 30, 8], forward: [0, -1], color: 13),
      .init(position: [8, 30, 8], forward: [2, 0], color: 13),
      .init(position: [8, 30, 8], forward: [.nan, 0], color: 13),
      .init(position: [8, .infinity, 8], forward: [0, -1], color: 13),
      .init(position: [8, 30, 8], forward: [0, -1], color: 99)] {
      let corrupt = try XCTUnwrap(TerrainPayloadCodec.encode(payload(seat, id: enabled.id), key: key))
      XCTAssertNil(TerrainPayloadCodec.decode(corrupt, key: key, id: enabled.id))
    }
    let wrongKey = TerrainPayloadKey(disabled)
    let unsupported = try XCTUnwrap(TerrainPayloadCodec.encode(payload(valid, id: disabled.id), key: wrongKey))
    XCTAssertNil(TerrainPayloadCodec.decode(unsupported, key: wrongKey, id: disabled.id))
    var oldSchema = bytes; oldSchema[40] = 1
    oldSchema.replaceSubrange(8..<40, with: Data(SHA256.hash(data: oldSchema.dropFirst(40))))
    XCTAssertNil(TerrainPayloadCodec.decode(oldSchema, key: key, id: enabled.id))
  }
}

private extension SIMD4 where Scalar == Float {
  var xyz: SIMD3<Float> { [x, y, z] }
}
