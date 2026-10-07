import Foundation
import XCTest
@testable import WorldCore

final class TerrainTravelPrefetchTests: XCTestCase {
  private func tile(_ x: Int) -> TerrainTile { .init(x: x,z: 0,fullDetail: true) }

  func testPendingWorkAndRealCompletionsDrivePredictionWithoutCountingReadyHits() {
    let world = UUID(), wanted: Set<TerrainTile> = [tile(0),tile(1),tile(2)]
    var forecast = TerrainTravelPrefetch()
    forecast.observe(world: world,target: wanted,visible: [tile(0)],time: 0)
    XCTAssertEqual(forecast.metrics.pendingTiles,2)
    XCTAssertEqual(forecast.metrics.sampleCount,0)
    forecast.observe(world: world,target: wanted,visible: [tile(0)],time: 3)
    XCTAssertEqual(forecast.metrics.predictionSeconds,3.5)
    forecast.observe(world: world,target: wanted,visible: wanted,time: 4)
    XCTAssertEqual(forecast.metrics.completionP95Milliseconds,4_000)
    XCTAssertEqual(forecast.metrics.sampleCount,2)
    XCTAssertEqual(forecast.metrics.predictionSeconds,4.5)
    forecast.observe(world: world,target: wanted,visible: wanted,time: 5)
    XCTAssertEqual(forecast.metrics.sampleCount,2,"Already-published detail does not bias the delay toward zero")
    XCTAssertEqual(forecast.metrics.pendingTiles,0)
  }

  func testOldMeasurementsExpireAndCancelledDemandDoesNotRemainPending() {
    let world = UUID(), wanted: Set<TerrainTile> = [tile(0),tile(1)]
    var forecast = TerrainTravelPrefetch()
    forecast.observe(world: world,target: wanted,visible: [],time: 0)
    forecast.observe(world: world,target: [tile(1)],visible: [],time: 3)
    XCTAssertEqual(forecast.metrics.cancelledTotal,1)
    XCTAssertEqual(forecast.metrics.pendingTiles,1)
    forecast.observe(world: world,target: [tile(1)],visible: [tile(1)],time: 4)
    forecast.observe(world: world,target: [],visible: [],time: 35)
    XCTAssertEqual(forecast.metrics.sampleCount,0)
    XCTAssertEqual(forecast.metrics.completionP95Milliseconds,0)
    XCTAssertGreaterThan(forecast.metrics.predictionSeconds,2.5,"Short cache-hit spells must not thrash the ahead region")
    for t in 36...48 { forecast.observe(world: world,target: [],visible: [],time: Double(t)) }
    XCTAssertEqual(forecast.metrics.predictionSeconds,2.5)
    forecast.observe(world: UUID(),target: wanted,visible: [],time: 49)
    XCTAssertEqual(forecast.metrics.cancelledTotal,0)
    XCTAssertEqual(forecast.metrics.completedTotal,0)
    XCTAssertEqual(forecast.metrics.oldestPendingMilliseconds,0)
  }

  func testCompletionHistoryAndLeadAreBoundedIncludingInvalidInput() {
    var forecast = TerrainTravelPrefetch()
    let world = UUID(), wanted = Set((0..<500).map(tile))
    forecast.observe(world: world,target: wanted,visible: [],time: 0)
    forecast.observe(world: world,target: wanted,visible: wanted,time: 20)
    XCTAssertEqual(forecast.metrics.sampleCount,128)
    XCTAssertEqual(forecast.metrics.completedTotal,500)
    XCTAssertEqual(forecast.metrics.predictionSeconds,6)
    let center = ChunkCoordinate(-12,24)
    for velocity: SIMD3<Float> in [[100,0,0],[100,0,100],[-100,0,100],[.greatestFiniteMagnitude,0,.greatestFiniteMagnitude]] {
      let ahead = forecast.lookAhead(from: center,velocity: velocity,detailRadius: 16)
      XCTAssertLessThanOrEqual(ahead.distanceSquared(to: center),144)
      XCTAssertTrue(forecast.metrics.leadLimited)
    }
    for enabled in [false,true] {
      var candidate = TerrainTravelPrefetch(enabled: enabled)
      XCTAssertEqual(candidate.lookAhead(from: center,velocity: [.nan,0,1],detailRadius: 16),center)
      XCTAssertEqual(candidate.lookAhead(from: center,velocity: [0,0,.infinity],detailRadius: 16),center)
      let large = candidate.lookAhead(from: center,velocity: [.greatestFiniteMagnitude,0,0],detailRadius: 16)
      XCTAssertLessThanOrEqual(large.distanceSquared(to: center),144)
    }
  }

  func testPredictionIsStableAtQuantizationBoundaryButTurnsAndStopsImmediately() {
    var forecast = TerrainTravelPrefetch()
    let center = ChunkCoordinate(0,0)
    let first = forecast.lookAhead(from: center,velocity: [18,0,0],detailRadius: 16)
    for speed: Float in [19,19.3,18.8,19.2,18.9] {
      XCTAssertEqual(forecast.lookAhead(from: center,velocity: [speed,0,0],detailRadius: 16),first)
    }
    let reverse = forecast.lookAhead(from: center,velocity: [-32,0,0],detailRadius: 16)
    XCTAssertLessThan(reverse.x,0)
    XCTAssertEqual(forecast.lookAhead(from: center,velocity: .zero,detailRadius: 16),center)
  }

  func testLegacyComparisonAndWorldReset() {
    var forecast = TerrainTravelPrefetch(enabled: false)
    let center = ChunkCoordinate(-18,50)
    for velocity: SIMD3<Float> in [[0,0,0],[6,0,-9],[32,12,18],[-200,3,-200]] {
      XCTAssertEqual(forecast.lookAhead(from: center,velocity: velocity,detailRadius: 16),
        TerrainStreamingPlan.lookAhead(from: center,velocity: velocity))
    }
    forecast.observe(world: UUID(),target: [tile(0)],visible: [],time: 0)
    forecast.reset()
    XCTAssertFalse(forecast.metrics.enabled); XCTAssertEqual(forecast.metrics.pendingTiles,0)
    XCTAssertEqual(forecast.metrics.sampleCount,0)
  }

  func testTravelPreferencePreservesBaseHorizonAndNearDetailInEveryDirection() {
    for center in [ChunkCoordinate(0,0),.init(-65,127)] {
      for radius in [4,6,8,16,32,128] {
        let detail = min(16,radius)
        let baseline = TerrainStreamingPlan(center: center,radius: radius,detailRadius: detail).tiles
        let anchor = TerrainStreamingPlan.anchor(for: center,radius: radius)
        for adaptive in [false,true] {
          for velocity: SIMD3<Float> in [[100,0,0],[-100,0,0],[0,0,100],[70,0,-70]] {
            var forecast = TerrainTravelPrefetch(enabled: adaptive)
            let ahead = forecast.lookAhead(from: anchor,velocity: velocity,detailRadius: detail)
            let plan = TerrainStreamingPlan(center: center,radius: radius,detailRadius: detail,lookAhead: ahead).tiles
            let index = TerrainOverlapIndex(plan)
            for leaf in baseline {
              let replacements = index.overlapping(leaf)
              let area = replacements.reduce(0) { total, other in
                total + max(0,min(leaf.x+leaf.size,other.x+other.size)-max(leaf.x,other.x))
                  * max(0,min(leaf.z+leaf.size,other.z+other.size)-max(leaf.z,other.z))
              }
              XCTAssertEqual(area,leaf.size*leaf.size,"Prefetch may refine but must not shrink horizon coverage")
              if leaf.fullDetail { XCTAssertTrue(plan.contains(leaf),"Baseline detailed circle must remain exact") }
            }
          }
        }
      }
    }
  }

  func testFastTravelRequestsDetailSoonerWithModeledTwoSecondPublication() {
    // Actual plans and predictor, fixed virtual publication delay. This is a
    // policy regression, not a model of GPU or native throughput.
    func run(adaptive: Bool) -> (missing: Int, peak: Int) {
      let world = UUID()
      var forecast = TerrainTravelPrefetch(enabled: adaptive)
      var visible = TerrainStreamingPlan(center: .init(0,0),radius: 128,detailRadius: 16).tiles
      var requested: [TerrainTile: Double] = [:]
      var missing = 0, peak = 0
      for frame in 0..<120 {
        let now = Double(frame)*0.25
        let center = ChunkCoordinate(frame,0), anchor = TerrainStreamingPlan.anchor(for: center,radius: 128)
        let ahead = forecast.lookAhead(from: anchor,velocity: [64,0,0],detailRadius: 16)
        let target = TerrainStreamingPlan(center: center,radius: 128,detailRadius: 16,lookAhead: ahead).tiles
        requested = requested.filter { target.contains($0.key) }
        visible.formIntersection(target)
        for tile in target where !visible.contains(tile) {
          if let began = requested[tile], now-began >= 2 { visible.insert(tile); requested[tile] = nil }
          else if requested[tile] == nil { requested[tile] = now }
        }
        peak = max(peak,target.filter(\.fullDetail).count)
        if frame > 24 {
          let needed = TerrainStreamingPlan(center: center,radius: 128,detailRadius: 16).tiles.filter(\.fullDetail)
          missing += needed.filter { !visible.contains($0) }.count
        }
        forecast.observe(world: world,target: target,visible: visible,time: now)
      }
      return (missing,peak)
    }
    let fixed = run(adaptive: false), adaptive = run(adaptive: true)
    XCTAssertLessThan(adaptive.missing,fixed.missing)
    XCTAssertGreaterThan(adaptive.peak,fixed.peak,"Earlier readiness has a declared additional preparation/residency cost")
  }

  func testSpeculativePriorityCannotHoldRequiredSiblingsBehindTheirParent() {
    let center = ChunkCoordinate(0,0), ahead = ChunkCoordinate(30,0)
    let parent = TerrainTile(x: 20,z: 0,size: 2)
    let children = Set((20...21).flatMap { x in (0...1).map { TerrainTile(x: x,z: $0,fullDetail: true) } })
    let future = TerrainTile(x: 30,z: 0,fullDetail: true), collision = tile(0)
    let needed = TerrainTile(x: 20,z: 0,fullDetail: true)
    let desired = children.union([future,collision])
    let optional = desired.subtracting([needed])
    let ordering = TerrainWorkPriority.streaming(desired: desired,available: [parent],
      center: center,lookAhead: ahead,speculative: optional)
    XCTAssertEqual(ordering.services[future],.refinement)
    XCTAssertEqual(ordering.services[collision],.collision)
    for child in children { XCTAssertEqual(ordering.services[child],.detail) }
    XCTAssertGreaterThan(ordering.ranks[future]!,ordering.ranks[needed]!)
  }
}
