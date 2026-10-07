import Foundation
import XCTest
@testable import WorldCore

final class RegionalPlanCacheTests: XCTestCase, @unchecked Sendable {
  func testEvictionRemovesOnlyLeastRecentlyUsedRegionIncludingNegativePlans() {
    let cache = RegionalPlanCache<Int, Int?>(capacity: 3)
    XCTAssertNil(cache.value(for: 1) { nil })
    XCTAssertEqual(cache.value(for: 2) { 20 }, 20)
    XCTAssertEqual(cache.value(for: 3) { 30 }, 30)
    XCTAssertNil(cache.value(for: 1) { XCTFail("Negative result was not cached"); return 10 })
    XCTAssertEqual(cache.value(for: 4) { 40 }, 40)
    XCTAssertEqual(cache.metrics.entries, 3)
    XCTAssertEqual(cache.metrics.evictions, 1)
    XCTAssertEqual(cache.value(for: 3) { XCTFail("Hot entries were flushed"); return nil }, 30)
    XCTAssertEqual(cache.value(for: 2) { 200 }, 200)
    XCTAssertEqual(cache.metrics.evictions, 2)
  }

  func testConcurrentRegionalMissIsBuiltOnce() async {
    let cache = RegionalPlanCache<Int, Int>(capacity: 4)
    let results = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
      for _ in 0..<8 {
        group.addTask {
          cache.value(for: 5) {
            // Only the worker owning the miss does this synthetic bulk work.
            Thread.sleep(forTimeInterval: 0.04)
            return 50
          }
        }
      }
      var values: [Int] = []
      for await result in group { values.append(result) }
      return values
    }
    XCTAssertEqual(results, Array(repeating: 50, count: 8))
    XCTAssertEqual(cache.metrics.misses, 1)
    XCTAssertEqual(cache.metrics.hits, 7)
    XCTAssertGreaterThan(cache.metrics.sharedWaits, 0)
  }

  func testCancelledSurveyCannotCachePartialNegativeResult() async {
    let cache = RegionalPlanCache<Int, Int?>(capacity: 4)
    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let worker = Task.detached {
      cache.value(for: 9) { started.signal(); release.wait(); return nil }
    }
    await Task.detached { Self.waitForStart(started) }.value
    worker.cancel(); release.signal()
    _ = await worker.value
    XCTAssertEqual(cache.metrics.entries, 0)
    XCTAssertEqual(cache.value(for: 9) { 90 }, 90)
  }

  func testSnapshotMatchesColumnsAtRegionBordersAcrossPlanetStylesAndMarina() throws {
    for style in PlanetStyle.allCases {
      let terrain = TerrainGenerator(seed: 967252643, style: style)
      for (x, z) in [(-521, -9), (503, 1015), (-1100, 300)] {
        let sampler = TerrainColumnSampler(x: x, z: z, width: 48, terrain: terrain,
          marinas: MarinaGenerator.sites(x: x, z: z, width: 48, terrain: terrain))
        for dx in stride(from: 0, through: 48, by: 3) { for dz in stride(from: 0, through: 48, by: 3) {
          assertSame(sampler.column(atX: x + dx, z: z + dz), terrain.column(atX: x + dx, z: z + dz))
        } }
      }
    }
    let terrain = TerrainGenerator(seed: 967252643)
    let site = try XCTUnwrap(MarinaGenerator.site(in: .init(-2, 0), terrain: terrain))
    let sampler = TerrainColumnSampler(x: site.x-300, z: site.z-300, width: 600,
      terrain: terrain, marinas: MarinaGenerator.sites(x: site.x-300, z: site.z-300, width: 600, terrain: terrain))
    for dx in stride(from: -300, through: 300, by: 12) { for dz in stride(from: -300, through: 300, by: 12) {
      assertSame(sampler.column(atX: site.x+dx, z: site.z+dz), terrain.column(atX: site.x+dx, z: site.z+dz))
    } }
  }
  private func assertSame(_ a: TerrainColumn, _ b: TerrainColumn, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.height, b.height, file: file, line: line)
    XCTAssertEqual(a.surface, b.surface, file: file, line: line)
    XCTAssertEqual(a.water, b.water, file: file, line: line)
  }
  private static func waitForStart(_ semaphore: DispatchSemaphore) { semaphore.wait() }
}
