import Compression
import CryptoKit
import Foundation

/// Lossless storage envelope around the already validated terrain archive.
/// File and expanded sizes are bounded independently before allocating. Raw
/// archives remain readable, so representation keys and saves do not change.
enum TerrainArchiveCompression {
  static let magic = Data("WCLZ4C01".utf8)
  static let headerBytes = 48

  static func encode(_ archive: Data) -> Data {
    guard archive.count >= 4_096, archive.count <= TerrainPayloadCodec.maximumBytes else { return archive }
    // Incompressible entries retain their raw representation. Destination
    // capacity never grows beyond the input archive's existing per-entry cap.
    var compressed = Data(count: archive.count - headerBytes)
    let size = compressed.withUnsafeMutableBytes { destination in archive.withUnsafeBytes { source in
      compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
        source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_LZ4)
    } }
    guard size > 0, size + headerBytes < archive.count else { return archive }
    compressed.count = size
    var counts = Data()
    for value in [UInt32(archive.count), UInt32(size)] {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { counts.append(contentsOf: $0) }
    }
    var digest = SHA256(); digest.update(data: counts); digest.update(data: compressed)
    var result = magic
    result.append(counts); result.append(contentsOf: digest.finalize()); result.append(compressed)
    return result
  }

  static func decode(_ stored: Data) -> Data? {
    guard stored.count <= TerrainPayloadCodec.maximumBytes else { return nil }
    if stored.prefix(8) == TerrainPayloadCodec.magic { return stored }
    guard stored.count > headerBytes, stored.prefix(8) == magic else { return nil }
    let counts = stored[8..<16]
    let (expanded, compressed): (Int, Int) = counts.withUnsafeBytes {
      (Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))),
        Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))))
    }
    guard expanded >= 4_096, expanded <= TerrainPayloadCodec.maximumBytes,
      compressed == stored.count - headerBytes, stored.count < expanded else { return nil }
    let source = stored.dropFirst(headerBytes)
    var digest = SHA256(); digest.update(data: counts); digest.update(data: source)
    guard Data(digest.finalize()) == stored[16..<headerBytes] else { return nil }
    var archive = Data(count: expanded)
    let size = archive.withUnsafeMutableBytes { destination in source.withUnsafeBytes { bytes in
      compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, expanded,
        bytes.bindMemory(to: UInt8.self).baseAddress!, bytes.count, nil, COMPRESSION_LZ4)
    } }
    guard size == expanded, archive.prefix(8) == TerrainPayloadCodec.magic else { return nil }
    return archive
  }
}
