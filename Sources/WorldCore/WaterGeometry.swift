/// Sparse water geometry: dry grid vertices are removed before upload. A single
/// mesh covers a whole horizon tile, using the same world-space wave samples as
/// the detailed chunks and swimming physics.
public struct WaterGeometry: Equatable, Sendable {
  public struct Sample: Equatable, Sendable {
    public let position: SIMD2<Float>
    public let depth: Float
    public let body: WaterBody
  }
  public var samples: [Sample] = []
  public var shallowIndices: [UInt32] = []
  public var deepIndices: [UInt32] = []
  public var isEmpty: Bool { shallowIndices.isEmpty && deepIndices.isEmpty }
  public init() {}
  public init(_ patch: WaterPatch) {
    var mapping: [UInt32: UInt32] = [:]
    func vertex(_ index: UInt32) -> UInt32 {
      if let mapped = mapping[index] { return mapped }
      let i = Int(index)
      let id = UInt32(samples.count)
      samples.append(
        .init(
          position: [
            Float(i % patch.vertexSide * patch.sampleStride),
            Float(i / patch.vertexSide * patch.sampleStride),
          ],
          depth: patch.depths[i], body: patch.bodies[i]))
      mapping[index] = id
      return id
    }
    shallowIndices = patch.shallowIndices.map { vertex($0) }
    deepIndices = patch.deepIndices.map { vertex($0) }
  }

  static func surface(
    _ tile: TerrainTile, columns: [TerrainColumn], terrain: TerrainGenerator,
    heights: [Float]
  ) -> Self {
    let step = tile.sampleStride
    let side = tile.blockSize / step + 1
    var result = Self()
    var mapping: [Int: UInt32] = [:]
    var sampler = WaterBodySampling()
    let uniform = WaterBodySampling.uniformBody(style:terrain.style)
    func vertex(_ i: Int) -> UInt32? {
      if let id = mapping[i] { return id }
      let x = i % side * step
      let z = i / side * step
      guard let selected = columns[i].water ?? uniform ?? sampler.nearest(
        atX:tile.x*16+x,z:tile.z*16+z,lookup:{ terrain.waterBody(atX:$0,z:$1) }) else { return nil }
      let id = UInt32(result.samples.count)
      result.samples.append(
        .init(
          position: [Float(x), Float(z)], depth: max(0, selected.level - heights[i]), body: selected
        ))
      mapping[i] = id
      return id
    }
    // Increasing land detail must not multiply water compute/vertex work.
    let skip = tile.size >= 4 ? max(2, 4 / step) : max(1, 2 / step)
    precondition(step*skip <= 32)
    for z in stride(from: 0, to: side - 1, by: skip) {
      if Task.isCancelled { return .init() }
      for x in stride(from: 0, to: side - 1, by: skip) {
        let a = z * side + x
        guard let body = columns[a].water, heights[a] <= body.level + 1 else { continue }
        let indices = [
          a, a + side * skip, a + skip, a + skip, a + side * skip, a + side * skip + skip,
        ].compactMap { vertex($0) }
        guard indices.count == 6 else { return .init() }
        if body.level - heights[a] < 5 {
          result.shallowIndices += indices
        } else {
          result.deepIndices += indices
        }
      }
    }
    return result
  }
}
