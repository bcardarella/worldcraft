import Foundation

/// Intersecting seeded 3D density fields form connected tunnels and deeper chambers.
public struct CaveGenerator: Sendable {
  public let seed: UInt64
  public init(seed: UInt64) { self.seed = seed }

  /// Exact occupancy for one chunk-height column. Noise lattice planes are
  /// shared across Y samples instead of hashing the same corners per block.
  /// This is local worker data: no global cache, locks or actor calls.
  public struct Column: Sendable {
    fileprivate var bits = SIMD4<UInt64>(repeating: 0)
    public func isCarved(y: Int) -> Bool {
      guard y >= ChunkData.minimumY, y < ChunkData.height else { return false }
      let offset = y - ChunkData.minimumY
      return bits[offset / 64] & (1 << (offset % 64)) != 0
    }
  }

  public func column(x: Int, z: Int, surface: Int, waterCovered: Bool) -> Column {
    // Four words are enough for the current 192-cell vertical world. Changing
    // its height requires enlarging this fixed storage, never silent truncation.
    precondition(ChunkData.height - ChunkData.minimumY <= 256)
    var result = Column()
    let low = ChunkData.minimumY + 4
    guard surface >= low else { return result }
    let entrance = !waterCovered && surface > TerrainGenerator.seaLevel + 5
      && TerrainGenerator(seed: seed).hash(floorDivide(x, by: 48), floorDivide(z, by: 48), salt: 9_101) % 7 == 0
    let high = min(ChunkData.height - 1, surface - (entrance ? 0 : 5))
    guard high >= low else { return result }
    let first = VerticalNoise(seed: seed, x: Double(x) / 25, z: Double(z) / 25,
      scaleY: 18, offsetY: 0, low: low, high: high, salt: 4_091)
    let second = VerticalNoise(seed: seed, x: Double(x) / 21 + 13.7, z: Double(z) / 21 + 4.8,
      scaleY: 23, offsetY: -9.3, low: low, high: high, salt: 8_191)
    let chamberTop = min(high, min(0, surface - 12) - 1)
    let chamber = chamberTop >= low ? VerticalNoise(seed: seed, x: Double(x) / 42, z: Double(z) / 42,
      scaleY: 28, offsetY: 0, low: low, high: chamberTop, salt: 6_151) : nil
    for y in low...high {
      let tunnel = abs(first.sample(y) - 0.5) < 0.075 && abs(second.sample(y) - 0.5) < 0.085
      let room = !tunnel && y <= chamberTop && chamber!.sample(y) > 0.82
      if tunnel || room {
        let offset = y - ChunkData.minimumY
        result.bits[offset / 64] |= 1 << (offset % 64)
      }
    }
    return result
  }

  private struct VerticalNoise {
    let minimumLayer: Int
    let scaleY, offsetY: Double
    let planes: [Double]
    init(seed: UInt64, x: Double, z: Double, scaleY: Double, offsetY: Double,
      low: Int, high: Int, salt: UInt64) {
      self.scaleY = scaleY; self.offsetY = offsetY
      let ix = Int(floor(x)), iz = Int(floor(z))
      let dx = x - floor(x), dz = z - floor(z)
      let sx = dx * dx * (3 - 2 * dx), sz = dz * dz * (3 - 2 * dz)
      minimumLayer = Int(floor(Double(low) / scaleY + offsetY))
      let maximumLayer = Int(floor(Double(high) / scaleY + offsetY)) + 1
      let terrain = TerrainGenerator(seed: seed)
      planes = (minimumLayer...maximumLayer).map { y in
        let layer = UInt64(bitPattern: Int64(y)) &* 0x9E37_79B1_85EB_CA87
        func value(_ a: Int, _ b: Int) -> Double {
          Double(terrain.hash(ix + a, iz + b, salt: salt ^ layer) & 65_535) / 65_535
        }
        // Preserve the scalar evaluator's operation order, including division
        // and interpolation order. Threshold occupancy must remain identical.
        let a = value(0, 0) * (1 - sx) + value(1, 0) * sx
        let b = value(0, 1) * (1 - sx) + value(1, 1) * sx
        return a * (1 - sz) + b * sz
      }
    }
    func sample(_ y: Int) -> Double {
      let py = Double(y) / scaleY + offsetY, layer = Int(floor(py))
      let dy = py - floor(py), sy = dy * dy * (3 - 2 * dy)
      let i = layer - minimumLayer
      return planes[i] * (1 - sy) + planes[i + 1] * sy
    }
  }

  public func isCarved(at p: BlockPosition, surface: Int, waterCovered: Bool) -> Bool {
    guard p.y > ChunkData.minimumY + 3, p.y <= surface else { return false }
    let terrain = TerrainGenerator(seed: seed)
    let entrance =
      !waterCovered && surface > TerrainGenerator.seaLevel + 5
      && terrain.hash(floorDivide(p.x, by: 48), floorDivide(p.z, by: 48), salt: 9_101) % 7 == 0
    guard p.y <= surface - 5 || entrance else { return false }
    let x = Double(p.x)
    let y = Double(p.y)
    let z = Double(p.z)
    let first = noise(x / 25, y / 18, z / 25, salt: 4_091)
    let second = noise(x / 21 + 13.7, y / 23 - 9.3, z / 21 + 4.8, salt: 8_191)
    if abs(first - 0.5) < 0.075 && abs(second - 0.5) < 0.085 { return true }
    return p.y < min(0, surface - 12)
      && noise(x / 42, y / 28, z / 42, salt: 6_151) > 0.82
  }

  private func noise(_ x: Double, _ y: Double, _ z: Double, salt: UInt64) -> Double {
    let ix = Int(floor(x))
    let iy = Int(floor(y))
    let iz = Int(floor(z))
    func smooth(_ value: Double) -> Double { value * value * (3 - 2 * value) }
    let sx = smooth(x - floor(x))
    let sy = smooth(y - floor(y))
    let sz = smooth(z - floor(z))
    let terrain = TerrainGenerator(seed: seed)
    func value(_ dx: Int, _ dy: Int, _ dz: Int) -> Double {
      let layer = UInt64(bitPattern: Int64(iy + dy)) &* 0x9E37_79B1_85EB_CA87
      return Double(terrain.hash(ix + dx, iz + dz, salt: salt ^ layer) & 65_535) / 65_535
    }
    func plane(_ dy: Int) -> Double {
      let a = value(0, dy, 0) * (1 - sx) + value(1, dy, 0) * sx
      let b = value(0, dy, 1) * (1 - sx) + value(1, dy, 1) * sx
      return a * (1 - sz) + b * sz
    }
    return plane(0) * (1 - sy) + plane(1) * sy
  }
}
