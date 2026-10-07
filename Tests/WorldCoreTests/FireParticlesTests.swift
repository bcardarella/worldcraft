import XCTest
import simd
@testable import WorldCore

final class FireParticlesTests: XCTestCase {
  func testStreamingUploadsCannotBypassLightingCadence() {
    var sources = LocalLightSources()
    let torch = TerrainTile(x: 0, z: 0, fullDetail: true)
    sources.install(torch, positions: [[2.5, 4.85, 3.5]])
    func sample(_ time: Double) -> [SIMD3<Float>]? {
      sources.sample(time: time, interval: 0.125, eye: .zero, radius: 96, limit: 20, isValid: { _ in true })
    }
    XCTAssertEqual(sample(0)?.count, 1)
    for tick in 1...120 {
      // Both empty far tiles and edits to an existing torch previously reset
      // lastUpdate to -infinity, defeating the advertised eight-Hz limit.
      sources.install(.init(x: tick + 30, z: 0), positions: [])
      sources.install(torch, positions: [[2.5, 4.85, 3.5]])
      sources.remove(.init(x: tick + 50, z: 0))
      XCTAssertNil(sample(Double(tick) / 1_000))
    }
    XCTAssertEqual(sample(0.125)?.count, 1)
    sources.remove(torch)
    XCTAssertNil(sample(0.15))
    XCTAssertEqual(sample(0.25), [])
    XCTAssertEqual(sources.count, 0)
  }

  func testSourceSelectionDeduplicatesLODAndRejectsExtinguishedTorchesBeforeBudget() {
    var sources = LocalLightSources()
    let points = (0..<40).map { SIMD3<Float>(Float($0) + 0.5, 3.85, 0.5) }
    sources.install(.init(x: 0, z: 0), positions: points)
    sources.install(.init(x: 0, z: 0, fullDetail: true), positions: points)
    let selected = sources.sample(time: 4, interval: 0.125, eye: .zero, radius: 96, limit: 20,
      isValid: { $0.x >= 4 })!
    XCTAssertEqual(selected.count, 20)
    XCTAssertEqual(Set(selected.map(BlockPosition.init)).count, 20)
    XCTAssertEqual(selected.first?.x, 4.5)
    XCTAssertEqual(selected.last?.x, 23.5)
    let far = sources.sample(time: 5, interval: 0.125, eye: [500, 0, 0], radius: 96, limit: 20, isValid: { _ in true })
    XCTAssertEqual(far, [])
  }

  func testSourceChangesAreVisibleAfterPauseAndClockReset() {
    var sources = LocalLightSources()
    let tile = TerrainTile(x: 0, z: 0)
    sources.install(tile, positions: [[1, 2, 3]])
    _ = sources.sample(time: 100, interval: 0.2, eye: .zero, radius: 44, limit: 3, isValid: { _ in true })
    sources.install(tile, positions: [[4, 5, 6]])
    XCTAssertEqual(sources.count, 1)
    XCTAssertEqual(sources.sample(time: 0, interval: 0.2, eye: .zero, radius: 44, limit: 3, isValid: { _ in true }), [[4, 5, 6]])
    sources.clear()
    XCTAssertEqual(sources.count, 0)
    XCTAssertEqual(sources.sample(time: 0, interval: 0.2, eye: .zero, radius: 44, limit: 3, isValid: { _ in true }), [])
  }

  func testMetalLayoutsAndIndicesMatchAllocatedBuffer() {
    XCTAssertEqual(MemoryLayout<FireParticleSource>.stride, 32)
    XCTAssertEqual(MemoryLayout<FireParticleFrame>.stride, 32)
    XCTAssertEqual(MemoryLayout<FireParticleVertex>.stride, 20)
    XCTAssertEqual(MemoryLayout<FireParticleVertex>.offset(of: \.u), 12)
    XCTAssertEqual(FireParticles.vertexCapacity, 3_200)
    XCTAssertEqual(FireParticles.indices.count, 4_800)
    XCTAssertEqual(FireParticles.indices.max(), UInt32(FireParticles.vertexCapacity - 1))
  }

  func testUnusedSlotsAreAlwaysInitializedAndExcessSourcesAreBounded() {
    let source = FireParticleSource(position: [12, 3, -20], breeze: .zero)
    let single = FireParticles.vertices(sources: [source], time: 2, eye: [0, 10, 0])
    XCTAssertEqual(single.count, FireParticles.vertexCapacity)
    XCTAssertTrue(single.dropFirst(160).allSatisfy { $0 == FireParticleVertex() })
    XCTAssertTrue(FireParticles.vertices(sources: [], time: 9, eye: .zero).allSatisfy { $0 == FireParticleVertex() })
    let many = FireParticles.vertices(sources: Array(repeating: source, count: 80), time: 2, eye: [0, 10, 0])
    XCTAssertEqual(many.count, FireParticles.vertexCapacity)
    XCTAssertEqual(Array(many.prefix(160)), Array(single.prefix(160)))
  }

  func testParticleMotionFitsDrawBoundsWithStormWindAndOverheadViews() {
    let point = SIMD3<Float>(-24.5, 8.85, 31.5)
    let source = FireParticleSource(position: point, breeze: [-12, 0, 15])
    for time in stride(from: Float(0), to: 12, by: 0.3) {
      for eye in [point, point + [0, 12, 0], point + [0, -12, 0], point + [30, 1, -20]] {
        let vertices = FireParticles.vertices(sources: [source], time: time, eye: eye)
        for v in vertices.prefix(160) {
          let offset = SIMD3<Float>(v.px, v.py, v.pz) - point
          XCTAssertTrue(v.px.isFinite && v.py.isFinite && v.pz.isFinite)
          XCTAssertLessThanOrEqual(abs(offset.x), 6); XCTAssertLessThanOrEqual(abs(offset.z), 6)
          XCTAssertGreaterThanOrEqual(offset.y, -1); XCTAssertLessThanOrEqual(offset.y, 7)
          XCTAssertTrue((0...1).contains(v.u) && (0...1).contains(v.v))
        }
      }
    }
  }

  func testParticleClockHasNoCatchUpStateAndSourcesKeepTheirIdentity() {
    let source = FireParticleSource(position: [1, 2, 3], breeze: .zero)
    let direct = FireParticles.vertices(sources: [source], time: FireParticles.clock(600), eye: [5, 5, 5])
    _ = FireParticles.vertices(sources: [source], time: 0, eye: [5, 5, 5])
    XCTAssertEqual(direct, FireParticles.vertices(sources: [source], time: FireParticles.clock(600), eye: [5, 5, 5]))
    XCTAssertEqual(source.positionAndSeed, FireParticleSource(position: [1, 2, 3], breeze: [1, 0, 1]).positionAndSeed)
    XCTAssertNotEqual(source.positionAndSeed.w, FireParticleSource(position: [2, 2, 3], breeze: .zero).positionAndSeed.w)
    XCTAssertEqual(FireParticles.clock(4_096 + 0.5), 0.5)
  }
}
