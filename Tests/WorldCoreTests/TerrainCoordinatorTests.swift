import Foundation
import XCTest
@testable import WorldCore

final class TerrainCoordinatorTests: XCTestCase, @unchecked Sendable {
  private let world = UUID()
  private func requests(_ count: Int, incarnation: UInt64 = 0) -> [TerrainPreparationRequest] {
    (0..<count).map { n in
      .init(id: .init(world: world, tile: .init(x: n, z: 0, fullDetail: true), revision: 0,
        lush: false, incarnation: incarnation), terrain: .init(seed: 9),
        service: TerrainWorkClass.allCases[n % TerrainWorkClass.allCases.count], priority: n)
    }
  }
  private func eventually(_ predicate: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<200 {
      if predicate() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
  }

  func testWorkerRefillAndCollisionDoNotRequireRenderFrames() async {
    let exchange = TerrainStreamingExchange()
    let coordinator = TerrainStreamingCoordinator(exchange: exchange, workers: 2, preparedLimit: 6) { request, publish in
      publish(.init(coordinate: request.id.tile.coordinate))
      return .init(id: request.id, mesh: .init(.init()))
    }
    let demand = requests(20)
    exchange.expect(demand, sequence: 1)
    coordinator.wake()
    let filled = await eventually { exchange.occupancy.tiles == 6 && exchange.metrics.completedTotal == 6 && exchange.counts.workers == 0 }
    XCTAssertTrue(filled)
    XCTAssertEqual(exchange.metrics.completedTotal, 6)
    XCTAssertEqual(exchange.takeCollisions().count, 6)
    XCTAssertEqual(exchange.counts.workers, 0)
    // One render-frame publication frees one slot. Refill continues on its actor.
    XCTAssertNotNil(exchange.takeReady())
    coordinator.wake()
    let refilled = await eventually { exchange.metrics.completedTotal == 7 }
    XCTAssertTrue(refilled)
    XCTAssertEqual(exchange.occupancy.tiles, 6)
    exchange.expect([], sequence: 2)
    await coordinator.update([], sequence: 2)
  }

  func testCancellationAndReentryCannotExceedWorkerLimitOrPublishObsoleteWorld() async {
    let probe = BlockingProbe()
    defer { probe.release() }
    let exchange = TerrainStreamingExchange()
    let coordinator = TerrainStreamingCoordinator(exchange: exchange, workers: 2, preparedLimit: 8) { request, _ in
      probe.build(id: request.id)
      return .init(id: request.id, mesh: .init(.init()))
    }
    let old = requests(4), new = requests(4, incarnation: 1)
    exchange.expect(old, sequence: 1); await coordinator.update(old, sequence: 1)
    let started = await eventually { probe.count == 2 }
    XCTAssertTrue(started)
    exchange.expect([], sequence: 2); await coordinator.update([], sequence: 2)
    exchange.expect(new, sequence: 3); await coordinator.update(new, sequence: 3)
    XCTAssertEqual(probe.count, 2)
    XCTAssertEqual(exchange.counts.workers, 2, "Cancelled jobs own their slots until they return")
    probe.release()
    let finished = await eventually { exchange.occupancy.tiles == 4 }
    XCTAssertTrue(finished)
    XCTAssertEqual(probe.peak, 2)
    for _ in 0..<4 { XCTAssertEqual(exchange.takeReady()?.id.incarnation, 1) }
    XCTAssertNil(exchange.takeReady())
    XCTAssertEqual(exchange.metrics.discardedTotal, 2)
    // Late actor messages and stale publications cannot resurrect old demand.
    exchange.expect(old, sequence: 1); await coordinator.update(old, sequence: 1)
    XCTAssertFalse(exchange.accepts(old[0].id))
    XCTAssertTrue(exchange.accepts(new[0].id))
    XCTAssertFalse(exchange.publish(.init(id: old[0].id, mesh: .init(.init()))))
  }

  func testByteBackpressurePausesProducersButAllowsOversizedResultToProgress() async {
    let exchange = TerrainStreamingExchange()
    let coordinator = TerrainStreamingCoordinator(exchange: exchange, workers: 2, preparedLimit: 8,
      byteLimit: 100) { request, _ in
      var mesh = VoxelMesh()
      mesh.appendBox(size: [1, 1, 1], center: .zero, material: 0)
      return .init(id: request.id, mesh: .init(mesh))
    }
    let demand = requests(20)
    exchange.expect(demand, sequence: 1); await coordinator.update(demand, sequence: 1)
    let paused = await eventually { exchange.counts.workers == 0 && exchange.occupancy.bytes > 100 }
    XCTAssertTrue(paused)
    XCTAssertLessThanOrEqual(exchange.occupancy.tiles, 2)
    XCTAssertNil(exchange.takeReady(maximumBytes: 100))
    XCTAssertNotNil(exchange.takeReady())
    exchange.expect([], sequence: 2); await coordinator.update([], sequence: 2)
  }

  func testEveryServiceClassGetsWorkEvenWhenLocalDetailIsContinuouslyRequested() {
    var demand = requests(40), turn = 0, seen: [TerrainWorkClass] = []
    for _ in 0..<12 {
      let next = TerrainServiceOrder.next(demand, turn: &turn)!
      seen.append(next.service); demand.removeAll { $0.id == next.id }
    }
    for service in TerrainWorkClass.allCases { XCTAssertTrue(seen.prefix(6).contains(service)) }
    XCTAssertEqual(seen.filter { $0 == .coverage }.count, 4)
    let urgent = demand[0], older = demand[4]
    let sameClass = [urgent, older]
    let aged = TerrainServiceOrder.next(sameClass, turn: &turn,
      enqueued: [urgent.id: 9, older.id: 1], now: 10)
    XCTAssertEqual(aged?.id, older.id)
  }

  func testDemandMailboxKeepsOnlyLatestFrameAndCoalescesWakeups() {
    let exchange = TerrainStreamingExchange()
    for sequence in 1...500 {
      exchange.expect(requests(2, incarnation: UInt64(sequence)), sequence: UInt64(sequence))
      XCTAssertEqual(exchange.reserveNotification(), sequence == 1)
    }
    guard case let .demand(latest, sequence)? = exchange.nextUpdate() else {
      return XCTFail("Latest demand was lost")
    }
    XCTAssertEqual(sequence, 500)
    XCTAssertEqual(latest.count, 2)
    XCTAssertEqual(latest[0].id.incarnation, 500)
    XCTAssertNil(exchange.nextUpdate())
    XCTAssertTrue(exchange.reserveNotification())
    guard case .resume? = exchange.nextUpdate() else { return XCTFail("Publication feedback was lost") }
    XCTAssertNil(exchange.nextUpdate())
  }
}

private final class BlockingProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var started = 0, active = 0, maximum = 0
  var count: Int { lock.withLock { started } }
  var peak: Int { lock.withLock { maximum } }
  func build(id: TerrainWorkID) {
    lock.withLock { started += 1; active += 1; maximum = max(maximum, active) }
    if id.incarnation == 0 { semaphore.wait() }
    lock.withLock { active -= 1 }
  }
  func release() { semaphore.signal(); semaphore.signal() }
}
