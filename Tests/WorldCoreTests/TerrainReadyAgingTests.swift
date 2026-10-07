import Foundation
import XCTest
@testable import WorldCore

final class TerrainReadyAgingTests: XCTestCase {
  private let world = UUID()
  private func request(_ x: Int, priority: Int = 0, service: TerrainWorkClass = .detail,
    incarnation: UInt64 = 0) -> TerrainPreparationRequest {
    .init(id: .init(world: world,tile: .init(x: x,z: 0,fullDetail: true),revision: 0,
      lush: false,incarnation: incarnation),terrain: .init(seed: 8),service: service,priority: priority)
  }
  private func result(_ request: TerrainPreparationRequest, large: Bool = false) -> PreparedTerrainTile {
    guard large else { return .init(id: request.id,mesh: .init(.init())) }
    let vertex = TerrainVertex(position: .zero,normal: [0,1,0],uv: .zero,
      tangent: [1,0,0],bitangent: [0,0,1])
    return .init(id: request.id,mesh: .init(vertices: .init(repeating: vertex,count: 65),
      indices: [0,1,2],parts: [.init(offset: 0,count: 3,material: 0,minimum: .zero,maximum: .one)]))
  }
  func testNewNearResultsCannotIndefinitelyPassAnOldReadyTile() {
    func selectedAt(aging: Bool) -> Double? {
      let exchange = TerrainStreamingExchange(agingReadyResults: aging)
      let far = request(-1,priority: 1_000_000)
      exchange.expect([far],sequence: 0); XCTAssertTrue(exchange.publish(result(far),at: 0))
      for n in 1...80 {
        let now = Double(n)*0.1, near = request(n)
        exchange.expect([far,near],sequence: UInt64(n))
        XCTAssertTrue(exchange.publish(result(near),at: now))
        XCTAssertEqual(exchange.occupancy.tiles,2)
        let selected = exchange.takeReady(at: now)
        if selected?.id == far.id { return now }
        XCTAssertEqual(selected?.id,near.id)
      }
      return nil
    }
    XCTAssertNil(selectedAt(aging: false),"The comparison demonstrates the old starvation behavior")
    let age = selectedAt(aging: true)
    XCTAssertNotNil(age); XCTAssertGreaterThan(age ?? 0,2); XCTAssertLessThanOrEqual(age ?? 100,2.2)
  }
  func testAgingPreservesCollisionCoverageAndDetailServiceOpportunities() {
    let exchange = TerrainStreamingExchange()
    let old = request(-1,priority: 999,service: .refinement)
    var pending = [old]
    exchange.expect(pending,sequence: 0); XCTAssertTrue(exchange.publish(result(old),at: 0))
    var expected: [TerrainWorkClass] = [.collision,.coverage,.detail,.coverage,.refinement,.detail]
    for n in 0..<6 {
      let now = 10+Double(n)*0.1
      for (index,service) in TerrainWorkClass.allCases.enumerated() where service != .refinement {
        let fresh = request(n*10+index,service: service)
        pending.append(fresh)
      }
      exchange.expect(pending,sequence: UInt64(n+1))
      // Refreshing an existing ID must not erase its original queue arrival.
      for request in pending where request.id != old.id {
        XCTAssertTrue(exchange.publish(result(request),at: now))
      }
      let chosen = exchange.takeReady(at: now)!
      let served = pending.first { $0.id == chosen.id }!.service
      XCTAssertEqual(served,expected.removeFirst())
      if served == .refinement { XCTAssertEqual(chosen.id,old.id) }
      pending.removeAll { $0.id == chosen.id }
    }
  }
  func testReprioritizationAndDuplicatePublicationKeepOriginalReadyAge() {
    let exchange = TerrainStreamingExchange(), old = request(0,priority: 40)
    exchange.expect([old],sequence: 1); XCTAssertTrue(exchange.publish(result(old),at: 0))
    let changed = request(0,priority: 1_000), fresh = request(1)
    exchange.expect([changed,fresh],sequence: 2)
    XCTAssertTrue(exchange.publish(result(changed),at: 1.9))
    XCTAssertTrue(exchange.publish(result(fresh),at: 2))
    XCTAssertEqual(exchange.takeReady(at: 2.1)?.id,old.id)
    XCTAssertEqual(exchange.metrics.maximumReadyWaitMilliseconds,2_100,accuracy: 0.00001)
    XCTAssertEqual(exchange.metrics.agedPublications,1)
    let reentered = request(0,priority: 1_000,incarnation: 1)
    exchange.expect([fresh,reentered],sequence: 3)
    XCTAssertTrue(exchange.publish(result(reentered),at: 2.1))
    XCTAssertEqual(exchange.takeReady(at: 2.2)?.id,fresh.id)
    XCTAssertEqual(exchange.takeReady(at: 2.2)?.id,reentered.id)
    XCTAssertEqual(exchange.metrics.maximumReadyWaitMilliseconds,2_100,accuracy: 0.00001)
  }
  func testInvalidationAndWorldChangeRemoveReadyAgeAndPayloadTogether() {
    let exchange = TerrainStreamingExchange(), old = request(0), other = request(1)
    exchange.expect([old,other],sequence: 1)
    XCTAssertTrue(exchange.publish(result(old,large: true),at: 0))
    XCTAssertTrue(exchange.publish(result(other,large: true),at: 0))
    XCTAssertGreaterThan(exchange.occupancy.bytes,0)
    exchange.invalidate(old.id.tile)
    XCTAssertFalse(exchange.publish(result(old),at: 1))
    exchange.expect([],sequence: 2)
    XCTAssertEqual(exchange.occupancy.tiles,0); XCTAssertEqual(exchange.occupancy.bytes,0)
    XCTAssertEqual(exchange.metrics.oldestReadyMilliseconds,0)
    XCTAssertNil(exchange.takeReady(at: 10))
    exchange.expect([old],sequence: 1) // An obsolete actor update cannot restore old work.
    XCTAssertFalse(exchange.publish(result(old),at: 10))
    let nextWorld = TerrainPreparationRequest(id: .init(world: UUID(),tile: old.id.tile,
      revision: 0,lush: false,incarnation: 0),terrain: .init(seed: 10),service: .detail,priority: 0)
    exchange.expect([nextWorld],sequence: 3)
    XCTAssertFalse(exchange.publish(result(old),at: 10))
    XCTAssertTrue(exchange.publish(result(nextWorld),at: 10))
    XCTAssertEqual(exchange.takeReady(at: 10.1)?.id,nextWorld.id)
    XCTAssertEqual(exchange.metrics.maximumReadyWaitMilliseconds,100,accuracy: 0.00001)
    XCTAssertEqual(exchange.metrics.agedPublications,0)
  }
  func testAgedLargeResultRetainsItsPlaceUntilNativeCapacityDrains() {
    let exchange = TerrainStreamingExchange(), old = request(0,priority: 999), small = request(1)
    let large = result(old,large: true), charge = large.publicationByteCount(reuseMeshes: true)
    exchange.expect([old,small],sequence: 1)
    XCTAssertTrue(exchange.publish(large,at: 0)); XCTAssertTrue(exchange.publish(result(small),at: 2))
    XCTAssertNil(exchange.takeReady(maximumPublicationBytes: charge-1,at: 2.1))
    XCTAssertEqual(exchange.occupancy.tiles,2); XCTAssertEqual(exchange.metrics.nativeCapacityDeferrals,1)
    XCTAssertEqual(exchange.takeReady(maximumPublicationBytes: charge,at: 2.2)?.id,old.id)
    XCTAssertEqual(exchange.takeReady(at: 2.2)?.id,small.id)
    // The ordinary per-frame byte filter is still honored. A subsequent first
    // result gets the unchanged unlimited-byte progress opportunity.
    exchange.expect([old,small],sequence: 2)
    XCTAssertTrue(exchange.publish(large,at: 0)); XCTAssertTrue(exchange.publish(result(small),at: 2))
    XCTAssertEqual(exchange.takeReady(maximumBytes: 1,at: 3)?.id,small.id)
    XCTAssertEqual(exchange.takeReady(at: 3)?.id,old.id)
  }
  func testQueueWaitUsesPublicationTimeAndRetainsTheLifetimeMaximum() throws {
    let exchange = TerrainStreamingExchange(), item = request(0)
    let prepared = result(item)
    exchange.expect([item],sequence: 1)
    XCTAssertTrue(exchange.publish(prepared,at: 50))
    XCTAssertEqual(exchange.takeReady(at: 51.25)?.id,item.id)
    let firstMaximum = try XCTUnwrap(exchange.metrics.readyWait.maxMilliseconds)
    XCTAssertEqual(firstMaximum,1_250,accuracy: 0.00001)
    XCTAssertEqual(exchange.metrics.maximumReadyWaitMilliseconds,1_250,accuracy: 0.00001)
    XCTAssertTrue(exchange.metrics.readyAgingEnabled)
    for i in 0..<300 {
      XCTAssertTrue(exchange.publish(prepared,at: 60+Double(i)))
      XCTAssertNotNil(exchange.takeReady(at: 60+Double(i)+0.01))
    }
    let recentMaximum = try XCTUnwrap(exchange.metrics.readyWait.maxMilliseconds)
    XCTAssertLessThan(recentMaximum,11)
    XCTAssertEqual(exchange.metrics.maximumReadyWaitMilliseconds,1_250,accuracy: 0.00001)
  }
}
