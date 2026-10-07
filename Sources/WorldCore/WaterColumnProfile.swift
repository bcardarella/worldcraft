import Foundation

/// Liquid occupancy from an immutable voxel column, independent of procedural
/// terrain height. A heightfield or water-body lookup cannot supply this proof
/// after edits, inside a building, or below an overhang.
public struct WaterColumnProfile: Sendable, Equatable {
  public struct Span: Sendable, Equatable {
    public let lower, upper: Int // Half-open voxel heights.
    public let material: Block
    public let below, above: Block
    /// Opaque full cubes hide a contacting face. Glass, foliage and partial
    /// shapes do not certify that the liquid boundary can be omitted.
    public var coveredAbove: Bool {
      above.isOpaque && !above.isFoliage
    }
    public var supportedBelow: Bool {
      below.isOpaque && !below.isFoliage
    }
  }
  public let spans: [Span]
  /// Index of the existing liquid span reaching the procedural body surface.
  /// Fractional rivers occupy ceil(level)-1, matching TerrainGenerator.
  /// A covered upper face or missing/mismatched liquid returns nil.
  public let proceduralSurface: Int?
  /// Liquid runs with visible upper faces not represented by that surface.
  /// These need voxel fluid geometry or an independently resolved body; do not
  /// invent an ocean/lake identity or silently discard them.
  public let additionalSurfaces: [Int]
  /// A water sheet alone cannot close these lower faces when viewed underwater.
  /// A caller may prove an alternative bottom, but this profile does not.
  public let unsupportedBottoms: [Int]

  public enum Outcome: Sendable, Equatable {
    case ready(WaterColumnProfile)
    case invalidInput
    case cancelled
  }

  /// x/z are local, including the authoritative one-block halo. Out-of-range
  /// reads are rejected, because ChunkData's air fallback is not proof of dry
  /// space. A nil body means no known procedural surface, not no actual water.
  public static func inspect(_ chunk: ChunkData, x: Int, z: Int, body: WaterBody?) -> Outcome {
    if Task.isCancelled { return .cancelled }
    guard (-1...16).contains(x), (-1...16).contains(z) else { return .invalidInput }
    if let body {
      guard body.level.isFinite, body.level > Float(ChunkData.minimumY),
        body.level <= Float(ChunkData.height),
        body.current.x.isFinite, body.current.y.isFinite, body.current.z.isFinite else {
        return .invalidInput
      }
    }
    var spans: [Span] = []
    var y = ChunkData.minimumY
    let top = min(ChunkData.height, chunk.maximumFilledY + 1)
    while y < top {
      if Task.isCancelled { return .cancelled }
      let block = chunk[x,y,z]
      guard block.isLiquid else { y += 1; continue }
      let lower = y
      while y < top && chunk[x,y,z] == block { y += 1 }
      spans.append(.init(lower: lower, upper: y, material: block,
        below: chunk[x,lower-1,z], above: chunk[x,y,z]))
    }
    let procedural: Int?
    if let body {
      let material: Block = body.kind == .lava ? .lava : .water
      let surface = Int(ceil(body.level))
      procedural = spans.firstIndex {
        $0.upper == surface && $0.material == material && !$0.coveredAbove
          && $0.upper < ChunkData.height
      }
    } else { procedural = nil }
    // The finite top/bottom of ChunkData is unknown outside the snapshot. A run
    // touching those limits is never an implicitly supported closed volume.
    let additional = spans.indices.filter { $0 != procedural && !spans[$0].coveredAbove }
    let bottoms = spans.indices.filter { !spans[$0].supportedBelow }
    if Task.isCancelled { return .cancelled }
    return .ready(.init(spans: spans, proceduralSurface: procedural,
      additionalSurfaces: additional, unsupportedBottoms: bottoms))
  }
}
