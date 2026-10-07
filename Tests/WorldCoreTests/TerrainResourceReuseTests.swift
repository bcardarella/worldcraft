import XCTest
@testable import WorldCore

final class TerrainResourceReuseTests: XCTestCase {
  func testCapacityClassesFitCountsWithoutUnboundedRounding() {
    let empty = TerrainMeshCapacity(vertices: 0, indices: 0)
    XCTAssertEqual(empty.bytes, 0)
    for count in Array(1...10_000) + [65_535, 65_536, 65_537, 1_000_003] {
      let capacity = TerrainMeshCapacity(vertices: count, indices: count)
      XCTAssertGreaterThanOrEqual(capacity.vertices, count)
      XCTAssertGreaterThanOrEqual(capacity.indices, count)
      XCTAssertLessThanOrEqual(capacity.vertices, max(64, count * 5 / 4))
      XCTAssertLessThanOrEqual(capacity.indices, max(96, count * 5 / 4))
      XCTAssertEqual(capacity.bytes, capacity.vertices * 40 + capacity.indices * 4)
    }
    let exact = TerrainMeshCapacity(vertices: 65, indices: 101, rounded: false)
    XCTAssertEqual(exact.vertices, 65)
    XCTAssertEqual(exact.indices, 101)
  }

  func testPoolUsesBestFitAndTransfersUniqueOwnership() {
    var pool = TerrainMeshReuseCache<String>()
    let small = TerrainMeshCapacity(vertices: 128, indices: 192)
    let large = TerrainMeshCapacity(vertices: 160, indices: 240)
    XCTAssertTrue(pool.offer("larger", capacity: large, at: 0))
    XCTAssertTrue(pool.offer("best", capacity: small, at: 0))
    XCTAssertEqual(pool.take(fitting: small), "best")
    XCTAssertEqual(pool.take(fitting: small), "larger")
    XCTAssertNil(pool.take(fitting: small))
    XCTAssertEqual(pool.metrics.entries, 0)
    XCTAssertEqual(pool.metrics.bytes, 0)
    XCTAssertEqual(pool.metrics.hits, 2)
    XCTAssertEqual(pool.metrics.misses, 1)
  }

  func testPoolRequiresBothBuffersAndRejectsExcessiveSlack() {
    let demand = TerrainMeshCapacity(vertices: 128, indices: 192, rounded: false)
    XCTAssertFalse(TerrainMeshCapacity(vertices: 127, indices: 10_000, rounded: false).fits(demand))
    XCTAssertFalse(TerrainMeshCapacity(vertices: 10_000, indices: 191, rounded: false).fits(demand))
    XCTAssertFalse(TerrainMeshCapacity(vertices: 256, indices: 384).fits(demand))
    XCTAssertTrue(TerrainMeshCapacity(vertices: 160, indices: 240).fits(demand))
  }

  func testPoolEnforcesBytesEntriesAndIncrementalExpiry() {
    let capacity = TerrainMeshCapacity(vertices: 128, indices: 192)
    var byteBound = TerrainMeshReuseCache<Int>(limitBytes: capacity.bytes * 2, limitEntries: 20)
    for id in 0..<2 { XCTAssertTrue(byteBound.offer(id, capacity: capacity, at: Double(id))) }
    XCTAssertFalse(byteBound.offer(2, capacity: capacity, at: 2))
    XCTAssertNil(byteBound.takeExpired(before: -1))
    XCTAssertEqual(byteBound.takeExpired(before: 0), 0)
    XCTAssertEqual(byteBound.metrics.bytes, capacity.bytes)
    XCTAssertEqual(byteBound.takeExpired(before: 10), 1)
    XCTAssertNil(byteBound.takeExpired(before: 10))
    XCTAssertEqual(byteBound.metrics.bytes, 0)
    var entryBound = TerrainMeshReuseCache<Int>(limitBytes: capacity.bytes * 20, limitEntries: 1)
    XCTAssertTrue(entryBound.offer(3, capacity: capacity, at: 0))
    XCTAssertFalse(entryBound.offer(4, capacity: capacity, at: 0))
    XCTAssertEqual(entryBound.metrics.rejected, 1)
    XCTAssertEqual(entryBound.take(fitting: capacity), 3)
    XCTAssertTrue(entryBound.offer(5, capacity: capacity, at: 1))
    var disabled = TerrainMeshReuseCache<Int>(limitBytes: 0, limitEntries: 0)
    XCTAssertFalse(disabled.offer(1, capacity: capacity, at: 0))
  }

  func testRetirementReleasesOneOwnerAtATime() {
    final class Token {}
    var first: Token? = Token(), second: Token? = Token()
    weak var firstObserved = first, secondObserved = second
    var queue = TerrainRetirementQueue<Token>()
    queue.append(first!, bytes: 100, at: 0)
    queue.append(second!, bytes: 200, at: 1)
    first = nil; second = nil
    XCTAssertNotNil(firstObserved)
    XCTAssertNotNil(secondObserved)
    var retired = queue.popFirst()
    XCTAssertTrue(retired === firstObserved)
    XCTAssertEqual(queue.metrics(at: 2).bytes, 200)
    retired = nil
    XCTAssertNil(firstObserved)
    XCTAssertNotNil(secondObserved)
    _ = queue.popFirst()
    XCTAssertNil(secondObserved)
    XCTAssertTrue(queue.isEmpty)
  }

  func testRetirementBurstAppliesBackpressureUntilBothWatermarksClear() {
    var queue = TerrainRetirementQueue<Int>(highWaterEntries: 3, highWaterBytes: 1_000)
    // A reset transfers ownership of already resident geometry. High-water
    // marks throttle new publication; they do not discard outgoing owners.
    for id in 0..<6 { queue.append(id, bytes: 300, at: Double(id)) }
    XCTAssertTrue(queue.appliesBackpressure)
    XCTAssertEqual(queue.metrics(at: 10).peakBytes, 1_800)
    XCTAssertEqual(queue.metrics(at: 10).oldestAgeMilliseconds, 10_000)
    for id in 0..<3 { XCTAssertEqual(queue.popFirst(), id) }
    XCTAssertTrue(queue.appliesBackpressure) // Three entries, even below byte mark.
    XCTAssertEqual(queue.popFirst(), 3)
    XCTAssertFalse(queue.appliesBackpressure)
    XCTAssertEqual(queue.metrics(at: 2).oldestAgeMilliseconds, 0)
    XCTAssertEqual(queue.metrics(at: 10).completed, 4)
    XCTAssertEqual(queue.metrics(at: 10).peakEntries, 6)
    var byteQueue = TerrainRetirementQueue<Int>(highWaterEntries: 100, highWaterBytes: 1_000)
    byteQueue.append(0, bytes: 1_000, at: 0)
    XCTAssertTrue(byteQueue.appliesBackpressure)
    _ = byteQueue.popFirst()
    XCTAssertFalse(byteQueue.appliesBackpressure)
  }

  func testLongRouteRetirementCompactionPreservesFIFOAndAccounting() {
    var queue = TerrainRetirementQueue<Int>()
    var expected = 0
    for batch in 0..<80 {
      for offset in 0..<73 { queue.append(batch * 73 + offset, bytes: 48, at: Double(batch)) }
      for _ in 0..<70 {
        XCTAssertEqual(queue.popFirst(), expected); expected += 1
      }
      XCTAssertEqual(queue.metrics(at: 80).bytes, queue.count * 48)
    }
    while let value = queue.popFirst() { XCTAssertEqual(value, expected); expected += 1 }
    XCTAssertEqual(expected, 80 * 73)
    XCTAssertEqual(queue.metrics(at: 100).bytes, 0)
    XCTAssertEqual(queue.metrics(at: 100).oldestAgeMilliseconds, 0)
    XCTAssertEqual(queue.metrics(at: 100).completed, expected)
    XCTAssertNil(queue.popFirst())
    queue.append(99, bytes: 32, at: 101)
    XCTAssertEqual(queue.popFirst(), 99)
    XCTAssertTrue(queue.isEmpty)
  }
}
