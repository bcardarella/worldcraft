import Foundation

/// A shared drainage sample drives terrain carving, water meshes and currents.
public struct RiverSample: Sendable {
  public let body: WaterBody
  public let bed: Int
  public let bankBlend: Float
  public let current: SIMD3<Float>
}
extension TerrainGenerator {
  public func river(atX x: Float, z: Float) -> RiverSample? {
    WorldDrainage.patch(atX: Int(floor(x)), z: Int(floor(z)), terrain: self).river(atX: x, z: z)
  }
  public func waterCurrent(at position: SIMD3<Float>, time: Double) -> SIMD3<Float> {
    guard let body = waterBody(atX: Int(floor(position.x)), z: Int(floor(position.z))),
      body.kind == .river,
      position.y < body.level
    else { return .zero }
    let weather = WorldWeather.sample(seed: seed, time: time, style: style)
    return body.current * (1 + weather.precipitation * 0.45)
  }
}

public enum FluidMotion {
  /// Small collision-tested steps keep floating objects out of banks and edits.
  public static func advected(
    _ position: SIMD3<Float>, current: SIMD3<Float>, seconds: Float,
    clearance: Float = 0.2, block: (BlockPosition) -> Block
  ) -> SIMD3<Float> {
    let dt = min(0.1, max(0, seconds))
    let steps = max(1, Int(ceil(dt * 30)))
    var p = position
    for _ in 0..<steps {
      for axis in [0, 2] {
        var next = p
        next[axis] += current[axis] * dt / Float(steps)
        if ![-clearance, clearance].contains(where: { dx in
          [-clearance, clearance].contains { dz in block(.init(next + [dx, 0, dz])).isSolid }
        }) {
          p = next
        }
      }
    }
    return p
  }
}
