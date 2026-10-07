import XCTest
@testable import WorldCore

final class WaterBatchTests: XCTestCase {
  private func quad(_ body: WaterBody = .ocean, deep: Bool = false) -> WaterGeometry {
    var geometry = WaterGeometry()
    geometry.samples = [[0, 0], [0, 16], [16, 0], [16, 16]].map {
      .init(position: $0, depth: deep ? 12 : 3, body: body)
    }
    if deep { geometry.deepIndices = [0, 1, 2, 2, 1, 3] }
    else { geometry.shallowIndices = [0, 1, 2, 2, 1, 3] }
    return geometry
  }

  func testWaterBatchPreservesWorldPositionsWavesNormalsAndRepeatingUVs() {
    XCTAssertEqual(MemoryLayout<WaterMeshSource>.stride, 32)
    XCTAssertEqual(MemoryLayout<WaterMeshVertex>.stride, 64)
    XCTAssertEqual(MemoryLayout<WaterMeshSource>.offset(of: \.identity), 16)
    XCTAssertEqual(MemoryLayout<WaterMeshVertex>.offset(of: \.uv), 16)
    XCTAssertEqual(MemoryLayout<WaterMeshVertex>.offset(of: \.normal), 24)
    XCTAssertEqual(MemoryLayout<WaterMeshVertex>.offset(of: \.tangent), 32)
    XCTAssertEqual(MemoryLayout<WaterMeshVertex>.offset(of: \.bitangent), 40)
    XCTAssertEqual(MemoryLayout<WaterMeshVertex>.offset(of: \.detailUV), 48)
    XCTAssertEqual(MemoryLayout<WaterMeshVertex>.offset(of: \.optics), 56)
    let lake = WaterBody(id: 0x1234_5678_8765_4321, kind: .lake, level: 41)
    for body in [WaterBody.ocean, lake, .lava] {
      for origin in [ChunkCoordinate(-4, -8), .init(0, 0), .init(8192, -4096)] {
        let tiles = (0..<4).map { TerrainTile(x: origin.x + $0, z: origin.z, fullDetail: true) }
        let geometry = Dictionary(uniqueKeysWithValues: tiles.map { ($0, quad(body)) })
        let key = WaterBatchKey(tiles[0]), batch = WaterMeshBatch(key: key, geometry: geometry)
        var environment = WorldEnvironment(elapsed: 9999.9)
        environment.disturbWater(atX: key.origin.x + 16, z: key.origin.z, body: body, energy: 0.24)
        environment.advance(0.25)
        let vertices = batch.vertices(environment: environment)
        XCTAssertEqual(batch.indices.count, 24)
        XCTAssertEqual(vertices.count, 16)
        for slice in batch.slices {
          let original = geometry[slice.tile]!
          for i in 0..<slice.indexCount {
            let index = Int(batch.indices[slice.indexStart + i])
            let vertex = vertices[index], source = batch.sources[index]
            let sample = original.samples[Int(original.shallowIndices[i])]
            let world = slice.tile.origin + [sample.position.x, 0, sample.position.y]
            XCTAssertEqual(vertex.px + key.origin.x, world.x)
            XCTAssertEqual(vertex.pz + key.origin.z, world.z)
            let expected = environment.water(atX: world.x, z: world.z, depth: sample.depth, body: body)
            XCTAssertEqual(vertex.py, expected.height, accuracy: 0.00001)
            XCTAssertEqual(Float(Float16(bitPattern: vertex.normal.x)), expected.normal.x, accuracy: 0.001)
            XCTAssertEqual(Float(Float16(bitPattern: vertex.normal.y)), expected.normal.y, accuracy: 0.001)
            XCTAssertEqual(UInt64(source.identity.x) | UInt64(source.identity.y) << 32, body.id)
            let scale: Float = body.kind == .lava ? 0.0625 : 0.1
            let t = Float(environment.elapsed.truncatingRemainder(dividingBy: 10000))
            let flow = SIMD2<Float>(slice.tile.origin.x * scale + t * (body.kind == .lava ? 0.002 : 0.008),
              slice.tile.origin.z * scale - t * (body.kind == .lava ? 0.0012 : 0.004))
            let uv = sample.position * scale + flow - SIMD2<Float>(floor(flow.x), floor(flow.y))
            let difference = vertex.uv - uv
            // The original per-tile UV wrap differs only by whole repetitions.
            XCTAssertEqual(difference.x, difference.x.rounded(), accuracy: 0.002)
            XCTAssertEqual(difference.y, difference.y.rounded(), accuracy: 0.002)
            let detailFlow = SIMD2<Float>(slice.tile.origin.x, slice.tile.origin.z) * 0.27
              + SIMD2<Float>(-0.012, 0.01) * t
            let detail = sample.position * 0.27 + detailFlow - SIMD2<Float>(floor(detailFlow.x), floor(detailFlow.y))
            let detailDifference = vertex.detailUV - detail
            XCTAssertEqual(detailDifference.x, detailDifference.x.rounded(), accuracy: 0.004)
            XCTAssertEqual(detailDifference.y, detailDifference.y.rounded(), accuracy: 0.004)
            let optics = WaterAppearance.optics(depth: sample.depth, body: body, sample: expected)
            for axis in 0..<4 {
              XCTAssertEqual(Float(Float16(bitPattern: vertex.optics[axis])), optics[axis], accuracy: 0.001)
            }
          }
        }
      }
    }
  }

  func testPartsMergeOnlyAdjacentMatchingMaterialsAndRetainHiddenHoles() {
    let tiles = (0..<4).map { TerrainTile(x: $0, z: 0, fullDetail: true) }
    let geometry = Dictionary(uniqueKeysWithValues: tiles.map { ($0, quad()) })
    let batch = WaterMeshBatch(key: WaterBatchKey(tiles[0]), geometry: geometry)
    let merged = batch.parts(visible: Set(tiles), bands: [:])
    XCTAssertEqual(merged.count, 1)
    XCTAssertEqual(merged[0].indexCount, 24)
    XCTAssertEqual(merged[0].maximum.x, 64)
    let holes = batch.parts(visible: Set([tiles[0], tiles[2], tiles[3]]), bands: [tiles[3]: 7])
    XCTAssertEqual(holes.map(\.indexCount), [6, 6, 6])
    XCTAssertEqual(holes.map(\.indexStart), [0, 12, 18])
    XCTAssertEqual(holes.map(\.materialIndex), [0, 0, 14])
    XCTAssertEqual(holes.reduce(0) { $0 + $1.indexCount }, 18)
  }

  func testDepthAndTransparencyArePreservedAtMixedLOD() {
    let a = TerrainTile(x: 0, z: 0, fullDetail: true), b = TerrainTile(x: 1, z: 0)
    var mixed = quad(); mixed.deepIndices = mixed.shallowIndices
    let batch = WaterMeshBatch(key: WaterBatchKey(a), geometry: [a: mixed, b: mixed])
    let parts = batch.parts(visible: [a, b], bands: [a: 3, b: 3])
    XCTAssertEqual(Set(parts.map(\.materialIndex)), [6, 7, 48, 49])
    XCTAssertEqual(parts.reduce(0) { $0 + $1.indexCount }, 24)
  }

  func testKilometreHorizonBatchesStayGeographicallyBoundedWithoutRemovingTiles() {
    let plan = TerrainStreamingPlan(center: .init(16, 0), radius: 128, detailRadius: 16)
    let groups = Dictionary(grouping: plan.tiles, by: WaterBatchKey.init)
    XCTAssertEqual(groups.values.flatMap { $0 }.count, plan.tiles.count)
    XCTAssertLessThan(groups.count, plan.tiles.count / 3)
    for (key, tiles) in groups {
      for tile in tiles {
        XCTAssertLessThanOrEqual(key.size, max(4, tile.size * 2))
        XCTAssertGreaterThanOrEqual(tile.origin.x, key.origin.x)
        XCTAssertGreaterThanOrEqual(tile.origin.z, key.origin.z)
        XCTAssertLessThanOrEqual(tile.origin.x + Float(tile.blockSize), key.origin.x + Float(key.size * 16))
        XCTAssertLessThanOrEqual(tile.origin.z + Float(tile.blockSize), key.origin.z + Float(key.size * 16))
      }
    }
    XCTAssertEqual(WaterBatchKey(.init(x: -1, z: -1)).origin, [-64, 0, -64])
  }

  func testCoverageWaitsForAllChildrenIncludingDryReplacements() {
    let parent = TerrainTile(x: 0, z: 0, size: 8)
    let children: Set<TerrainTile> = [
      .init(x: 0, z: 0, size: 4), .init(x: 4, z: 0, size: 4),
      .init(x: 0, z: 4, size: 4), .init(x: 4, z: 4, size: 4),
    ]
    var coverage = WaterPresentationCoverage()
    coverage.update(desired: [parent], available: [parent])
    let dry = TerrainTile(x: 4, z: 4, size: 4)
    coverage.update(desired: children, available: children.subtracting([dry]).union([parent]))
    XCTAssertEqual(coverage.visible, [parent])
    coverage.update(desired: children, available: children.union([parent]))
    XCTAssertEqual(coverage.visible, children)
    coverage.update(desired: [], available: children.union([parent]))
    XCTAssertTrue(coverage.visible.isEmpty)
  }

  func testPreparedChildrenRemainHiddenUntilTerrainCoverageSwitches() {
    let parent = TerrainTile(x: 0, z: 0, size: 2)
    let children: Set<TerrainTile> = [.init(x: 0, z: 0), .init(x: 1, z: 0), .init(x: 0, z: 1), .init(x: 1, z: 1)]
    var coverage = WaterPresentationCoverage()
    coverage.update(desired: [parent], available: children.union([parent]))
    XCTAssertEqual(coverage.visible, [parent])
    coverage.update(desired: children, available: children.union([parent]))
    XCTAssertEqual(coverage.visible, children)
    // Moving away reverses the exchange without a hole or overlapping water.
    coverage.update(desired: [parent], available: children)
    XCTAssertEqual(coverage.visible, children)
    coverage.update(desired: [parent], available: children.union([parent]))
    XCTAssertEqual(coverage.visible, [parent])
  }

  private func assertSameVertex(_ a: WaterMeshVertex, _ b: WaterMeshVertex,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.px, b.px, file: file, line: line)
    XCTAssertEqual(a.py, b.py, file: file, line: line)
    XCTAssertEqual(a.pz, b.pz, file: file, line: line)
    XCTAssertEqual(a.uv, b.uv, file: file, line: line)
    XCTAssertEqual(a.normal, b.normal, file: file, line: line)
    XCTAssertEqual(a.tangent, b.tangent, file: file, line: line)
    XCTAssertEqual(a.bitangent, b.bitangent, file: file, line: line)
    XCTAssertEqual(a.detailUV, b.detailUV, file: file, line: line)
    XCTAssertEqual(a.optics, b.optics, file: file, line: line)
  }

  func testPartialUploadPreservesEveryDrawAttributeMaterialAndBounds() {
    let bodies: [WaterBody] = [.ocean, .lava,
      .init(id: 0x1234_5678_9999_8765, kind: .lake, level: 63),
      .init(id: 41, kind: .river, level: 80, current: [0.7, 0, -2.3])]
    for origin in [ChunkCoordinate(-8, -12), .init(8192, -8192)] {
      let tiles = (0..<4).map { TerrainTile(x: origin.x + $0, z: origin.z, fullDetail: $0 % 2 == 0) }
      var geometry: [TerrainTile: WaterGeometry] = [:]
      for (i, tile) in tiles.enumerated() {
        var g = quad(bodies[i]); g.deepIndices = [2, 1, 3]
        geometry[tile] = g
      }
      let batch = WaterMeshBatch(key: .init(tiles[0]), geometry: geometry)
      let bands = Dictionary(uniqueKeysWithValues: tiles.enumerated().map { ($1, $0 * 6) })
      for time in [0.0, 31.25, 9999.9] {
        var environment = WorldEnvironment(elapsed: time)
        for body in bodies { environment.disturbWater(atX: batch.key.origin.x + 16,
          z: batch.key.origin.z, body: body, energy: 0.3) }
        environment.advance(0.2)
        let original = batch.vertices(environment: environment)
        for mask in 0..<16 {
          let accepted = Set(tiles.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil })
          let result = batch.retaining(accepted, vertices: original)
          let control = WaterMeshBatch(key: batch.key, geometry: geometry.filter { accepted.contains($0.key) })
          XCTAssertEqual(result.batch.tiles, accepted)
          XCTAssertEqual(result.batch.sources.count, accepted.count * 4)
          XCTAssertEqual(result.batch.indices, control.indices)
          XCTAssertEqual(result.batch.sources.map(\.geometry), control.sources.map(\.geometry))
          XCTAssertEqual(result.batch.sources.map(\.identity), control.sources.map(\.identity))
          let controlVertices = control.vertices(environment: environment)
          let animated = result.batch.vertices(environment: environment)
          for i in result.vertices.indices {
            assertSameVertex(result.vertices[i], controlVertices[i])
            assertSameVertex(animated[i], controlVertices[i])
          }
          for continuous in [false, true] {
            let actualParts = result.batch.parts(visible: accepted, bands: bands, continuousDepth: continuous)
            XCTAssertEqual(actualParts, control.parts(visible: accepted, bands: bands, continuousDepth: continuous))
            let before = batch.parts(visible: accepted, bands: bands, continuousDepth: continuous).flatMap { part in
              batch.indices[part.indexStart..<(part.indexStart + part.indexCount)].map { (part.materialIndex, Int($0)) }
            }
            let after = actualParts.flatMap { part in
              result.batch.indices[part.indexStart..<(part.indexStart + part.indexCount)].map { (part.materialIndex, Int($0)) }
            }
            XCTAssertEqual(before.count, after.count)
            for (a, b) in zip(before, after) {
              XCTAssertEqual(a.0, b.0)
              assertSameVertex(original[a.1], result.vertices[b.1])
            }
          }
        }
      }
    }
  }

  func testCompleteUploadSharesPreparedArraysAndIgnoresUnknownTiles() {
    let a = TerrainTile(x: 0, z: 0), b = TerrainTile(x: 1, z: 0)
    let batch = WaterMeshBatch(key: .init(a), geometry: [a: quad(), b: quad()])
    let vertices = batch.vertices(environment: .init(elapsed: 3))
    let result = batch.retaining([a, b, .init(x: 200, z: 200)], vertices: vertices)
    XCTAssertEqual(result.batch.tiles, [a, b])
    batch.sources.withUnsafeBufferPointer { original in
      result.batch.sources.withUnsafeBufferPointer { XCTAssertEqual(original.baseAddress, $0.baseAddress) }
    }
    batch.indices.withUnsafeBufferPointer { original in
      result.batch.indices.withUnsafeBufferPointer { XCTAssertEqual(original.baseAddress, $0.baseAddress) }
    }
    vertices.withUnsafeBufferPointer { original in
      result.vertices.withUnsafeBufferPointer { XCTAssertEqual(original.baseAddress, $0.baseAddress) }
    }
  }

  func testDryOnlyPartialUploadCarriesCoverageWithoutWetBufferStorage() {
    let wet = TerrainTile(x: 0, z: 0), dry = TerrainTile(x: 1, z: 0)
    let batch = WaterMeshBatch(key: .init(wet), geometry: [wet: quad(), dry: .init()])
    let vertices = batch.vertices(environment: .init())
    for accepted: Set<TerrainTile> in [[dry], [], [.init(x: -100, z: -100)]] {
      let result = batch.retaining(accepted, vertices: vertices)
      XCTAssertEqual(result.batch.tiles, accepted.intersection(batch.tiles))
      XCTAssertTrue(result.batch.sources.isEmpty)
      XCTAssertTrue(result.batch.indices.isEmpty)
      XCTAssertTrue(result.batch.slices.isEmpty)
      XCTAssertTrue(result.vertices.isEmpty)
    }
    XCTAssertEqual(batch.sources.count, 4)
    XCTAssertEqual(batch.indices.count, 6)
  }

  func testCompactionCanBeRepeatedWithoutReintroducingRejectedMembers() {
    let tiles = (0..<4).map { TerrainTile(x: $0, z: 0) }
    let batch = WaterMeshBatch(key: .init(tiles[0]), geometry: Dictionary(uniqueKeysWithValues: tiles.map { ($0, quad()) }))
    let vertices = batch.vertices(environment: .init(elapsed: 40))
    let first = batch.retaining([tiles[1], tiles[3]], vertices: vertices)
    let second = first.batch.retaining([tiles[0], tiles[3]], vertices: first.vertices)
    let direct = batch.retaining([tiles[3]], vertices: vertices)
    XCTAssertEqual(second.batch.tiles, [tiles[3]])
    XCTAssertEqual(second.batch.indices, direct.batch.indices)
    XCTAssertEqual(second.batch.sources.map(\.geometry), direct.batch.sources.map(\.geometry))
    for (a, b) in zip(second.vertices, direct.vertices) { assertSameVertex(a, b) }
  }

  func testDryPartialPreparationDoesNotAcknowledgeChangedWetNeighbor() async throws {
    let a = TerrainTile(x: 0, z: 0), b = TerrainTile(x: 1, z: 0)
    var requests = WaterGeometryRequests()
    requests.install(quad(), tile: a); requests.install(.init(), tile: b)
    let input = try XCTUnwrap(requests.beginPreparation(for: .init(a)))
    let worker = WaterMeshPreparation()
    let (batch, vertices) = await worker.prepare(key: input.key, geometry: input.geometry, environment: .init())
    requests.install(quad(.lava), tile: a)
    let accepted = requests.publishableTiles(in: input)
    XCTAssertEqual(accepted, [b])
    let selected = batch.retaining(accepted, vertices: vertices)
    XCTAssertEqual(selected.batch.tiles, [b]); XCTAssertTrue(selected.batch.indices.isEmpty)
    XCTAssertFalse(requests.acknowledge(input, published: accepted))
    XCTAssertNotNil(requests.dirty[.init(a)])
    let current = try XCTUnwrap(requests.beginPreparation(for: .init(a)))
    let next = await worker.prepare(key: current.key, geometry: current.geometry, environment: .init(elapsed: 50))
    let replacement = next.0.retaining(requests.publishableTiles(in: current), vertices: next.1)
    XCTAssertEqual(replacement.batch.tiles, [a, b])
    XCTAssertEqual(replacement.batch.sources.count, 4)
    XCTAssertTrue(replacement.batch.sources.allSatisfy { $0.identity.z == UInt32(WaterBodyKind.lava.rawValue) })
    XCTAssertTrue(requests.acknowledge(current, published: replacement.batch.tiles))
    XCTAssertTrue(requests.dirty.isEmpty)
  }

  func testHiddenCurrentLODRemainsPackedUntilCoverageChanges() {
    let parent = TerrainTile(x: 0, z: 0, size: 2)
    let children: Set<TerrainTile> = [.init(x: 0, z: 0), .init(x: 1, z: 0), .init(x: 0, z: 1), .init(x: 1, z: 1)]
    let rejected = TerrainTile(x: 3, z: 3)
    let kept = children.union([parent])
    let batch = WaterMeshBatch(key: .init(parent), geometry: Dictionary(uniqueKeysWithValues: kept.union([rejected]).map { ($0, quad()) }))
    let compact = batch.retaining(kept, vertices: batch.vertices(environment: .init()))
    var coverage = WaterPresentationCoverage()
    coverage.update(desired: [parent], available: compact.batch.tiles)
    XCTAssertEqual(coverage.visible, [parent])
    XCTAssertEqual(compact.batch.parts(visible: coverage.visible, bands: [:]).reduce(0) { $0 + $1.indexCount }, 6)
    coverage.update(desired: children, available: compact.batch.tiles)
    XCTAssertEqual(coverage.visible, children)
    XCTAssertEqual(compact.batch.parts(visible: coverage.visible, bands: [:]).reduce(0) { $0 + $1.indexCount }, 24)
    XCTAssertEqual(compact.batch.sources.count, 20)
  }

  func testGPUBackpressureNeverQueuesFramesAndRecoversWithoutMainActor() throws {
    let gate = RenderSubmissionGate(limit: 2)
    let first = try XCTUnwrap(gate.acquire(at: 1)), second = try XCTUnwrap(gate.acquire(at: 2))
    for _ in 0..<180 { XCTAssertNil(gate.acquire(at: 3)) }
    let stalled = gate.consume(at: 8)
    XCTAssertEqual(stalled.inFlight, 2)
    XCTAssertEqual(stalled.oldestInFlightMilliseconds, 7000)
    XCTAssertEqual(stalled.skippedTotal, 180)
    XCTAssertEqual(stalled.gpu.count, 0)
    let completion = expectation(description: "GPU completion without a UI task")
    DispatchQueue.global().async {
      gate.complete(first, at: 9, gpuSeconds: 0.004)
      gate.complete(second, at: 10, failed: true)
      completion.fulfill()
    }
    wait(for: [completion], timeout: 2)
    let recovered = gate.consume(at: 11)
    XCTAssertEqual(recovered.inFlight, 0)
    XCTAssertEqual(recovered.completedTotal, 2)
    XCTAssertEqual(recovered.failedTotal, 1)
    XCTAssertEqual(recovered.gpu.meanMilliseconds, 4)
    XCTAssertEqual(recovered.completionLatency.count, 2)
    XCTAssertNotNil(gate.acquire(at: 11))
    gate.complete(first, at: 12) // Late/duplicate callback cannot release a new slot.
    XCTAssertEqual(gate.consume(at: 12).inFlight, 1)
  }
}
