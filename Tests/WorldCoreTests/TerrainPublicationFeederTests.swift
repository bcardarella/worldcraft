import Foundation
import XCTest
@testable import WorldCore

@MainActor private final class PreparationGate {
  private var waits: [CheckedContinuation<Void, Never>] = []
  var count: Int { waits.count }
  func wait() async { await withCheckedContinuation { waits.append($0) } }
  func release() { let old = waits; waits.removeAll(); old.forEach { $0.resume() } }
}

@MainActor final class TerrainPublicationFeederTests: XCTestCase {
  private func requests(_ count: Int, world: UUID = UUID()) -> [TerrainPreparationRequest] {
    (0..<count).map { n in
      .init(id: .init(world: world,tile: .init(x: n,z: 0,fullDetail: true),revision: 0,
        lush: false,incarnation: 0),terrain: .init(seed: 9),service: .detail,priority: n)
    }
  }
  private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<1_000 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
  }
  func testWorkersAndNativePreparationRefillWithoutAnySceneCallbacks() async {
    let exchange = TerrainStreamingExchange()
    let coordinator = TerrainStreamingCoordinator(exchange: exchange) { input,_ in
      .init(id: input.id,mesh: .init(.init()))
    }
    let queue = TerrainPublicationQueue<TerrainWorkID>(maximumRunning: 4,maximumEntries: 8,
      prepare: { input in try await Task.sleep(for: .milliseconds(1)); return input.id }, discard: { _ in })
    let feeder = TerrainPublicationFeeder(exchange: exchange,queue: queue,
      permits: { true },current: { exchange.accepts($0) },retry: { _ in XCTFail("Unexpected rejection") },
      resumeWorkers: { coordinator.wake() })
    let demand = requests(40)
    exchange.expect(demand,sequence: 1); coordinator.wake()
    let full = await eventually { queue.counts.ready == 8 && exchange.occupancy.tiles == 8 }
    XCTAssertTrue(full); XCTAssertEqual(feeder.metrics.frameRefills,0)
    XCTAssertEqual(queue.metrics.peakEntries,8); XCTAssertEqual(feeder.metrics.admitted,8)
    // Adoption releases backpressure. No refill() or coordinator.resume() calls
    // are needed; completion, takeReady and the real worker signals drive it.
    var adopted = Set<TerrainWorkID>()
    let drained = await eventually {
      while let item = queue.takeReady() {
        XCTAssertTrue(adopted.insert(try! item.result.get()).inserted)
      }
      return adopted.count == demand.count
    }
    XCTAssertTrue(drained); XCTAssertEqual(adopted,Set(demand.map(\.id)))
    XCTAssertEqual(feeder.metrics.readyToAdmission.count,40)
    XCTAssertEqual(queue.metrics.retainedBytes,0)
    XCTAssertEqual(exchange.occupancy.tiles,0)
    exchange.expect([],sequence: 2); await coordinator.update([],sequence: 2)
  }
  func testExistingReadyWorkAndRetirementRecoveryCannotLoseWakeups() async {
    let exchange = TerrainStreamingExchange(), demand = requests(3)
    exchange.expect(demand,sequence: 1)
    for input in demand { XCTAssertTrue(exchange.publish(.init(id: input.id,mesh: .init(.init())))) }
    var permits = false
    let queue = TerrainPublicationQueue<Int>(maximumRunning: 1,maximumEntries: 1,
      prepare: { $0.tile.x },discard: { _ in })
    let feeder = TerrainPublicationFeeder(exchange: exchange,queue: queue,
      permits: { permits },current: { exchange.accepts($0) },retry: { _ in XCTFail() },resumeWorkers: {})
    let observed = await eventually { feeder.metrics.eventRefills > 0 }
    XCTAssertTrue(observed); XCTAssertEqual(queue.metrics.admitted,0)
    permits = true; feeder.wake() // Same transition emitted by resource retirement.
    let first = await eventually { queue.counts.ready == 1 }
    XCTAssertTrue(first); XCTAssertEqual(try? queue.takeReady()?.result.get(),0)
    let second = await eventually { queue.counts.ready == 1 }
    XCTAssertTrue(second); XCTAssertEqual(try? queue.takeReady()?.result.get(),1)
    let third = await eventually { queue.counts.ready == 1 }
    XCTAssertTrue(third); XCTAssertEqual(try? queue.takeReady()?.result.get(),2)
    XCTAssertEqual(feeder.metrics.admitted,3); XCTAssertEqual(feeder.metrics.frameRefills,0)
  }
  func testWorldResetKeepsCanceledNativeSlotsUntilTheyReturn() async {
    let gate = PreparationGate(), exchange = TerrainStreamingExchange()
    let old = requests(2), next = requests(2)
    var discarded = Set<TerrainWorkID>()
    let queue = TerrainPublicationQueue<TerrainWorkID>(maximumRunning: 2,maximumEntries: 2,
      prepare: { input in await gate.wait(); return input.id },discard: { discarded.insert($0) })
    let feeder = TerrainPublicationFeeder(exchange: exchange,queue: queue,
      permits: { true },current: { exchange.accepts($0) },retry: { _ in XCTFail() },resumeWorkers: {})
    exchange.expect(old,sequence: 1)
    for input in old { XCTAssertTrue(exchange.publish(.init(id: input.id,mesh: .init(.init())))) }
    let started = await eventually { gate.count == 2 }; XCTAssertTrue(started)
    exchange.expect(next,sequence: 2); queue.retain { exchange.accepts($0) }
    for input in next { XCTAssertTrue(exchange.publish(.init(id: input.id,mesh: .init(.init())))) }
    feeder.refill()
    XCTAssertEqual(queue.metrics.running,2); XCTAssertEqual(feeder.metrics.admitted,2)
    XCTAssertFalse(exchange.publish(.init(id: old[0].id,mesh: .init(.init()))))
    gate.release()
    let restarted = await eventually { discarded.count == 2 && gate.count == 2 }
    XCTAssertTrue(restarted); XCTAssertEqual(discarded,Set(old.map(\.id)))
    XCTAssertEqual(queue.metrics.peakEntries,2)
    gate.release()
    let finished = await eventually { queue.counts.ready == 2 }; XCTAssertTrue(finished)
    var adopted = Set<TerrainWorkID>()
    while let item = queue.takeReady() { adopted.insert(try! item.result.get()) }
    XCTAssertEqual(adopted,Set(next.map(\.id))); XCTAssertEqual(feeder.metrics.admitted,4)
  }
  func testFrameDrivenControlRetainsPreviousAdmissionBehavior() async {
    let exchange = TerrainStreamingExchange(), demand = requests(2)
    let queue = TerrainPublicationQueue<Int>(maximumRunning: 1,maximumEntries: 2,
      prepare: { $0.tile.x },discard: { _ in })
    let feeder = TerrainPublicationFeeder(exchange: exchange,queue: queue,independent: false,
      permits: { true },current: { exchange.accepts($0) },retry: { _ in XCTFail() },resumeWorkers: {})
    exchange.expect(demand,sequence: 1)
    for input in demand { XCTAssertTrue(exchange.publish(.init(id: input.id,mesh: .init(.init())))) }
    feeder.wake(); await Task.yield()
    XCTAssertEqual(queue.metrics.admitted,0)
    feeder.refill()
    let first = await eventually { queue.counts.ready == 1 }; XCTAssertTrue(first)
    XCTAssertEqual(queue.metrics.admitted,1); XCTAssertEqual(exchange.occupancy.tiles,1)
    feeder.refill()
    let second = await eventually { queue.counts.ready == 2 }; XCTAssertTrue(second)
    XCTAssertEqual(feeder.metrics.eventRefills,0); XCTAssertEqual(feeder.metrics.frameRefills,2)
  }
  func testNotificationStormIsCoalescedAndConsumerDoesNotRetainOwner() async {
    let exchange = TerrainStreamingExchange()
    let queue = TerrainPublicationQueue<Int>(prepare: { $0.tile.x },discard: { _ in })
    var feeder: TerrainPublicationFeeder<Int>? = .init(exchange: exchange,queue: queue,
      permits: { true },current: { _ in false },retry: { _ in XCTFail() },resumeWorkers: {})
    for _ in 0..<10_000 { feeder?.wake() }
    let delivered = await eventually { feeder!.metrics.eventRefills > 0 }; XCTAssertTrue(delivered)
    XCTAssertEqual(feeder?.metrics.eventRefills,1)
    weak var weakFeeder = feeder
    feeder = nil
    XCTAssertNil(weakFeeder)
  }
}
