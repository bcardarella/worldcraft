import XCTest
@testable import WorldCore

final class WaterAppearanceTests: XCTestCase {
  func testAbsorptionIncreasesWithDepthAndCalmLakesRetainGentleDetail() {
    let body = WaterBody(id: 83, kind: .lake, level: 40)
    let env = WorldEnvironment(elapsed: 732)
    var previous: Float = -1
    for depth: Float in [0, 0.3, 1, 4, 10, 40] {
      let sample = env.water(atX: 21, z: -40, depth: depth, body: body)
      XCTAssertEqual(sample.height, body.level)
      let optics = WaterAppearance.optics(depth: depth, body: body, sample: sample)
      XCTAssertGreaterThan(optics.x, previous)
      XCTAssertEqual(optics.z, 0.24)
      XCTAssertTrue((0...1).contains(optics.w))
      if depth == 0 { XCTAssertEqual(optics.w, 0) }
      previous = optics.x
    }
  }

  func testSwimmingWakeCarriesFoamOnlyWithinItsOwnBodyAndDecays() {
    let lake = WaterBody(id: 12, kind: .lake, level: 40)
    let other = WaterBody(id: 13, kind: .lake, level: 40)
    var env = WorldEnvironment(elapsed: 230)
    env.disturbWater(atX: 10, z: -7, body: lake, energy: 0.32)
    env.advance(0.8)
    let wake = env.water(atX: 11.84, z: -7, depth: 12, body: lake)
    XCTAssertGreaterThan(wake.foam, 0.4)
    XCTAssertEqual(env.water(atX: 11.84, z: -7, depth: 12, body: other).foam, 0)
    XCTAssertEqual(env.water(atX: 100, z: -7, depth: 12, body: lake).foam, 0)
    env.advance(5)
    XCTAssertEqual(env.water(atX: 11.84, z: -7, depth: 12, body: lake).foam, 0)
  }

  func testSwellsAndFoamStayBoundedWithAnalyticNormalsAcrossDayCycle() {
    for t in stride(from: 0.0, to: 1_200, by: 17) {
      let env = WorldEnvironment(elapsed: t)
      for depth: Float in [0, 0.2, 2, 6, 30] {
        let x: Float = 21.7, z: Float = -34.2, epsilon: Float = 0.02
        let wave = env.water(atX: x, z: z, depth: depth)
        XCTAssertLessThan(abs(wave.height - WaterBody.ocean.level - env.tide), 1.0)
        XCTAssertTrue((0...1).contains(wave.foam))
        let dx = (env.water(atX: x+epsilon, z: z, depth: depth).height
          - env.water(atX: x-epsilon, z: z, depth: depth).height) / (2*epsilon)
        XCTAssertEqual(-wave.normal.x / wave.normal.y, dx, accuracy: 0.003)
        XCTAssertEqual(env.water(atX: x, z: z, depth: depth, body: .lava).foam, 0)
      }
    }
  }

  func testUnderwaterColorRespondsToDepthDaylightAndEntryWithoutHidingTowns() {
    let air = WaterAppearance.immersion(depth: -1, daylight: 1, lava: false)
    let shallows = WaterAppearance.immersion(depth: 1, daylight: 1, lava: false)
    let deep = WaterAppearance.immersion(depth: 60, daylight: 1, lava: false)
    let night = WaterAppearance.immersion(depth: 60, daylight: 0, lava: false)
    XCTAssertEqual(air.w, 0)
    XCTAssertLessThan(shallows.w, deep.w)
    XCTAssertLessThan(deep.w, 0.56)
    XCTAssertLessThan(deep.y, shallows.y)
    XCTAssertLessThan(night.y, deep.y)
    XCTAssertEqual(night.w, deep.w)
  }

  func testContinuousDepthMergesDrawsWithoutDroppingGeometry() {
    let tile = TerrainTile(x: 0, z: 0, fullDetail: true)
    var geometry = WaterGeometry()
    geometry.samples = [[0, 0], [0, 16], [16, 0], [16, 16]].enumerated().map {
      .init(position: $0.element, depth: Float($0.offset)*5, body: .ocean)
    }
    geometry.shallowIndices = [0, 1, 2]; geometry.deepIndices = [2, 1, 3]
    let batch = WaterMeshBatch(key: WaterBatchKey(tile), geometry: [tile: geometry])
    XCTAssertEqual(batch.parts(visible: [tile], bands: [:]).count, 2)
    let parts = batch.parts(visible: [tile], bands: [:], continuousDepth: true)
    XCTAssertEqual(parts.count, 1)
    XCTAssertEqual(parts[0].indexCount, 6)
    XCTAssertEqual(batch.vertices(environment: .init()).count, 4)
    XCTAssertEqual(batch.parts(visible: [], bands: [:], continuousDepth: true).count, 0)
  }
}
