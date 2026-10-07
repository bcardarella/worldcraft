import XCTest
import simd
@testable import WorldCore

final class WaterAnimationScheduleTests: XCTestCase {
  private typealias Scheduler = WaterAnimationSchedule
  private let front = Scheduler.View(eye: .zero, forward: [0, 0, -1])!
  private let rear = Scheduler.View(eye: .zero, forward: [0, 0, 1])!
  private func candidate(_ center: SIMD3<Float>, extent: SIMD3<Float> = [16, 10, 16], vertices: Int = 100) -> Scheduler.Candidate {
    .init(id: UUID(), bounds: .init(minimum: center - extent, maximum: center + extent), vertices: vertices)
  }
  private func settle(_ scheduler: inout Scheduler, _ candidates: [Scheduler.Candidate], from: Double = 0,
    view: Scheduler.View? = nil) -> Scheduler.Plan {
    var plan = scheduler.select(candidates, view: view ?? front, now: from, enabled: true)
    for step in 1...60 {
      plan = scheduler.select(candidates, view: view ?? front, now: from + Double(step) / 60, enabled: true)
    }
    return plan
  }

  func testRearBoundsNearWaterInvalidGeometryAndStereoMargin() {
    XCTAssertFalse(Scheduler.mayAffectView(candidate([0, 0, 500]).bounds, view: front))
    for c in [candidate([0, 0, -500]), candidate([500, 0, 0]), candidate([0, 0, 50]),
      candidate([0, 0, 500], extent: [600, 10, 600]), candidate([0, 600, 500], extent: [16, 800, 16])] {
      XCTAssertTrue(Scheduler.mayAffectView(c.bounds, view: front))
    }
    XCTAssertTrue(Scheduler.mayAffectView(.init(minimum: [.nan, 0, 0], maximum: [1, 1, 1]), view: front))
    XCTAssertTrue(Scheduler.mayAffectView(.init(minimum: [2, 2, 2], maximum: .zero), view: front))
    XCTAssertNil(Scheduler.View(eye: [.infinity, 0, 0], forward: [0, 0, -1]))
    XCTAssertNil(Scheduler.View(eye: .zero, forward: .zero))
    XCTAssertNil(Scheduler.View(eye: .zero, forward: [.nan, 0, -1]))
    XCTAssertEqual(Scheduler.View(eye: .zero, forward: [0, 0, -10])!.forward, front.forward)
  }

  func testEveryRejectedBoxCornerIsBehindAnIndependentlySampledWideStereoView() {
    var rejected = 0
    // Wide independent sample of stereo eye offsets and view rays, including
    // 110° off the central forward axis. Test world/bounds, not exact SDK optics.
    for azimuth in stride(from: Float(0), to: 2 * .pi, by: .pi / 24) {
      for elevation: Float in [-0.8, 0, 0.8] {
        let f = simd_normalize(SIMD3(cos(azimuth), elevation, sin(azimuth)))
        let view = Scheduler.View(eye: [17, -3, 9], forward: f)!
        for x in stride(from: -800, through: 800, by: 160) { for z in stride(from: -800, through: 800, by: 160) {
          let box = candidate([Float(x), 24, Float(z)], extent: [30, 12, 30]).bounds
          guard !Scheduler.mayAffectView(box, view: view) else { continue }
          rejected += 1
          for dx in [box.minimum.x, box.maximum.x] { for dy in [box.minimum.y, box.maximum.y] { for dz in [box.minimum.z, box.maximum.z] {
            for eyeOffset: Float in [-0.2, 0, 0.2] {
              let vector = simd_normalize(SIMD3(dx, dy, dz) - view.eye - [eyeOffset, 0, 0])
              XCTAssertLessThan(simd_dot(vector, f), cos(110 * .pi / 180))
            }
          } } }
        } }
      }
    }
    XCTAssertGreaterThan(rejected, 1000)
  }

  func testRetentionUrgencyRetriesAndPartialSubmission() {
    let a = candidate([0, 0, 500]), b = candidate([0, 0, 600], vertices: 200)
    var schedule = Scheduler()
    let initial = schedule.select([a, b], view: front, now: 0, enabled: true)
    XCTAssertEqual(initial.urgent, [a.id, b.id])
    schedule.didSubmit(initial, ids: [a.id])
    let pending = schedule.select([a, b], view: front, now: 0.01, enabled: true)
    XCTAssertEqual(pending.urgent, [b.id]) // GPU backpressure did not consume B.
    for step in 2...30 {
      XCTAssertEqual(schedule.select([a, b], view: front, now: Double(step) / 60, enabled: true).selected.count, 2)
    }
    let hidden = schedule.select([a, b], view: front, now: 0.52, enabled: true)
    XCTAssertTrue(hidden.selected.isEmpty)
    XCTAssertEqual(schedule.metrics.skippedVertices, 300)
    let returned = schedule.select([a, b], view: rear, now: 0.53, enabled: true)
    XCTAssertEqual(returned.urgent, [a.id, b.id])
    XCTAssertFalse(schedule.allowsPublication(initial, id: a.id))
    XCTAssertFalse(schedule.allowsPublication(initial, id: b.id))
    XCTAssertTrue(schedule.allowsPublication(returned, id: a.id))
    schedule.didSubmit(initial, ids: [a.id, b.id]) // Old CPU completion is stale for BOTH, including never-acknowledged B.
    XCTAssertEqual(schedule.select([a, b], view: rear, now: 0.531, enabled: true).urgent, returned.urgent)
    schedule.didSubmit(returned, ids: returned.selected)
    XCTAssertTrue(schedule.select([a, b], view: rear, now: 0.532, enabled: true).urgent.isEmpty)
    XCTAssertEqual(schedule.metrics.catchupBatchesTotal, 3)
  }

  func testFastTurnsTeleportLostTrackingAndTimeDiscontinuitiesKeepEverything() {
    let a = candidate([0, 0, 500]), b = candidate([0, 0, -500])
    var schedule = Scheduler()
    XCTAssertEqual(settle(&schedule, [a,b]).selected, [b.id])
    let turned = schedule.select([a,b], view: rear, now: 1.01, enabled: true)
    XCTAssertEqual(turned.selected, [a.id,b.id])
    _ = settle(&schedule, [a,b], from: 2, view: rear)
    XCTAssertEqual(schedule.select([a,b], view: nil, now: 3.01, enabled: true).selected.count, 2)
    _ = settle(&schedule, [a,b], from: 4)
    XCTAssertEqual(schedule.select([a,b], view: front, now: 6, enabled: true).selected.count, 2)
    _ = settle(&schedule, [a,b], from: 7)
    XCTAssertEqual(schedule.select([a,b], view: front, now: 0, enabled: true).selected.count, 2)
    _ = settle(&schedule, [a,b], from: 1)
    let teleported = Scheduler.View(eye: [100,0,0], forward: front.forward)!
    XCTAssertEqual(schedule.select([a,b], view: teleported, now: 2.01, enabled: true).selected.count, 2)
    XCTAssertEqual(schedule.select([a,b], view: front, now: .nan, enabled: true).selected.count, 2)
  }

  func testBaselineNeverCullsAndStateRemainsBoundedThroughRetirementAndReset() {
    var schedule = Scheduler()
    for i in 0..<500 {
      let c = candidate([0,0,500])
      _ = schedule.select([c], view: front, now: Double(i)/60, enabled: true)
      XCTAssertEqual(schedule.metrics.trackedBatches, 1)
    }
    let c = candidate([0,0,500])
    let old = schedule.select([c], view: front, now: 10, enabled: true)
    schedule.reset()
    _ = schedule.select([c], view: front, now: 10.1, enabled: true)
    XCTAssertFalse(schedule.allowsPublication(old, id: c.id))
    schedule.didSubmit(old, ids: old.selected)
    XCTAssertEqual(schedule.select([c], view: front, now: 10.2, enabled: true).urgent, [c.id])
    for time: Double in [10.3, 11, 20, .infinity] {
      let plan = schedule.select([c], view: front, now: time, enabled: false)
      XCTAssertEqual(plan.selected, [c.id]); XCTAssertTrue(plan.urgent.isEmpty)
      XCTAssertEqual(schedule.metrics.trackedBatches, 0)
    }
  }

  func testRecliningAndThirdPersonUseTheActualCalibratedWorldView() {
    for reference in [simd_quatf(angle: 0, axis: [1,0,0]), .init(angle: .pi/2, axis: [1,0,0]), .init(angle: .pi/2, axis: [0,0,1])] {
      let frame = PlayerFrame(referenceEye: [0,1,0], referenceOrientation: reference,
        feet: [100,30,-200], heading: .pi/3, pitch: 0.3, cameraOffset: [2,3,6])
      let head = reference * simd_quatf(angle: 0.2, axis: [0,1,0])
      let forward = frame.worldDirection(fromTracked: head.act([0,0,-1]))
      let eye = frame.worldPoint(fromTracked: [0.1,1.1,-0.1])
      let view = Scheduler.View(eye: eye, forward: forward)!
      let expected = simd_quatf(angle: frame.heading, axis: [0,1,0])
        * simd_quatf(angle: frame.pitch, axis: [1,0,0]) * simd_quatf(angle: 0.2, axis: [0,1,0])
      XCTAssertLessThan(simd_distance(view.forward, expected.act([0,0,-1])), 0.00001)
      XCTAssertTrue(Scheduler.mayAffectView(candidate(eye+forward*500).bounds, view: view))
      XCTAssertFalse(Scheduler.mayAffectView(candidate(eye-forward*500).bounds, view: view))
    }
  }

  func testHiddenRipplesCurrentClockAndReentryMatchContinuousWaterEvaluation() async {
    for body in [WaterBody.ocean, WaterBody(id: 34, kind: .lake, level: 20),
      WaterBody(id: 71, kind: .river, level: 12, current: [2,0,-1]), .lava] {
      let tile = TerrainTile(x: 0, z: 32, fullDetail: true)
      var geometry = WaterGeometry()
      geometry.samples = [[0,0],[0,16],[16,0],[16,16]].map { .init(position: $0, depth: 4, body: body) }
      geometry.shallowIndices = [0,1,2,2,1,3]
      let batch = WaterMeshBatch(key: .init(tile), geometry: [tile: geometry])
      let c = candidate(tile.origin + [8,body.level,8])
      var schedule = Scheduler(), environment = WorldEnvironment(elapsed: 9997), continuous = environment
      var skipped = 0
      for i in 0..<360 {
        for env in 0...1 {
          if env == 0 {
            environment.advance(1.0/60)
            if i == 0 || i == 320 { environment.disturbWater(atX: 0, z: 512, body: body) }
          } else {
            continuous.advance(1.0/60)
            if i == 0 || i == 320 { continuous.disturbWater(atX: 0, z: 512, body: body) }
          }
        }
        let plan = schedule.select([c], view: front, now: Double(i)/60, enabled: true)
        if plan.selected.isEmpty { skipped += 1 }
        else { schedule.didSubmit(plan, ids: plan.selected) }
        _ = batch.vertices(environment: continuous) // Reference renders throughout.
      }
      XCTAssertGreaterThan(skipped, 300)
      XCTAssertEqual(environment.disturbances.count, 1) // First wake expired while hidden.
      let plan = schedule.select([c], view: rear, now: 6, enabled: true)
      XCTAssertEqual(plan.urgent, [c.id])
      let actor = WaterMeshPreparation()
      let resumed = await actor.animate([c.id: batch], environment: environment)[c.id]!
      let reference = batch.vertices(environment: continuous)
      for (a,b) in zip(resumed, reference) {
        XCTAssertEqual(a.px,b.px); XCTAssertEqual(a.py,b.py); XCTAssertEqual(a.pz,b.pz)
        XCTAssertEqual(a.uv,b.uv); XCTAssertEqual(a.normal,b.normal); XCTAssertEqual(a.tangent,b.tangent)
        XCTAssertEqual(a.bitangent,b.bitangent); XCTAssertEqual(a.detailUV,b.detailUV); XCTAssertEqual(a.optics,b.optics)
      }
      schedule.didSubmit(plan, ids: plan.selected)
      // The world clock remains frozen during pause, but head turns still cause
      // one current-time publication without replaying any skipped simulation.
      XCTAssertTrue(schedule.select([c], view: rear, now: 6.001, enabled: true).urgent.isEmpty)
    }
  }

  func testDiagnosticModesAreIndependentLaunchOnlyAndDefaultToFullEffects() throws {
    let empty = RenderDiagnostics()
    XCTAssertEqual(empty, .init(arguments: ["Worldcraft", "--unknown", "--cull-rear-water-animation=false"]))
    let flags = ["--freeze-water-animation", "--freeze-wind-animation", "--disable-fire-particles",
      "--disable-local-lights", "--water-pbr", "--cull-rear-water-animation"]
    for flag in flags {
      let data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RenderDiagnostics(arguments: [flag]))) as! [String: Bool]
      XCTAssertEqual(data.values.filter { $0 }.count, 1)
    }
    let all = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RenderDiagnostics(arguments: flags))) as! [String: Bool]
    XCTAssertEqual(all.values.filter { $0 }.count, 6)
  }

  func testPartialWaterDrawBoundsContainDisplacedVerticesAcrossBodiesAndClockWraps() throws {
    let tiles = (0..<4).map { TerrainTile(x: -4+$0, z: 32, fullDetail: true) }
    for body in [WaterBody.ocean, WaterBody(id: 9, kind: .lake, level: 40),
      WaterBody(id: 27, kind: .river, level: 12, current: [1,0,-2]), .lava] {
      var geometry = WaterGeometry()
      geometry.samples = [[0,0],[0,16],[16,0],[16,16]].map { .init(position: $0, depth: 8, body: body) }
      geometry.shallowIndices = [0,1,2,2,1,3]
      let batch = WaterMeshBatch(key: .init(tiles[0]), geometry: Dictionary(uniqueKeysWithValues: tiles.map { ($0,geometry) }))
      let parts = batch.parts(visible: [tiles[0],tiles[2]], bands: [tiles[2]:12])
      let bounds = try XCTUnwrap(batch.animationBounds(for: parts))
      XCTAssertEqual(parts.reduce(0) { $0 + $1.indexCount }, 12)
      XCTAssertNil(batch.animationBounds(for: []))
      XCTAssertEqual(bounds.minimum.x, -64); XCTAssertEqual(bounds.maximum.x, -16)
      for time: Double in [0,125,456,9999.9,10000.1] {
        var environment = WorldEnvironment(elapsed: time)
        for _ in 0..<24 { environment.disturbWater(atX: -64, z: 512, body: body, energy: 0.35) }
        environment.advance(0.35)
        let vertices = batch.vertices(environment: environment)
        XCTAssertFalse(Scheduler.mayAffectView(bounds, view: front))
        for part in parts { for i in part.indexStart..<(part.indexStart+part.indexCount) {
          let v = vertices[Int(batch.indices[i])]
          let world = SIMD3(v.px,v.py,v.pz) + batch.key.origin
          for axis in 0..<3 {
            XCTAssertGreaterThanOrEqual(world[axis],bounds.minimum[axis]); XCTAssertLessThanOrEqual(world[axis],bounds.maximum[axis])
          }
          XCTAssertLessThan(simd_dot(simd_normalize(world-front.eye),front.forward),-0.5)
        } }
      }
    }
  }

  func testPausedReentryOnlyRefreshesStaleBatchesAndDoesNotRepeatAnIdenticalSample() {
    let a = candidate([0,0,500]), b = candidate([0,0,-500])
    var scheduler = Scheduler()
    let first = scheduler.select([a,b], view: front, now: 0, enabled: true, sample: .init(elapsed: 10))
    scheduler.didSubmit(first, ids: first.selected)
    for step in 1...60 {
      let plan = scheduler.select([a,b], view: front, now: Double(step)/60, enabled: true, sample: .init(elapsed: 10))
      scheduler.didSubmit(plan, ids: plan.selected)
    }
    let next = scheduler.select([a,b], view: front, now: 1.01, enabled: true, sample: .init(elapsed: 11))
    XCTAssertEqual(next.selected, [b.id])
    scheduler.didSubmit(next, ids: next.selected)
    let returned = scheduler.select([a,b], view: rear, now: 1.02, enabled: true, sample: .init(elapsed: 11))
    XCTAssertEqual(returned.urgent, [a.id]) // B already has the shared clock.
    scheduler.didSubmit(returned, ids: returned.urgent)
    for step in 0..<300 {
      let direction = step%120 < 60 ? front : rear
      let paused = scheduler.select([a,b], view: direction, now: 1.03+Double(step)/60, enabled: true, sample: .init(elapsed: 11))
      XCTAssertTrue(paused.urgent.isEmpty) // Head movement alone creates no new wave state.
    }
  }

  func testDisturbanceSampleIdentityTracksSameClockReplacementAndExpiry() {
    var environment = WorldEnvironment(elapsed: 300)
    let empty = environment.waterAnimationSample
    environment.disturbWater(atX: 1,z: 2,body: .ocean)
    XCTAssertEqual(environment.elapsed, empty.elapsed)
    XCTAssertNotEqual(environment.waterAnimationSample,empty)
    let first = environment.waterAnimationSample
    for i in 0..<30 { environment.disturbWater(atX: Float(i),z: 2,body: .ocean) }
    XCTAssertEqual(environment.disturbances.count,24)
    XCTAssertNotEqual(environment.waterAnimationSample,first)
    let before = environment.waterAnimationSample
    environment.advance(0)
    XCTAssertEqual(environment.waterAnimationSample,before)
    environment.advance(6)
    XCTAssertEqual(environment.disturbances.count,0)
    XCTAssertEqual(environment.waterDisturbanceRevision,before.disturbances+1)
    let expired = environment.waterDisturbanceRevision
    environment.advance(1)
    XCTAssertEqual(environment.waterDisturbanceRevision,expired)
  }
}
