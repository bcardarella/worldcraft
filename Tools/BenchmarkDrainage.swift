import CoreGraphics
import Foundation
import ImageIO

/// swiftc -O Sources/WorldCore/*.swift Tools/BenchmarkDrainage.swift -o tmp/scratch/benchmark-drainage
/// Optional first argument writes a diagnostic map, not a gameplay screenshot.
@main struct BenchmarkDrainage {
  static func main() throws {
    let terrain = TerrainGenerator(seed: 8192)
    var patches: [DrainagePatch] = []
    let cold = Date()
    for x in -8..<8 {
      for z in -8..<8 {
        patches.append(WorldDrainage.patch(atX: x * 512, z: z * 512, terrain: terrain))
      }
    }
    let coldMS = Date().timeIntervalSince(cold) * 1000
    let warm = Date()
    var checksum = 0
    var waterColumns = 0
    for z in stride(from: -2048, to: 2048, by: 8) {
      for x in stride(from: -2048, to: 2048, by: 8) {
        let column = terrain.column(atX: x, z: z)
        checksum += column.height
        if column.water != nil { waterColumns += 1 }
      }
    }
    let hotMS = Date().timeIntervalSince(warm) * 1000
    var rivers: [ChunkCoordinate: RiverReach] = [:]
    var lakes: [UInt64: InlandLake] = [:]
    for patch in patches {
      for r in patch.rivers { rivers[r.origin] = r }
      for l in patch.lakes { lakes[l.id] = l }
    }
    var blockedChannels: [String] = []
    for reach in rivers.values {
      for point in reach.points {
        let p = BlockPosition(point)
        let column = terrain.column(atX: p.x, z: p.z)
        guard let water = column.water else { continue }
        let cell = BlockPosition(p.x, Int(ceil(water.level)) - 1, p.z)
        if terrain.block(at: cell).isSolid {
          blockedChannels.append("\(cell.x),\(cell.y),\(cell.z)")
        }
      }
    }
    let result: [String: Any] = [
      "cold_patch_count": 256, "cold_patch_mean_ms": coldMS / 256,
      "warm_column_count": 512 * 512, "warm_column_mean_us": hotMS * 1000 / Double(512 * 512),
      "rivers": rivers.count, "lakes": lakes.count, "water_columns": waterColumns,
      "checksum": checksum,
      "blocked_channel_samples": blockedChannels.count,
      "blocked_examples": Array(blockedChannels.prefix(8)),
      "measurement": "Host terrain preparation only; not headset FPS or GPU time",
    ]
    print(
      String(
        decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys),
        as: UTF8.self))
    guard CommandLine.arguments.count > 1 else { return }
    let size = 1024
    var pixels = [UInt8](repeating: 255, count: size * size * 4)
    for z in 0..<size {
      for x in 0..<size {
        let wx = x * 8 - 4096
        let wz = z * 8 - 4096
        let column = terrain.column(atX: wx, z: wz)
        let h = Float(column.height)
        let rgb: SIMD3<Float>
        switch column.water?.kind {
        case .ocean: rgb = [0.03, 0.20 + max(0, h + 30) * 0.001, 0.34 + max(0, h + 30) * 0.002]
        case .lake: rgb = [0.10, 0.47, 0.64]
        case .river: rgb = [0.25, 0.78, 0.88]
        case .lava: rgb = [1, 0.20, 0.03]
        case nil:
          rgb =
            h >= 58
            ? SIMD3(repeating: min(0.99, 0.7 + (h - 58) * 0.009))
            : h >= 49
              ? [0.48, 0.51, 0.38] : [0.19 + h * 0.002, 0.30 + h * 0.005, 0.13 + h * 0.001]
        }
        for channel in 0..<3 {
          pixels[(z * size + x) * 4 + channel] = UInt8(max(0, min(255, rgb[channel] * 255)))
        }
      }
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(
      width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(
      URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
      "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
  }
}
