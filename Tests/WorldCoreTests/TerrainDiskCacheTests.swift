import CryptoKit
import Foundation
import XCTest
@testable import WorldCore

final class TerrainDiskCacheTests: XCTestCase, @unchecked Sendable {
  private final class WriteGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false, released = false
    func block() {
      condition.lock()
      entered = true
      let deadline = Date().addingTimeInterval(10)
      while !released && condition.wait(until: deadline) {}
      condition.unlock()
    }
    var isBlocked: Bool {
      condition.lock(); defer { condition.unlock() }
      return entered && !released
    }
    func release() {
      condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
  }
  private final class ReadCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    func finish() { lock.withLock { completed = true } }
    var isFinished: Bool { lock.withLock { completed } }
  }
  private func request(x: Int = -2, seed: UInt64 = 901) -> TerrainPreparationRequest {
    .init(id: .init(world: UUID(), tile: .init(x: x, z: -1, fullDetail: true),
      revision: 0, lush: true, incarnation: 1), terrain: .init(seed: seed, style: .dune),
      service: .detail, priority: 0)
  }
  private func fixture(_ request: TerrainPreparationRequest) -> PreparedTerrainTile {
    var mesh = VoxelMesh()
    mesh.appendBox(size: [1, 1, 1], center: [2, 30, 2], material: 0)
    var foliage = VoxelMesh()
    foliage.appendBox(size: [1, 2, 1], center: [4, 31, 4], material: 4)
    var chunk = ChunkData(coordinate: request.id.tile.coordinate)
    chunk[2, 30, 2] = .grass; chunk[-1, -60, 16] = .stone; chunk[15, 100, 15] = .glass
    var water = WaterGeometry()
    water.samples = [[Float(0), 0], [0, 2], [2, 0]].map {
      .init(position: SIMD2($0[0], $0[1]), depth: 3.2,
        body: .init(id: 77, kind: .river, level: 20, current: [1.5, 0, -0.3]))
    }
    water.shallowIndices = [0, 1, 2]; water.deepIndices = [2, 1, 0]
    return .init(id: request.id, chunk: chunk, mesh: .init(mesh), animated: .init(foliage),
      windAdmissionVertexCount: mesh.positions.count + foliage.positions.count, water: water,
      plants: [.init(position: .init(-30, 31, -14), kind: .fern, scale: 0.87)],
      lamps: [[1, 30, 2]], fires: [[5, 31, 2]])
  }
  private func folder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("worldcraft-cache-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  private func eventually(_ predicate: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<300 {
      if predicate() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
  }
  private func same(_ first: PackedTerrainMesh, _ second: PackedTerrainMesh) {
    XCTAssertEqual(first.vertices.withUnsafeBytes { Data($0) }, second.vertices.withUnsafeBytes { Data($0) })
    XCTAssertEqual(first.indices, second.indices); XCTAssertEqual(first.parts.count, second.parts.count)
    for (a, b) in zip(first.parts, second.parts) {
      XCTAssertEqual(a.offset, b.offset); XCTAssertEqual(a.count, b.count); XCTAssertEqual(a.material, b.material)
      XCTAssertEqual(a.minimum, b.minimum); XCTAssertEqual(a.maximum, b.maximum)
    }
  }

  func testArchivePreservesCollisionGeometryMaterialsAnimationAndWater() throws {
    let first = request(), next = request(), key = TerrainPayloadKey(first), value = fixture(first)
    let data = try XCTUnwrap(TerrainPayloadCodec.encode(value, key: key))
    let copy = try XCTUnwrap(TerrainPayloadCodec.decode(data, key: key, id: next.id))
    XCTAssertEqual(copy.id, next.id); XCTAssertNotEqual(copy.id.world, value.id.world)
    XCTAssertGreaterThanOrEqual(copy.readyAt, value.readyAt)
    XCTAssertEqual(copy.chunk?.archiveCells, value.chunk?.archiveCells)
    XCTAssertEqual(copy.chunk?.maximumFilledY, value.chunk?.maximumFilledY)
    same(copy.mesh, value.mesh); same(try XCTUnwrap(copy.animated), try XCTUnwrap(value.animated))
    XCTAssertEqual(copy.windAdmissionVertexCount, value.windAdmissionVertexCount)
    XCTAssertEqual(copy.plants, value.plants); XCTAssertEqual(copy.fires, value.fires); XCTAssertEqual(copy.lamps, value.lamps)
    XCTAssertEqual(copy.water.shallowIndices, value.water.shallowIndices)
    XCTAssertEqual(copy.water.deepIndices, value.water.deepIndices)
    for (a, b) in zip(copy.water.samples, value.water.samples) {
      XCTAssertEqual(a.position, b.position); XCTAssertEqual(a.depth, b.depth); XCTAssertEqual(a.body, b.body)
    }
    let surfaceRequest = TerrainPreparationRequest(id: .init(world: UUID(),
      tile: .init(x: -32, z: -32, size: 32), revision: 0, lush: false), terrain: first.terrain,
      service: .coverage, priority: 0)
    let surface = PreparedTerrainTile(id: surfaceRequest.id, mesh: .init(.init()))
    let surfaceKey = TerrainPayloadKey(surfaceRequest)
    let surfaceData = try XCTUnwrap(TerrainPayloadCodec.encode(surface, key: surfaceKey))
    XCTAssertNotNil(TerrainPayloadCodec.decode(surfaceData, key: surfaceKey, id: surfaceRequest.id))
  }

  func testCorruptionWrongContentTruncationAndIncompatibleSchemaAreRejected() throws {
    let r = request(), key = TerrainPayloadKey(r)
    let data = try XCTUnwrap(TerrainPayloadCodec.encode(fixture(r), key: key))
    XCTAssertNil(TerrainPayloadCodec.decode(data, key: TerrainPayloadKey(request(seed: 902)), id: r.id))
    for length in [0, 8, 40, data.count / 2, data.count - 1] {
      XCTAssertNil(TerrainPayloadCodec.decode(data.prefix(length), key: key, id: r.id))
    }
    var corrupt = data; corrupt[corrupt.count - 1] ^= 1
    XCTAssertNil(TerrainPayloadCodec.decode(corrupt, key: key, id: r.id))
    // Repair the checksum to exercise version/semantic rejection, not only CRC.
    var oldSchema = data; oldSchema[40] = 255
    oldSchema.replaceSubrange(8..<40, with: Data(SHA256.hash(data: oldSchema.dropFirst(40))))
    XCTAssertNil(TerrainPayloadCodec.decode(oldSchema, key: key, id: r.id))
    let original = fixture(r)
    let invalidMeshes = [
      PackedTerrainMesh(vertices: original.mesh.vertices, indices: [.max, 0, 1], parts: original.mesh.parts),
      PackedTerrainMesh(vertices: original.mesh.vertices, indices: original.mesh.indices,
        parts: [.init(offset: 0, count: original.mesh.indices.count, material: 99, minimum: .zero, maximum: .one)]),
      PackedTerrainMesh(vertices: original.mesh.vertices, indices: original.mesh.indices,
        parts: [.init(offset: 0, count: original.mesh.indices.count, material: 0, minimum: .zero, maximum: .one)])
    ]
    for mesh in invalidMeshes {
      let malformed = PreparedTerrainTile(id: r.id, chunk: original.chunk, mesh: mesh)
      let bytes = try XCTUnwrap(TerrainPayloadCodec.encode(malformed, key: key))
      XCTAssertNil(TerrainPayloadCodec.decode(bytes, key: key, id: r.id))
    }
    var badLength = data
    badLength.replaceSubrange(48..<56, with: [UInt8](repeating: 255, count: 8))
    badLength.replaceSubrange(8..<40, with: Data(SHA256.hash(data: badLength.dropFirst(40))))
    XCTAssertNil(TerrainPayloadCodec.decode(badLength, key: key, id: r.id))
  }

  func testWritebackRemainsBoundedWhileEncodingAndCoalescesDuplicateKeys() {
    let first = request(), value = fixture(first), key = TerrainPayloadKey(first)
    let queue = TerrainDiskWriteQueue(limitBytes: value.byteCount * 2, limitEntries: 2)
    XCTAssertTrue(queue.offer(value, key: key))
    XCTAssertFalse(queue.offer(value, key: key)); XCTAssertEqual(queue.snapshot.coalescedWrites, 1)
    let active = queue.take()!
    XCTAssertEqual(queue.snapshot.queuedWrites, 1, "In-progress encoding is still charged")
    let second = request(x: 0)
    XCTAssertFalse(queue.offer(fixture(second), key: TerrainPayloadKey(second)))
    XCTAssertEqual(queue.snapshot.queuedWrites, 2)
    let third = request(x: 1)
    XCTAssertFalse(queue.offer(fixture(third), key: TerrainPayloadKey(third)))
    XCTAssertEqual(queue.snapshot.droppedWrites, 1)
    XCTAssertLessThanOrEqual(queue.snapshot.queuedBytes, value.byteCount * 2)
    queue.finish(active); queue.finish(queue.take()!)
    XCTAssertNil(queue.take()); XCTAssertEqual(queue.snapshot.queuedBytes, 0)
    XCTAssertTrue(queue.offer(value, key: key), "A drained mailbox permits a new wake-up")
  }

  func testFilenameInventoryOnlyShortCircuitsKnownMissesAndPublishesNewWrites() {
    let queue = TerrainDiskWriteQueue(limitBytes: 1_024, limitEntries: 2)
    XCTAssertFalse(queue.definitelyAbsent("a"), "Uninitialized disk inventory needs one actor scan")
    queue.publish(.init(), names: ["a"])
    XCTAssertFalse(queue.definitelyAbsent("a")); XCTAssertTrue(queue.definitelyAbsent("b"))
    XCTAssertEqual(queue.snapshot.misses, 1)
    queue.publish(.init(), names: ["a", "b"])
    XCTAssertFalse(queue.definitelyAbsent("b"), "A completed write becomes available to subsequent reads")
    queue.publish(.init(), names: nil)
    XCTAssertFalse(queue.definitelyAbsent("a"), "Metrics-only publication preserves known membership")
    XCTAssertTrue(queue.definitelyAbsent("c"))
    XCTAssertEqual(queue.snapshot.misses, 2)
    queue.insertName("c"); queue.removeName("a")
    XCTAssertFalse(queue.definitelyAbsent("c"), "An incremental write becomes readable")
    XCTAssertTrue(queue.definitelyAbsent("a"), "An evicted entry becomes a known miss")
    queue.publish(.init(), names: nil)
    XCTAssertFalse(queue.definitelyAbsent("b")); XCTAssertFalse(queue.definitelyAbsent("c"))
    XCTAssertTrue(queue.definitelyAbsent("a"))
  }

  func testGeneratedPayloadRoundTripsAcrossAllPlanetStyles() throws {
    for style in PlanetStyle.allCases {
      let terrain = TerrainGenerator(seed: 31_913, style: style)
      for tile in [TerrainTile(x: -2, z: -3, fullDetail: true), .init(x: -32, z: 32, size: 32)] {
        let r = TerrainPreparationRequest(id: .init(world: UUID(), tile: tile, revision: 0, lush: true),
          terrain: terrain, edits: [.init(-31, 60, -46): .torch, .init(-30, 61, -46): .woodStairsEast],
          service: .detail, priority: 0)
        let key = TerrainPayloadKey(r), original = try XCTUnwrap(TerrainPreparation.build(r, collision: { _ in }))
        let previousFilename = SHA256.hash(data: TerrainPayloadCodec.keyData(key))
          .map { String(format: "%02x", $0) }.joined() + ".wcterrain"
        XCTAssertEqual(TerrainPayloadCodec.filename(key), previousFilename,
          "Existing cache filenames must remain reusable")
        let data = try XCTUnwrap(TerrainPayloadCodec.encode(original, key: key))
        let decoded = try XCTUnwrap(TerrainPayloadCodec.decode(data, key: key, id: r.id), "\(style), \(tile)")
        same(original.mesh, decoded.mesh)
        XCTAssertEqual(TerrainPayloadCodec.encode(decoded, key: key), data)
      }
    }
  }

  func testRestartReusesDiskWithCurrentIdentityAndCorruptEntryRegenerates() async throws {
    let root = try folder(), cache = TerrainDiskCache(root: root)
    let first = request(seed: 833_017), key = TerrainPayloadKey(first)
    let built = await TerrainPreparation.prepare(first, cache: .init(), disk: cache, collision: { _ in })
    let original = try XCTUnwrap(built)
    let stored = await eventually { cache.snapshot.writes == 1 && cache.snapshot.queuedWrites == 0 }
    XCTAssertTrue(stored)
    let restart = TerrainDiskCache(root: root), next = request(seed: 833_017)
    let loaded = await TerrainPreparation.prepare(next, cache: .init(), disk: restart, collision: { _ in })
    let hit = try XCTUnwrap(loaded)
    XCTAssertNotNil(hit.stages["disk_cache_hit"]); XCTAssertEqual(hit.id, next.id)
    same(original.mesh, hit.mesh); XCTAssertEqual(original.chunk?.archiveCells, hit.chunk?.archiveCells)
    XCTAssertEqual(restart.snapshot.hits, 1)
    XCTAssertEqual(restart.snapshot.mainThreadViolations + cache.snapshot.mainThreadViolations, 0)
    try Data([1, 2, 3]).write(to: root.appendingPathComponent(TerrainPayloadCodec.filename(key)))
    let broken = TerrainDiskCache(root: root)
    let repaired = await TerrainPreparation.prepare(next, cache: .init(), disk: broken, collision: { _ in })
    let rebuilt = try XCTUnwrap(repaired)
    XCTAssertNil(rebuilt.stages["disk_cache_hit"]); XCTAssertEqual(broken.snapshot.invalid, 1)
    same(original.mesh, rebuilt.mesh)
    let repairedOnDisk = await eventually { broken.snapshot.writes == 1 && broken.snapshot.queuedWrites == 0 }
    XCTAssertTrue(repairedOnDisk)
  }

  func testLRUEvictionAndUnavailableCacheDoNotAffectGeneration() async throws {
    let root = try folder(), cache = TerrainDiskCache(root: root, limitEntries: 2)
    let requests = [request(x: 0), request(x: 1), request(x: 2)]
    for r in requests.prefix(2) {
      cache.enqueue(fixture(r), key: TerrainPayloadKey(r))
      let done = await eventually { cache.snapshot.queuedWrites == 0 }
      XCTAssertTrue(done)
    }
    let touched = await cache.value(for: TerrainPayloadKey(requests[0]), id: requests[0].id)
    XCTAssertNotNil(touched)
    cache.enqueue(fixture(requests[2]), key: TerrainPayloadKey(requests[2]))
    let done = await eventually { cache.snapshot.writes == 3 && cache.snapshot.queuedWrites == 0 }
    XCTAssertTrue(done); XCTAssertEqual(cache.snapshot.evictions, 1); XCTAssertEqual(cache.snapshot.entries, 2)
    let evicted = await cache.value(for: TerrainPayloadKey(requests[1]), id: requests[1].id)
    XCTAssertNil(evicted); XCTAssertLessThanOrEqual(cache.snapshot.bytes, cache.snapshot.limitBytes)
    let fileRoot = root.appendingPathComponent("not-a-directory")
    try Data([0]).write(to: fileRoot)
    let unavailable = TerrainDiskCache(root: fileRoot)
    let generated = await TerrainPreparation.prepare(request(seed: 833_018), cache: .init(), disk: unavailable, collision: { _ in })
    XCTAssertNotNil(generated); XCTAssertGreaterThan(unavailable.snapshot.failures, 0)
    let drained = await eventually { unavailable.snapshot.queuedWrites == 0 }; XCTAssertTrue(drained)
  }

  func testAdmissionKeepsDetailedAndExpensiveSurfacesWithoutChargingCacheWaits() async throws {
    let cache = TerrainDiskCache(root: try folder(), compressionEnabled: true,
      minimumSurfacePreparationSeconds: 0.001)
    let r = request()
    let surface = TerrainPreparationRequest(id: .init(world: UUID(),
      tile: .init(x: -2, z: -1), revision: 0, lush: false), terrain: r.terrain,
      service: .refinement, priority: 0)
    let key = TerrainPayloadKey(surface)
    let inexpensive = PreparedTerrainTile(id: surface.id, mesh: .init(.init()),
      stages: ["surface": 0.0003, "packing": 0.0002, "cache_lookup": 3])
    cache.enqueue(inexpensive, key: key)
    XCTAssertEqual(cache.snapshot.inexpensiveSurfaceWritesSkipped, 1)
    XCTAssertEqual(cache.snapshot.queuedWrites, 0)

    let expensive = PreparedTerrainTile(id: surface.id, mesh: .init(.init()),
      stages: ["surface": 0.0007, "packing": 0.0004])
    cache.enqueue(expensive, key: key)
    let surfaceStored = await eventually { cache.snapshot.writes == 1 && cache.snapshot.queuedWrites == 0 }
    XCTAssertTrue(surfaceStored)
    let retrieved = await cache.value(for: key, id: surface.id)
    XCTAssertNotNil(retrieved, "Expensive distant geometry remains eligible for return reuse")

    // Detailed voxel payloads remain eligible even when no timings are supplied.
    cache.enqueue(fixture(r), key: .init(r))
    let detailStored = await eventually { cache.snapshot.writes == 2 && cache.snapshot.queuedWrites == 0 }
    XCTAssertTrue(detailStored)
    XCTAssertEqual(cache.snapshot.inexpensiveSurfaceWritesSkipped, 1)
    XCTAssertEqual(cache.snapshot.minimumSurfacePreparationMilliseconds, 1)
    XCTAssertEqual(cache.snapshot.mainThreadViolations, 0)
  }

  func testByteQuotaAndStartupEvictionIgnoreUnrelatedFiles() async throws {
    let root = try folder(), r = request(), key = TerrainPayloadKey(r)
    let data = try XCTUnwrap(TerrainPayloadCodec.encode(fixture(r), key: key))
    try data.write(to: root.appendingPathComponent(TerrainPayloadCodec.filename(key)))
    let unrelated = root.appendingPathComponent("keep.txt")
    try Data([4]).write(to: unrelated)
    let cache = TerrainDiskCache(root: root, limitBytes: data.count - 1)
    let result = await cache.value(for: key, id: r.id)
    XCTAssertNil(result); XCTAssertEqual(cache.snapshot.bytes, 0); XCTAssertEqual(cache.snapshot.evictions, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    cache.enqueue(fixture(r), key: key)
    let skipped = await eventually { cache.snapshot.oversized == 1 && cache.snapshot.queuedWrites == 0 }
    XCTAssertTrue(skipped); XCTAssertEqual(cache.snapshot.writes, 0)
  }

  func testAuthoritativeSnapshotBypassesDiskAndCancellationCannotPublish() async throws {
    let cache = TerrainDiskCache(root: try folder()), r = request(seed: 833_019)
    var chunk = ChunkData(coordinate: r.id.tile.coordinate); chunk[1, 80, 1] = .glass
    let supplied = TerrainPreparationRequest(id: r.id, terrain: r.terrain, cachedChunk: chunk, service: .detail, priority: 0)
    let result = await TerrainPreparation.prepare(supplied, cache: .init(), disk: cache, collision: { _ in })
    XCTAssertEqual(result?.chunk?[1, 80, 1], .glass)
    XCTAssertEqual(cache.snapshot.hits + cache.snapshot.misses + cache.snapshot.queuedWrites, 0)
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await TerrainPreparation.prepare(r, cache: .init(), disk: cache, collision: { _ in XCTFail("Cancelled collision") })
    }
    let empty = await cancelled.value; XCTAssertNil(empty)
    XCTAssertEqual(cache.snapshot.hits + cache.snapshot.misses + cache.snapshot.queuedWrites, 0)
  }

  func testCompressedDiskRestartPreservesFullPayloadAndHonorsStoredByteQuota() async throws {
    let root = try folder(), first = request(), key = TerrainPayloadKey(first), original = fixture(first)
    let raw = try XCTUnwrap(TerrainPayloadCodec.encode(original, key: key))
    let compressed = TerrainArchiveCompression.encode(raw)
    XCTAssertLessThan(compressed.count, raw.count)
    let writer = TerrainDiskCache(root: root, limitBytes: compressed.count + 8, limitEntries: 3, compressionEnabled: true)
    writer.enqueue(original, key: key)
    let finished = await eventually { writer.snapshot.writes == 1 && writer.snapshot.queuedWrites == 0 }
    XCTAssertTrue(finished); XCTAssertEqual(writer.snapshot.compressedWrites, 1)
    XCTAssertEqual(writer.snapshot.bytes, compressed.count); XCTAssertEqual(writer.snapshot.rawWriteBytes, raw.count)
    XCTAssertEqual(writer.snapshot.limitEntries, 3)
    // A reader with raw writes selected can still load compressed existing data.
    let restart = TerrainDiskCache(root: root), next = request()
    let loaded = await restart.value(for: key, id: next.id), copy = try XCTUnwrap(loaded)
    same(copy.mesh, original.mesh); same(try XCTUnwrap(copy.animated), try XCTUnwrap(original.animated))
    XCTAssertEqual(copy.chunk?.archiveCells, original.chunk?.archiveCells)
    XCTAssertEqual(copy.water.samples.map(\.position), original.water.samples.map(\.position))
    XCTAssertEqual(copy.plants, original.plants); XCTAssertEqual(copy.lamps, original.lamps)
    XCTAssertEqual(TerrainPayloadCodec.encode(copy, key: key), raw)
    // Same byte quota applies during startup inventory; no compressed entry
    // can pin a file larger than the configured stored budget.
    let tooSmall = TerrainDiskCache(root: root, limitBytes: compressed.count - 1, compressionEnabled: true)
    let missing = await tooSmall.value(for: key, id: next.id)
    XCTAssertNil(missing); XCTAssertEqual(tooSmall.snapshot.bytes, 0)
    XCTAssertEqual(writer.snapshot.mainThreadViolations + restart.snapshot.mainThreadViolations + tooSmall.snapshot.mainThreadViolations, 0)
  }

  func testCachedTerrainLoadsWhileAnotherArchiveIsEncoding() async throws {
    try await assertReadsDuringStalledWrite(encoding: true)
  }

  func testCachedTerrainLoadsWhileAnotherAtomicFileWriteIsStalled() async throws {
    try await assertReadsDuringStalledWrite(encoding: false)
  }

  private func assertReadsDuringStalledWrite(encoding: Bool) async throws {
    let root = try folder(), cached = request(x: 0), key = TerrainPayloadKey(cached)
    let original = fixture(cached)
    let bytes = try XCTUnwrap(TerrainPayloadCodec.encode(original, key: key))
    try bytes.write(to: root.appendingPathComponent(TerrainPayloadCodec.filename(key)))
    let gate = WriteGate(), readCompletion = ReadCompletion()
    defer { gate.release() }
    let writer = TerrainArchiveWriter(encode: { payload, key in
      if encoding { gate.block() }
      return TerrainPayloadCodec.encode(payload, key: key)
    }, write: { data, url in
      if !encoding { gate.block() }
      try data.write(to: url, options: .atomic)
    })
    let cache = TerrainDiskCache(root: root, limitEntries: 3, writeLimitEntries: 2,
      compressionEnabled: true, writer: writer)
    let initial = await cache.value(for: key, id: cached.id)
    XCTAssertNotNil(initial)
    let first = request(x: 1), second = request(x: 2), refused = request(x: 3)
    cache.enqueue(fixture(first), key: .init(first))
    let blocked = await eventually { gate.isBlocked }
    XCTAssertTrue(blocked)
    cache.enqueue(fixture(first), key: .init(first))
    cache.enqueue(fixture(second), key: .init(second))
    cache.enqueue(fixture(refused), key: .init(refused))
    XCTAssertEqual(cache.snapshot.queuedWrites, 2, "Active work remains in the bounded queue")
    XCTAssertEqual(cache.snapshot.coalescedWrites, 1)
    XCTAssertEqual(cache.snapshot.droppedWrites, 1)
    XCTAssertEqual(cache.snapshot.entries, 1, "Incomplete writes are not readable entries")
    let incomplete = await cache.value(for: .init(first), id: first.id)
    XCTAssertNil(incomplete)
    let read = Task {
      let value = await cache.value(for: key, id: cached.id)
      readCompletion.finish()
      return value
    }
    let readFinishedBeforeRelease = await eventually { readCompletion.isFinished }
    XCTAssertTrue(readFinishedBeforeRelease, "A cached tile must not wait for archive writeback")
    XCTAssertTrue(gate.isBlocked)
    gate.release()
    let hit = await read.value
    XCTAssertEqual(hit.flatMap { TerrainPayloadCodec.encode($0, key: key) }, bytes)
    let finished = await eventually { cache.snapshot.queuedWrites == 0 }
    XCTAssertTrue(finished)
    XCTAssertEqual(cache.snapshot.writes, 2)
    XCTAssertEqual(cache.snapshot.queuedBytes, 0)
    XCTAssertEqual(cache.snapshot.entries, 3)
    XCTAssertLessThanOrEqual(cache.snapshot.bytes, cache.snapshot.limitBytes)
    XCTAssertEqual(cache.snapshot.archiveEncodingCPU.count, 2)
    XCTAssertEqual(cache.snapshot.fileWriteCPU.count, 2)
    XCTAssertEqual(cache.snapshot.writebackLatency.count, 2)
    XCTAssertEqual(cache.snapshot.readQueueWait.count, 2)
    XCTAssertEqual(cache.snapshot.mainThreadViolations, 0)
    for r in [first, second] {
      let stored = await cache.value(for: .init(r), id: r.id)
      let expected = TerrainPayloadCodec.encode(fixture(r), key: .init(r))
      XCTAssertEqual(stored.flatMap { TerrainPayloadCodec.encode($0, key: .init(r)) }, expected)
    }
  }

  func testReadDuringEncodingRefreshesRecencyBeforeWriteReservesCapacity() async throws {
    let root = try folder(), a = request(x: 0), b = request(x: 1), c = request(x: 2)
    for r in [a, b] {
      let data = try XCTUnwrap(TerrainPayloadCodec.encode(fixture(r), key: .init(r)))
      try data.write(to: root.appendingPathComponent(TerrainPayloadCodec.filename(.init(r))))
    }
    let gate = WriteGate(), completion = ReadCompletion()
    defer { gate.release() }
    let cache = TerrainDiskCache(root: root, limitEntries: 2, writer: .init(encode: { value, key in
      gate.block(); return TerrainPayloadCodec.encode(value, key: key)
    }))
    _ = await cache.value(for: .init(a), id: a.id)
    _ = await cache.value(for: .init(b), id: b.id)
    cache.enqueue(fixture(c), key: .init(c))
    let blocked = await eventually { gate.isBlocked }; XCTAssertTrue(blocked)
    let read = Task {
      let hit = await cache.value(for: .init(a), id: a.id)
      completion.finish(); return hit
    }
    let completed = await eventually { completion.isFinished }; XCTAssertTrue(completed)
    gate.release()
    let hit = await read.value; XCTAssertNotNil(hit)
    let finished = await eventually { cache.snapshot.queuedWrites == 0 }; XCTAssertTrue(finished)
    let kept = await cache.value(for: .init(a), id: a.id)
    let evicted = await cache.value(for: .init(b), id: b.id)
    let added = await cache.value(for: .init(c), id: c.id)
    XCTAssertNotNil(kept); XCTAssertNil(evicted); XCTAssertNotNil(added)
    XCTAssertEqual(cache.snapshot.evictions, 1); XCTAssertEqual(cache.snapshot.entries, 2)
  }

  func testFailedWriteDoesNotPublishAndTheNextQueuedWriteStillFinishes() async throws {
    let root = try folder(), bad = request(x: 0), good = request(x: 1)
    let badName = TerrainPayloadCodec.filename(.init(bad))
    let cache = TerrainDiskCache(root: root, writer: .init(write: { data, url in
      if url.lastPathComponent == badName { throw CocoaError(.fileWriteUnknown) }
      try data.write(to: url, options: .atomic)
    }))
    cache.enqueue(fixture(bad), key: .init(bad))
    cache.enqueue(fixture(good), key: .init(good))
    let finished = await eventually { cache.snapshot.queuedWrites == 0 }; XCTAssertTrue(finished)
    XCTAssertEqual(cache.snapshot.failures, 1); XCTAssertEqual(cache.snapshot.writes, 1)
    XCTAssertEqual(cache.snapshot.entries, 1); XCTAssertEqual(cache.snapshot.queuedBytes, 0)
    let absent = await cache.value(for: .init(bad), id: bad.id)
    let present = await cache.value(for: .init(good), id: good.id)
    XCTAssertNil(absent)
    XCTAssertEqual(present.flatMap { TerrainPayloadCodec.encode($0, key: .init(good)) },
      TerrainPayloadCodec.encode(fixture(good), key: .init(good)))
  }
}
