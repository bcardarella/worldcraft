/// Geometry ownership for a subset of a chunk's horizontal columns. Neighbour
/// visibility still uses the original voxel cells/halo; a missing column does
/// not imply air or add a cap. Surface transitions must be provided separately.
/// Sixteen UInt16 rows occupy 32 bytes with no heap allocation.
public struct VoxelColumnMask: Sendable, Equatable {
  private var rows: SIMD16<UInt16>
  public init() { rows = .zero }
  private init(rows: SIMD16<UInt16>) { self.rows = rows }
  public static let full = Self(rows: .init(repeating: .max))
  public var isEmpty: Bool { rows == .zero }
  public var count: Int { (0..<16).reduce(0) { $0 + rows[$1].nonzeroBitCount } }
  public func row(_ z: Int) -> UInt16 {
    precondition((0..<16).contains(z))
    return rows[z]
  }
  public func contains(x: Int, z: Int) -> Bool {
    guard (0..<16).contains(x), (0..<16).contains(z) else { return false }
    return rows[z] & (1 << x) != 0
  }
  /// Include a half-open rectangle after clipping it to the chunk. This also
  /// handles a one-block collar crossing negative world/chunk coordinates.
  public mutating func include(x: Range<Int>, z: Range<Int>) {
    let lowX = max(0, x.lowerBound), highX = min(16, x.upperBound)
    let lowZ = max(0, z.lowerBound), highZ = min(16, z.upperBound)
    guard lowX < highX, lowZ < highZ else { return }
    let bits = UInt16(truncatingIfNeeded: ((UInt32(1) << highX) - 1) ^ ((UInt32(1) << lowX) - 1))
    for row in lowZ..<highZ { rows[row] |= bits }
  }
  public mutating func formUnion(_ other: Self) { rows |= other.rows }
}
