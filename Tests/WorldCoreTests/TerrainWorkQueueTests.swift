import Foundation
import XCTest
@testable import WorldCore

final class TerrainWorkQueueTests: XCTestCase, @unchecked Sendable {
  private let world = UUID()
  private func requests(_ count: Int, incarnation: UInt64 = 0) -> [TerrainPreparationRequest] {
    (0..<count).map { n in
      .init(id: .init(world: world,tile: .init(x: n-700,z: n%7,fullDetail: true),revision: 0,
        lush: false,incarnation: incarnation),terrain: .init(seed: 9),
        service: TerrainWorkClass.allCases[n%4],priority: (n*83)%1_009)
    }
  }
  func testExactLegacySelectionAcrossAgingAndAllServiceClasses() {
    var pending = requests(997), turn = 0, legacyTurn = 0
    let ages = Dictionary(uniqueKeysWithValues: pending.enumerated().map { ($0.element.id,Double($0.offset%13)*0.21) })
    var queue = TerrainWorkQueue(pending,enqueued: ages,now: 0)
    for step in 0..<997 {
      let now = Double(step)*0.011
      let expected = TerrainServiceOrder.next(pending,turn: &legacyTurn,enqueued: ages,now: now)!
      let selected = queue.next(turn: &turn,now: now,accepts: { _ in true })
      XCTAssertEqual(selected,expected.id,"Mismatch at selection \(step)")
      XCTAssertEqual(turn,legacyTurn)
      pending.removeAll { $0.id == expected.id }
      XCTAssertEqual(queue.count,pending.count)
      let summary = queue.summary(now: now)
      for service in TerrainWorkClass.allCases {
        let members = pending.filter { $0.service == service }
        XCTAssertEqual(summary.counts[service.rawValue] ?? 0,members.count)
        let oldest = members.map { max(0,now-ages[$0.id]!)*1_000 }.max() ?? 0
        XCTAssertEqual(summary.ages[service.rawValue] ?? 0,oldest,accuracy: 1e-8)
      }
    }
    XCTAssertNil(queue.next(turn: &turn,now: 100,accepts: { _ in true }))
  }
  func testInvalidationBeforeActorUpdateDoesNotSpendServiceOpportunities() {
    let all = requests(120), accepted = Set(all.enumerated().filter { $0.offset%3 == 0 }.map { $0.element.id })
    var pending = all.filter { accepted.contains($0.id) }, turn = 2, legacyTurn = 2
    let ages = Dictionary(uniqueKeysWithValues: all.map { ($0.id,Double($0.priority)/1_000) })
    var queue = TerrainWorkQueue(all,enqueued: ages,now: 0)
    while !pending.isEmpty {
      let expected = TerrainServiceOrder.next(pending,turn: &legacyTurn,enqueued: ages,now: 4)!
      XCTAssertEqual(queue.next(turn: &turn,now: 4,accepts: { accepted.contains($0) }),expected.id)
      XCTAssertEqual(turn,legacyTurn)
      pending.removeAll { $0.id == expected.id }
    }
    XCTAssertNil(queue.next(turn: &turn,now: 4,accepts: { accepted.contains($0) }))
    XCTAssertEqual(queue.count,0)
  }
  func testRebuildReprioritizesCurrentDemandAndRetryDoesNotDuplicate() {
    let old = requests(80), replacement = requests(90,incarnation: 1)
    var queue = TerrainWorkQueue(old,enqueued: [:],now: 0), turn = 0
    for _ in 0..<12 { _ = queue.next(turn: &turn,now: 1,accepts: { _ in true }) }
    let updated = replacement.map { r in
      TerrainPreparationRequest(id: r.id,terrain: r.terrain,service: .coverage,priority: -r.priority)
    }
    queue = .init(updated,enqueued: [:],now: 2)
    let first = queue.next(turn: &turn,now: 2,accepts: { _ in true })!
    let retry = updated.first { $0.id == first }!
    queue.insert(retry,enqueued: 2); queue.insert(retry,enqueued: 2)
    XCTAssertEqual(queue.count,90)
    var result: [TerrainWorkID] = []
    while let next = queue.next(turn: &turn,now: 2,accepts: { _ in true }) { result.append(next) }
    XCTAssertEqual(result,updated.sorted { $0.priority < $1.priority }.map(\.id))
    XCTAssertEqual(Set(result).count,result.count)
    queue = .init([],enqueued: [:],now: 3)
    XCTAssertNil(queue.next(turn: &turn,now: 3,accepts: { _ in true }))
  }
  func testFailedBuilderRetriesWithoutWaitingForAnotherSceneFrame() async {
    final class Counter: @unchecked Sendable {
      let lock = NSLock()
      var attempts: [TerrainWorkID: Int] = [:]
      func first(_ id: TerrainWorkID) -> Bool { lock.withLock {
        attempts[id,default: 0] += 1; return attempts[id] == 1
      } }
    }
    let counter = Counter(), exchange = TerrainStreamingExchange()
    let coordinator = TerrainStreamingCoordinator(exchange: exchange,workers: 2,preparedLimit: 8) { request,_ in
      if counter.first(request.id) { return nil }
      return .init(id: request.id,mesh: .init(.init()))
    }
    let demand = requests(6)
    exchange.expect(demand,sequence: 1); await coordinator.update(demand,sequence: 1)
    for _ in 0..<200 where exchange.occupancy.tiles < 6 { try? await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(exchange.occupancy.tiles,6); XCTAssertEqual(exchange.metrics.discardedTotal,6)
    XCTAssertTrue(exchange.metrics.indexedWorkQueue)
    var ids = Set<TerrainWorkID>()
    while let next = exchange.takeReady() { ids.insert(next.id) }
    XCTAssertEqual(ids,Set(demand.map(\.id)))
    exchange.expect([],sequence: 2); await coordinator.update([],sequence: 2)
    XCTAssertEqual(exchange.counts.queued,0)
  }
}
