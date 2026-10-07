import Foundation
import XCTest
@testable import WorldCore

final class TerrainBaseCacheTests: XCTestCase, @unchecked Sendable {
  private func request(_ chunk: ChunkData, terrain: TerrainGenerator, lush: Bool,
    repeatAtlas: Bool = true, seats: Bool = false, edits: [BlockPosition: Block] = [:],
    plants: [BlockPosition: PlantEdit] = [:]) -> TerrainPreparationRequest {
    .init(id: .init(world: UUID(), tile: .init(x: chunk.coordinate.x, z: chunk.coordinate.z,
      fullDetail: true), revision: 0, lush: lush, repeatAtlas: repeatAtlas, instanceSeats: seats),
      terrain: terrain, edits: edits, plantEdits: plants, cachedChunk: chunk,
      service: .detail, priority: 0)
  }
  private func prepare(_ request: TerrainPreparationRequest, cache: TerrainPayloadCache) async throws -> PreparedTerrainTile {
    let result = await TerrainPreparation.prepare(request, cache: cache, disk: .init(root: nil), collision: { _ in })
    return try XCTUnwrap(result)
  }
  private func same(_ actual: PreparedTerrainTile, _ expected: PreparedTerrainTile,
    request: TerrainPreparationRequest, file: StaticString = #filePath, line: UInt = #line) throws {
    let key = TerrainPayloadKey(request)
    let a = try XCTUnwrap(TerrainPayloadCodec.encode(actual, key: key), file: file, line: line)
    let b = try XCTUnwrap(TerrainPayloadCodec.encode(expected, key: key), file: file, line: line)
    XCTAssertEqual(a, b, "Every mesh attribute/index, water sample, light, plant and collision cell must agree",
      file: file, line: line)
  }

  func testDecorationChangesReuseExactBaseAndWaterAcrossStylesAndAtlasModes() async throws {
    for style in PlanetStyle.allCases {
      for repeated in [false, true] {
        let terrain = TerrainGenerator(seed: 42_159, style: style)
        var chunk = terrain.generate(.init(-3, 2))
        // Include shaped, transparent, lit and foliage geometry in the base.
        chunk[2, 89, 2] = .torch; chunk[3, 89, 2] = .lamp
        chunk[4, 89, 2] = .glass; chunk[5, 89, 2] = .woodStairsEast
        chunk[6, 89, 2] = .leaves
        let cache = TerrainPayloadCache(baseBytes: 32 * 1_024 * 1_024)
        let warm = request(chunk, terrain: terrain, lush: true, repeatAtlas: repeated)
        let first = try await prepare(warm, cache: cache)
        let truth = try await prepare(warm, cache: .init())
        try same(first, truth, request: warm)
        XCTAssertEqual(cache.base?.metrics.entries, 1)
        for lush in [false, true, false] {
          let position = BlockPosition(-46, 90, 35)
          let next = request(chunk, terrain: terrain, lush: lush, repeatAtlas: repeated,
            plants: [position: .init(position: position, kind: lush ? .daisy : nil)])
          let reused = try await prepare(next, cache: cache)
          let fresh = try await prepare(next, cache: .init())
          XCTAssertNotNil(reused.stages["base_cache_hit"])
          XCTAssertNil(reused.stages["meshing"])
          XCTAssertEqual(reused.id, next.id)
          try same(reused, fresh, request: next)
        }
        XCTAssertEqual(cache.base?.metrics.hits, 3)
        XCTAssertLessThanOrEqual(cache.metrics.bytes + (cache.base?.metrics.bytes ?? 0), 64 * 1_024 * 1_024)
        XCTAssertEqual(cache.metrics.limitBytes + (cache.base?.metrics.limitBytes ?? 0), 64 * 1_024 * 1_024)
      }
    }
  }

  func testUnpublishedCellsHaloAndContextChangesCannotReuseStaleGeometry() async throws {
    let terrain = TerrainGenerator(seed: 932_119, style: .verdant)
    let chunk = terrain.generate(.init(-2, -3)), cache = TerrainPayloadCache(baseBytes: 32 * 1_024 * 1_024)
    let original = request(chunk, terrain: terrain, lush: true)
    _ = try await prepare(original, cache: cache)
    // Revisions/edits are deliberately unchanged. The real supplied cells win.
    for position in [(4, 100, 4), (-1, 50, 5), (16, -40, 16)] {
      var changed = chunk; changed[position.0, position.1, position.2] = .glass
      let next = request(changed, terrain: terrain, lush: false)
      let result = try await prepare(next, cache: cache)
      XCTAssertNil(result.stages["base_cache_hit"])
      XCTAssertEqual(result.chunk?.archiveCells, changed.archiveCells)
      let fresh = try await prepare(next, cache: .init())
      try same(result, fresh, request: next)
    }
    XCTAssertEqual(cache.base?.metrics.cellMismatches, 3)
    let changes = [
      request(chunk, terrain: .init(seed: terrain.seed + 1, style: terrain.style), lush: false),
      request(chunk, terrain: .init(seed: terrain.seed, style: .solar), lush: false),
      request(chunk, terrain: terrain.marinaSurveyTerrain, lush: false),
      request(chunk, terrain: terrain, lush: false, repeatAtlas: false),
      request(chunk, terrain: terrain, lush: false, seats: true),
      request(chunk, terrain: terrain, lush: false, edits: [.init(-31, 80, -47): .brick])
    ]
    for next in changes {
      let result = try await prepare(next, cache: cache)
      XCTAssertNil(result.stages["base_cache_hit"])
      let fresh = try await prepare(next, cache: .init())
      try same(result, fresh, request: next)
    }
    // A worker decorating a cached mesh must not mutate its stored arrays.
    let next = request(chunk, terrain: terrain, lush: false)
    let reused = try await prepare(next, cache: cache)
    XCTAssertNotNil(reused.stages["base_cache_hit"])
    let fresh = try await prepare(next, cache: .init())
    try same(reused, fresh, request: next)
  }

  func testBaseReservationEvictionOversizeAndLocalAdmissionAreBounded() async throws {
    let terrain = TerrainGenerator(seed: 932_120, style: .dune)
    let chunk = ChunkData(coordinate: .init(0, 0))
    var mesh = VoxelMesh(); mesh.appendBox(size: .one, center: .zero, material: 0)
    let base = TerrainBase(chunk: chunk, mesh: mesh, water: .init())
    let keys = (0..<3).map { i in
      TerrainBaseKey(.init(request(chunk, terrain: .init(seed: UInt64(i)), lush: true)))
    }
    let cache = TerrainBaseCache(limitBytes: base.byteCount * 2, limitEntries: 3)
    cache.insert(base, for: keys[0]); cache.insert(base, for: keys[1])
    XCTAssertNotNil(cache.value(for: keys[0], chunk: chunk))
    cache.insert(base, for: keys[2])
    XCTAssertNil(cache.value(for: keys[1], chunk: chunk))
    XCTAssertEqual(cache.metrics.evictions, 1)
    XCTAssertEqual(cache.metrics.bytes, base.byteCount * 2)
    var huge = mesh; huge.append(mesh); huge.append(mesh)
    let small = TerrainBaseCache(limitBytes: base.byteCount)
    small.insert(.init(chunk: chunk, mesh: huge, water: .init()), for: keys[0])
    XCTAssertEqual(small.metrics.oversized, 1); XCTAssertEqual(small.metrics.bytes, 0)

    let reserved = TerrainPayloadCache(limitBytes: 4 * 1_024 * 1_024, baseBytes: 1_024 * 1_024)
    _ = try await prepare(request(chunk, terrain: terrain, lush: false), cache: reserved)
    XCTAssertEqual(reserved.base?.metrics.entries, 0, "Far population must not evict local bases")
    _ = try await prepare(request(chunk, terrain: terrain, lush: true), cache: reserved)
    XCTAssertEqual(reserved.base?.metrics.entries, 1)
    XCTAssertEqual(reserved.metrics.limitBytes + (reserved.base?.metrics.limitBytes ?? 0), 4 * 1_024 * 1_024)
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await TerrainPreparation.prepare(self.request(chunk, terrain: terrain, lush: true),
        cache: reserved, disk: .init(root: nil), collision: { _ in XCTFail("Cancelled collision") })
    }
    let value = await cancelled.value
    XCTAssertNil(value); XCTAssertEqual(reserved.base?.metrics.hits, 0)
  }

  func testStadiumInstancesSurviveBaseReuseWithExactPayload() async throws {
    let terrain = TerrainGenerator(seed: 8192)
    let site = try XCTUnwrap((-8...8).lazy.flatMap { x in (-8...8).lazy.compactMap { z in
      SettlementGenerator.site(in: .init(x, z), terrain: terrain)
    }}.first { $0.sportsGrounds.contains(where: \.hasStadium) })
    let stadium = try XCTUnwrap(site.sportsGrounds.last?.stadium)
    let coordinate = BlockPosition(stadium.point(along: 40, depth: 35, y: 0)).chunk
    let chunk = terrain.generate(coordinate), cache = TerrainPayloadCache(baseBytes: 32 * 1_024 * 1_024)
    let warm = request(chunk, terrain: terrain, lush: true, seats: true)
    let first = try await prepare(warm, cache: cache)
    XCTAssertFalse(first.stadiumSeats.isEmpty)
    let next = request(chunk, terrain: terrain, lush: false, seats: true)
    let reused = try await prepare(next, cache: cache)
    XCTAssertNotNil(reused.stages["base_cache_hit"])
    let fresh = try await prepare(next, cache: .init())
    try same(reused, fresh, request: next)
    XCTAssertEqual(reused.stadiumSeats, first.stadiumSeats)
  }

  func testConcurrentWorkersDecorateIndependentCopies() async throws {
    let terrain = TerrainGenerator(seed: 73_159), chunk = terrain.generate(.init(-1, 2))
    let cache = TerrainPayloadCache(baseBytes: 32 * 1_024 * 1_024)
    _ = try await prepare(request(chunk, terrain: terrain, lush: true), cache: cache)
    let inputs = (0..<24).map { i in
      let p = BlockPosition(-14, 90, 34)
      return request(chunk, terrain: terrain, lush: i % 2 == 0,
        plants: [p: .init(position: p, kind: i % 3 == 0 ? .daisy : nil)])
    }
    let results = try await withThrowingTaskGroup(of: (Int, PreparedTerrainTile).self) { group in
      for (i, input) in inputs.enumerated() {
        group.addTask { (i, try await self.prepare(input, cache: cache)) }
      }
      var results: [(Int, PreparedTerrainTile)] = []
      for try await result in group { results.append(result) }
      return results
    }
    for (i, reused) in results {
      let fresh = try await prepare(inputs[i], cache: .init())
      XCTAssertNotNil(reused.stages["base_cache_hit"])
      try same(reused, fresh, request: inputs[i])
    }
    XCTAssertEqual(cache.base?.metrics.hits, inputs.count)
    XCTAssertEqual(cache.base?.metrics.entries, 1)
  }
}
