import XCTest
@testable import WorldCore

final class TerrainCacheRecencyTests: XCTestCase {
  func testTouchRemovalAndCopiesMatchAReferenceLRUThroughChurn() {
    var queue = TerrainCacheRecency<Int>(), reference: [Int] = [], random: UInt64 = 791
    for i in 0..<10_000 {
      random = random &* 6_364_136_223_846_793_005 &+ 1
      let key = Int((random >> 16) % 127)
      if i % 5 == 0 { queue.remove(key); reference.removeAll { $0 == key } }
      else { queue.touch(key); reference.removeAll { $0 == key }; reference.append(key) }
      XCTAssertEqual(queue.oldest, reference.first); XCTAssertEqual(queue.count, reference.count)
      if i % 89 == 0 {
        var copy = queue
        for expected in reference { XCTAssertEqual(copy.oldest, expected); copy.remove(expected) }
        XCTAssertNil(copy.oldest); XCTAssertEqual(copy.count, 0)
        XCTAssertEqual(queue.oldest, reference.first, "Value copies must not mutate the live order")
      }
    }
    for expected in reference { XCTAssertEqual(queue.oldest, expected); queue.remove(expected) }
    XCTAssertNil(queue.oldest); XCTAssertEqual(queue.count, 0)
    queue.touch(1); queue.touch(1); XCTAssertEqual(queue.count, 1)
    queue.remove(1); queue.remove(1); XCTAssertNil(queue.oldest)
  }
}
