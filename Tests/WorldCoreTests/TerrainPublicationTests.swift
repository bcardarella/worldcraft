import XCTest
@testable import WorldCore

@MainActor private final class NativeResourceGate {
  private var continuations: [CheckedContinuation<Void, Never>] = []
  var waiting: Int { continuations.count }
  func suspend() async { await withCheckedContinuation { continuations.append($0) } }
  func release() { let old = continuations; continuations.removeAll(); old.forEach { $0.resume() } }
}

@MainActor final class TerrainPublicationTests: XCTestCase {
  private func input(_ index: Int, world: UUID = UUID(), revision: Int = 0) -> PreparedTerrainTile {
    .init(id: .init(world: world, tile: .init(x: index, z: 0, size: 1, fullDetail: true),
      revision: revision, lush: false, incarnation: UInt64(revision)), mesh: .init(VoxelMesh()))
  }
  private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<300 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
  }
  func testCheapReadyResultsCanUseTheExistingEightEntryQueue() async throws {
    for limit in [4, 8] {
      let queue = TerrainPublicationQueue<Int>(maximumRunning: 4, maximumEntries: 8,
        prepare: { $0.tile.x }, discard: { _ in })
      for batch in 0..<2 {
        for n in 0..<4 { XCTAssertTrue(queue.admit(input(batch * 4 + n), bytes: 100)) }
        let ready = await eventually { queue.counts.ready == (batch + 1) * 4 }
        XCTAssertTrue(ready)
      }
      var budget = StreamingBudget(maximumTiles: limit), received: Set<Int> = []
      var elapsed = 0.0
      while budget.allowsNextTile(elapsed: elapsed, published: received.count,
        bytes: received.count * 100, urgent: false), let next = queue.takeReady() {
        XCTAssertTrue(received.insert(try next.result.get()).inserted)
        elapsed += 0.00015; budget.recordTile(seconds: 0.00015)
      }
      budget.recordFrame(published: received.count, bytes: received.count * 100,
        remainingReady: queue.counts.ready)
      XCTAssertEqual(received.count, limit)
      XCTAssertEqual(queue.counts.ready, 8 - limit)
      XCTAssertEqual(queue.metrics.peakEntries, 8)
      XCTAssertEqual(queue.metrics.maximumRunning, 4)
      XCTAssertEqual(queue.metrics.retainedBytes, (8 - limit) * 100)
      XCTAssertEqual(queue.metrics.failed, 0)
      XCTAssertLessThanOrEqual(elapsed, 0.0022)
      XCTAssertEqual(budget.metrics.countLimitWithReadyFrames, limit == 4 ? 1 : 0)
    }
  }
  func testBufferCopiesShareATimeBudgetAndResumeWithoutAFrameCallback() {
    var budget = TerrainBufferBudget(interval: 0.01, budget: 0.002)
    var copies = 0, now = 0.0
    while budget.delay(at: now) == 0 && copies < 20 {
      budget.record(seconds: 0.0004); now += 0.0004; copies += 1
    }
    XCTAssertGreaterThan(copies, 1); XCTAssertLessThanOrEqual(copies, 5)
    let delay = budget.delay(at: now)
    XCTAssertGreaterThan(delay, 0)
    // An independent timer wakes the waiter; an overloaded scene doesn't have
    // to deliver a frame just to restart native resource preparation.
    XCTAssertEqual(budget.delay(at: now + delay + 0.000001), 0)
  }
  func testSingleSlowBufferCannotAdmitAnotherBurstInTheSameWindow() {
    var budget = TerrainBufferBudget(interval: 0.01, budget: 0.002)
    XCTAssertEqual(budget.delay(at: 0), 0)
    budget.record(seconds: 0.007)
    XCTAssertGreaterThan(budget.delay(at: 0.007), 0)
    XCTAssertGreaterThan(budget.delay(at: 0.009), 0)
    XCTAssertEqual(budget.delay(at: 0.01001), 0)
    // Non-finite telemetry cannot poison admission and lock the stage forever.
    budget.record(seconds: .infinity); budget.record(seconds: .nan)
    XCTAssertEqual(budget.delay(at: 0.01001), 0)
  }
  func testSuspendedResourcesDoNotBlockFrameAndStayChargedUntilAdoption() async throws {
    let gate = NativeResourceGate()
    let queue = TerrainPublicationQueue<Int>(prepare: { input in
      await gate.suspend(); return input.tile.x
    }, discard: { _ in XCTFail("Current output discarded") })
    XCTAssertTrue(queue.admit(input(1), bytes: 100))
    XCTAssertTrue(queue.admit(input(2), bytes: 200))
    let started = await eventually { gate.waiting == 2 }; XCTAssertTrue(started)
    XCTAssertFalse(queue.admit(input(3), bytes: 10))
    let frame = Task { @MainActor in queue.metrics.running == 2 && queue.metrics.ready == 0 }
    let responsive = await frame.value; XCTAssertTrue(responsive)
    XCTAssertEqual(queue.metrics.retainedBytes, 300)
    gate.release()
    let finished = await eventually { queue.metrics.ready == 2 }; XCTAssertTrue(finished)
    XCTAssertEqual(queue.metrics.running, 0)
    XCTAssertEqual(queue.metrics.retainedBytes, 300)
    var adopted = Set<Int>()
    while let ready = queue.takeReady() { adopted.insert(try ready.result.get()) }
    XCTAssertEqual(adopted, [1, 2]); XCTAssertEqual(queue.metrics.retainedBytes, 0)
  }
  func testWorldResetDoesNotFreeUncooperativeFrameworkReservations() async {
    let gate = NativeResourceGate()
    var discarded: [UUID] = []
    let queue = TerrainPublicationQueue<UUID>(maximumRunning: 1, maximumEntries: 1,
      prepare: { input in await gate.suspend(); return input.id.world }, discard: { discarded.append($0) })
    let old = input(0), next = input(0)
    XCTAssertTrue(queue.admit(old, bytes: 70))
    let started = await eventually { gate.waiting == 1 }; XCTAssertTrue(started)
    queue.retain { _ in false }
    XCTAssertEqual(queue.metrics.running, 1); XCTAssertEqual(queue.metrics.retainedBytes, 70)
    XCTAssertFalse(queue.admit(next, bytes: 70))
    gate.release()
    let finished = await eventually { queue.metrics.running == 0 }; XCTAssertTrue(finished)
    XCTAssertEqual(discarded, [old.id.world]); XCTAssertNil(queue.takeReady())
    XCTAssertEqual(queue.metrics.retainedBytes, 0)
    XCTAssertTrue(queue.admit(next, bytes: 70))
    let restarted = await eventually { gate.waiting == 1 }; XCTAssertTrue(restarted)
    gate.release()
    let ready = await eventually { queue.metrics.ready == 1 }; XCTAssertTrue(ready)
    XCTAssertEqual(try? queue.takeReady()?.result.get(), next.id.world)
  }
  func testEditedRevisionWinsLateCompletionAndReadyInvalidationDiscardsResources() async {
    let oldGate = NativeResourceGate(), world = UUID()
    let old = input(3, world: world), edited = input(3, world: world, revision: 1)
    var discarded: [Int] = []
    let queue = TerrainPublicationQueue<Int>(prepare: { input in
      if input.revision == 0 { await oldGate.suspend() }
      return input.revision
    }, discard: { discarded.append($0) })
    XCTAssertTrue(queue.admit(old, bytes: 80))
    let started = await eventually { oldGate.waiting == 1 }; XCTAssertTrue(started)
    queue.retain { $0 == edited.id }
    XCTAssertTrue(queue.admit(edited, bytes: 80))
    let ready = await eventually { queue.metrics.ready == 1 }; XCTAssertTrue(ready)
    let adopted = queue.takeReady()
    XCTAssertEqual(adopted?.input.id, edited.id); XCTAssertEqual(try? adopted?.result.get(), 1)
    oldGate.release()
    let finished = await eventually { queue.metrics.running == 0 }; XCTAssertTrue(finished)
    XCTAssertEqual(discarded, [0]); XCTAssertNil(queue.takeReady())
    XCTAssertTrue(queue.admit(input(4, revision: 2), bytes: 80))
    let otherReady = await eventually { queue.metrics.ready == 1 }; XCTAssertTrue(otherReady)
    queue.retain { _ in false }
    XCTAssertEqual(discarded, [0, 2]); XCTAssertEqual(queue.metrics.retainedBytes, 0)
  }
  func testReadyResultsApplyCountAndByteBackpressure() async {
    let queue = TerrainPublicationQueue<Int>(maximumRunning: 2, maximumEntries: 3, byteWatermark: 100,
      prepare: { $0.tile.x }, discard: { _ in })
    XCTAssertTrue(queue.admit(input(0), bytes: 60))
    XCTAssertFalse(queue.admit(input(1), bytes: 41))
    XCTAssertTrue(queue.admit(input(1), bytes: 40))
    let ready = await eventually { queue.metrics.ready == 2 }; XCTAssertTrue(ready)
    XCTAssertEqual(queue.availableBytes, 0)
    XCTAssertFalse(queue.admit(input(2), bytes: 1))
    _ = queue.takeReady()
    XCTAssertTrue(queue.admit(input(2), bytes: 1))
    let again = await eventually { queue.metrics.ready == 2 }; XCTAssertTrue(again)
    XCTAssertTrue(queue.admit(input(3), bytes: 1))
    let full = await eventually { queue.metrics.ready == 3 }; XCTAssertTrue(full)
    XCTAssertFalse(queue.hasCapacity); XCTAssertFalse(queue.admit(input(4), bytes: 1))
    queue.retain { _ in false }; XCTAssertEqual(queue.metrics.retainedBytes, 0)
    XCTAssertEqual(queue.metrics.peakEntries, 3); XCTAssertEqual(queue.metrics.peakBytes, 100)
  }
  func testOneOversizedTileMakesProgressWithoutAdmittingCompanionsOrDuplicates() async {
    let gate = NativeResourceGate(), tile = input(0)
    let queue = TerrainPublicationQueue<Int>(byteWatermark: 100,
      prepare: { _ in await gate.suspend(); return 1 }, discard: { _ in })
    XCTAssertTrue(queue.admit(tile, bytes: 150))
    XCTAssertFalse(queue.admit(tile, bytes: 0)); XCTAssertFalse(queue.admit(input(1), bytes: 1))
    XCTAssertFalse(queue.admit(input(1), bytes: 0))
    let started = await eventually { gate.waiting == 1 }; XCTAssertTrue(started)
    gate.release()
    let ready = await eventually { queue.metrics.ready == 1 }; XCTAssertTrue(ready)
    XCTAssertFalse(queue.admit(input(1), bytes: 1))
    XCTAssertEqual(queue.metrics.oversized, 1); XCTAssertEqual(queue.metrics.retainedBytes, 150)
    _ = queue.takeReady()
    XCTAssertEqual(queue.availableBytes, .max)
  }
  func testFailureCanBeObservedAndRetriedWithoutDiscardingVisibleOwner() async {
    var fail = true, visible = 10
    let queue = TerrainPublicationQueue<Int>(prepare: { _ in
      if fail { throw CocoaError(.fileReadCorruptFile) }; return 20
    }, discard: { _ in XCTFail("No resources from failed preparation") })
    let tile = input(0)
    XCTAssertTrue(queue.admit(tile, bytes: 40))
    let failed = await eventually { queue.metrics.ready == 1 }; XCTAssertTrue(failed)
    if let entry = queue.takeReady(), case let .success(value) = entry.result { visible = value }
    XCTAssertEqual(visible, 10); XCTAssertEqual(queue.metrics.failed, 1)
    fail = false
    XCTAssertTrue(queue.admit(tile, bytes: 40))
    let ready = await eventually { queue.metrics.ready == 1 }; XCTAssertTrue(ready)
    if let entry = queue.takeReady(), case let .success(value) = entry.result { visible = value }
    XCTAssertEqual(visible, 20); XCTAssertEqual(queue.metrics.retainedBytes, 0)
  }
  func testRapidEditsAndWorldChangesCannotMultiplySuspendedWork() async {
    let gate = NativeResourceGate()
    var starts = 0, discarded = 0
    let queue = TerrainPublicationQueue<Int>(prepare: { _ in
      starts += 1; await gate.suspend(); return 0
    }, discard: { _ in discarded += 1 })
    XCTAssertTrue(queue.admit(input(0), bytes: 100)); XCTAssertTrue(queue.admit(input(1), bytes: 100))
    let started = await eventually { gate.waiting == 2 }; XCTAssertTrue(started)
    for i in 0..<500 {
      queue.retain { _ in false }
      XCTAssertFalse(queue.admit(input(i, revision: i), bytes: 100))
    }
    XCTAssertEqual(starts, 2); XCTAssertEqual(queue.metrics.peakEntries, 2)
    XCTAssertEqual(queue.metrics.retainedBytes, 200)
    gate.release()
    let finished = await eventually { queue.metrics.running == 0 }; XCTAssertTrue(finished)
    XCTAssertEqual(discarded, 2); XCTAssertEqual(queue.metrics.retainedBytes, 0)
  }
  func testNativeCapacityFilterLeavesUnadmittedCPUResultAvailable() {
    let vertex = TerrainVertex(position: .zero, normal: [0, 1, 0], uv: .zero,
      tangent: [1, 0, 0], bitangent: [0, 0, 1])
    let mesh = PackedTerrainMesh(vertices: .init(repeating: vertex, count: 65), indices: [0, 1, 2],
      parts: [.init(offset: 0, count: 3, material: 0, minimum: .zero, maximum: .one)])
    let tile = PreparedTerrainTile(id: input(0).id, mesh: mesh, animated: mesh)
    let capacity = TerrainMeshCapacity(vertices: 65, indices: 3)
    XCTAssertGreaterThanOrEqual(tile.publicationByteCount(reuseMeshes: true),
      tile.byteCount + capacity.bytes * 3 / 2 + mesh.byteCount)
    XCTAssertEqual(tile.publicationByteCount(reuseMeshes: false), tile.byteCount + 2 * mesh.byteCount)
    let exchange = TerrainStreamingExchange()
    let smaller = input(1)
    exchange.expect([
      .init(id: tile.id, terrain: .init(seed: 42), service: .coverage, priority: 0),
      .init(id: smaller.id, terrain: .init(seed: 42), service: .coverage, priority: 1),
    ], sequence: 1)
    XCTAssertTrue(exchange.publish(tile))
    XCTAssertTrue(exchange.publish(smaller))
    let charge = tile.publicationByteCount(reuseMeshes: true)
    XCTAssertNil(exchange.takeReady(maximumPublicationBytes: charge - 1))
    // Cheaper later arrivals cannot keep filling native slots and permanently
    // prevent the selected large tile from getting the empty-stage exception.
    XCTAssertEqual(exchange.occupancy.tiles, 2)
    XCTAssertEqual(exchange.takeReady(maximumPublicationBytes: charge)?.id, tile.id)
    XCTAssertEqual(exchange.takeReady()?.id, smaller.id)
    XCTAssertEqual(exchange.occupancy.tiles, 0)
  }
}
