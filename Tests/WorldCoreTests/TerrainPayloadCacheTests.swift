import Foundation
import XCTest
@testable import WorldCore

final class TerrainPayloadCacheTests: XCTestCase {
  private func request(x: Int = 0, seed: UInt64 = 42, style: PlanetStyle = .solar,
    lush: Bool = false, edits: [BlockPosition: Block] = [:], plants: [BlockPosition: PlantEdit] = [:]
  ) -> TerrainPreparationRequest {
    .init(id: .init(world: UUID(), tile: .init(x: x, z: 0, fullDetail: true), revision: 0,
      lush: lush, incarnation: UInt64.random(in: 1...UInt64.max)), terrain: .init(seed: seed, style: style),
      edits: edits, plantEdits: plants, service: .detail, priority: 0)
  }
  func testContentKeyIgnoresLifetimeButIncludesWorldRepresentationAndHaloEdits() {
    let ordinary = TerrainPayloadKey(request())
    XCTAssertEqual(ordinary, TerrainPayloadKey(request()))
    XCTAssertNotEqual(ordinary, TerrainPayloadKey(request(x: 1)))
    XCTAssertNotEqual(ordinary, TerrainPayloadKey(request(seed: 43)))
    XCTAssertNotEqual(ordinary, TerrainPayloadKey(request(style: .dune)))
    XCTAssertNotEqual(ordinary, TerrainPayloadKey(request(lush: true)))
    XCTAssertNotEqual(ordinary, TerrainPayloadKey(request(edits: [.init(-1, 30, 2): .air])))
    let a: BlockPosition = .init(1, 20, 2), b: BlockPosition = .init(2, 20, 2)
    XCTAssertEqual(TerrainPayloadKey(request(edits: [a: .stone, b: .air])),
      TerrainPayloadKey(request(edits: [b: .air, a: .stone])))
    let plant = PlantEdit(position: a, kind: nil)
    XCTAssertNotEqual(ordinary, TerrainPayloadKey(request(plants: [a: plant])))
  }

  func testByteBoundedReturnCacheRetainsRecentlyUsedPayloads() {
    var source = VoxelMesh(); source.appendBox(size: [1, 1, 1], center: .zero, material: 0)
    let mesh = PackedTerrainMesh(source)
    let requests = (0..<4).map { request(x: $0) }, keys = requests.map(TerrainPayloadKey.init)
    let cache = TerrainPayloadCache(limitBytes: mesh.byteCount * 2, limitEntries: 8)
    for i in 0..<2 { cache.insert(.init(id: requests[i].id, mesh: mesh), for: keys[i]) }
    XCTAssertNotNil(cache.value(for: keys[0]))
    cache.insert(.init(id: requests[2].id, mesh: mesh), for: keys[2])
    XCTAssertNil(cache.value(for: keys[1]))
    XCTAssertNotNil(cache.value(for: keys[0])); XCTAssertNotNil(cache.value(for: keys[2]))
    XCTAssertEqual(cache.metrics.entries, 2)
    XCTAssertEqual(cache.metrics.bytes, mesh.byteCount * 2)
    XCTAssertEqual(cache.metrics.evictions, 1)
    var huge = source; huge.append(source); huge.append(source)
    cache.insert(.init(id: requests[3].id, mesh: .init(huge)), for: keys[3])
    XCTAssertEqual(cache.metrics.oversized, 1)
    XCTAssertNil(cache.value(for: keys[3]))
    XCTAssertLessThanOrEqual(cache.metrics.bytes, cache.metrics.limitBytes)
  }

  func testWarmResultIsReissuedWithCurrentLifetimeAndIdenticalGeometry() throws {
    let firstRequest = request(x: -8, seed: 787_001)
    let first = try XCTUnwrap(TerrainPreparation.build(firstRequest, collision: { _ in }))
    let nextRequest = request(x: -8, seed: 787_001)
    let next = try XCTUnwrap(TerrainPreparation.build(nextRequest, collision: { _ in }))
    XCTAssertNotEqual(first.id, next.id)
    XCTAssertEqual(next.id, nextRequest.id)
    XCTAssertNotNil(next.stages["memory_cache_hit"])
    XCTAssertEqual(first.mesh.indices, next.mesh.indices)
    XCTAssertEqual(first.mesh.vertices.withUnsafeBytes { Data($0) }, next.mesh.vertices.withUnsafeBytes { Data($0) })
    XCTAssertEqual(first.water.shallowIndices, next.water.shallowIndices)
    XCTAssertEqual(first.plants, next.plants)
    XCTAssertGreaterThanOrEqual(next.readyAt, first.readyAt)
    let edit = request(x: -8, seed: 787_001, edits: [.init(-128, 60, 0): .brick])
    let changed = try XCTUnwrap(TerrainPreparation.build(edit, collision: { _ in }))
    XCTAssertNil(changed.stages["memory_cache_hit"])
    XCTAssertEqual(changed.chunk?[0, 60, 0], .brick)
    var snapshot = ChunkData(coordinate: firstRequest.id.tile.coordinate)
    snapshot[0, 70, 0] = .glass
    let supplied = TerrainPreparationRequest(id: nextRequest.id, terrain: nextRequest.terrain,
      cachedChunk: snapshot, service: .detail, priority: 0)
    let authoritative = try XCTUnwrap(TerrainPreparation.build(supplied, collision: { _ in }))
    XCTAssertNil(authoritative.stages["memory_cache_hit"])
    XCTAssertEqual(authoritative.chunk?[0, 70, 0], .glass)
  }
}
