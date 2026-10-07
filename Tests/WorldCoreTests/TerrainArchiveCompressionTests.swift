import CryptoKit
import Foundation
import XCTest
@testable import WorldCore

final class TerrainArchiveCompressionTests: XCTestCase {
  private func archive() throws -> Data {
    let r = TerrainPreparationRequest(id: .init(world: UUID(), tile: .init(x: -3, z: 2, fullDetail: true),
      revision: 0, lush: true, repeatAtlas: true), terrain: .init(seed: 731_112), service: .detail, priority: 0)
    return try XCTUnwrap(TerrainPayloadCodec.encode(XCTUnwrap(TerrainPreparation.build(r, collision: { _ in })), key: .init(r)))
  }
  private func resign(_ data: inout Data) {
    var digest = SHA256(); digest.update(data: data[8..<16]); digest.update(data: data.dropFirst(48))
    data.replaceSubrange(16..<48, with: Data(digest.finalize()))
  }
  func testLosslessEnvelopeAndRawArchiveCompatibility() throws {
    let raw = try archive(), compressed = TerrainArchiveCompression.encode(raw)
    XCTAssertEqual(compressed.prefix(8), TerrainArchiveCompression.magic)
    XCTAssertLessThan(compressed.count, raw.count / 2)
    XCTAssertEqual(TerrainArchiveCompression.decode(compressed), raw)
    XCTAssertEqual(TerrainArchiveCompression.decode(raw), raw)
  }
  func testCorruptionLengthsTruncationAndExpandedAllocationCapAreRejected() throws {
    let compressed = TerrainArchiveCompression.encode(try archive())
    for length in [0, 7, 16, 47, 48, compressed.count / 2, compressed.count - 1] {
      XCTAssertNil(TerrainArchiveCompression.decode(compressed.prefix(length)))
    }
    for index in [0, 7, 8, 12, 16, 49, compressed.count - 1] {
      var bad = compressed; bad[index] ^= 0xff
      XCTAssertNil(TerrainArchiveCompression.decode(bad))
    }
    // Repair envelope checksums to exercise the decompressor/semantic bounds.
    for count: UInt32 in [0, 4_095, UInt32(TerrainPayloadCodec.maximumBytes + 1), .max] {
      var bad = compressed, size = count.littleEndian
      withUnsafeBytes(of: &size) { bad.replaceSubrange(8..<12, with: $0) }
      resign(&bad); XCTAssertNil(TerrainArchiveCompression.decode(bad))
    }
    var garbage = compressed
    garbage.replaceSubrange(48..<garbage.count, with: [UInt8](repeating: 255, count: garbage.count - 48))
    resign(&garbage); XCTAssertNil(TerrainArchiveCompression.decode(garbage))
    var trailing = compressed; trailing.append(0)
    XCTAssertNil(TerrainArchiveCompression.decode(trailing))
    XCTAssertNil(TerrainArchiveCompression.decode(Data(count: TerrainPayloadCodec.maximumBytes + 1)))
  }
  func testTinyAndIncompressibleDataAvoidGrowingAStoredEntry() {
    let tiny = TerrainPayloadCodec.magic + Data(repeating: 1, count: 32)
    XCTAssertEqual(TerrainArchiveCompression.encode(tiny), tiny)
    var state: UInt64 = 42
    let random = Data((0..<32_768).map { _ -> UInt8 in
      state ^= state << 13; state ^= state >> 7; state ^= state << 17
      return UInt8(truncatingIfNeeded: state)
    })
    let raw = TerrainPayloadCodec.magic + random
    let stored = TerrainArchiveCompression.encode(raw)
    XCTAssertLessThanOrEqual(stored.count, raw.count)
    XCTAssertEqual(TerrainArchiveCompression.decode(stored), raw)
  }
}
