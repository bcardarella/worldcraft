import Foundation

public enum WaterBodyKind: Int, Sendable { case ocean, lake, lava, river }
public struct WaterBody: Equatable, Sendable {
  public var id: UInt64
  public var kind: WaterBodyKind
  public var level: Float
  public var current: SIMD3<Float>
  public init(id: UInt64, kind: WaterBodyKind, level: Float, current: SIMD3<Float> = .zero) {
    self.id = id; self.kind = kind; self.level = level; self.current = current
  }
  public static let ocean = WaterBody(
    id: 0, kind: .ocean, level: Float(TerrainGenerator.seaLevel + 1))
  public static let lava = WaterBody(
    id: .max, kind: .lava, level: Float(TerrainGenerator.seaLevel + 1))
  /// Upper wet shoreline: ocean tide (0.65), swell/harmonics and small wakes.
  public var snowLine: Float { level + (kind == .ocean ? 2 : 0.4) }
}
public struct InlandLake: Sendable {
  public let id: UInt64
  public let x: Int
  public let z: Int
  public let radiusX: Float
  public let radiusZ: Float
  public let level: Int
  public func distance(x: Int, z: Int) -> Float {
    let dx = Float(x - self.x) / radiusX
    let dz = Float(z - self.z) / radiusZ
    let angle=atan2(dz,dx),phase=Float(id%1024)*0.006135923
    let shore=1+sin(angle*3+phase)*0.075+sin(angle*5-phase)*0.035
    return sqrt(dx * dx + dz * dz)/shore
  }
  public var body: WaterBody { .init(id: id, kind: .lake, level: Float(level + 1)) }
}

public struct WaterDisturbance: Sendable {
  public let x: Float
  public let z: Float
  public let bodyID: UInt64
  public let onset: Double
  public let energy: Float
}
