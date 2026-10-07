/// A conservative candidate mask for the ordinary mesher, not view culling.
/// A cube surrounded by six opaque neighbours cannot emit a face. Shaped and
/// transparent blocks remain candidates even when enclosed, so fixtures keep
/// their geometry and emitters. Bit order matches the scalar x/y/z traversal.
struct VoxelVisibility {
  private let rows: [UInt16]
  var byteCount: Int { rows.count * MemoryLayout<UInt16>.stride }

  // Read-only tables classify every valid stored byte once, outside voxel loops.
  // Bit 0: renderable; bit 1: opaque. Empty/unused raw values have neither bit.
  private static let withWater = classifications(includeWater: true)
  private static let withoutWater = classifications(includeWater: false)
  private static func classifications(includeWater: Bool) -> [UInt32] {
    var result = [UInt32](repeating: 0, count: 256)
    for block in Block.allCases {
      result[Int(block.rawValue)] = (block != .air && (includeWater || !block.isLiquid) ? 1 : 0)
        | (block.isOpaque ? 2 : 0)
    }
    return result
  }

  init?(_ chunk: ChunkData, includeWater: Bool) {
    let height = max(0, chunk.maximumFilledY - ChunkData.minimumY + 1)
    var candidates = [UInt16](repeating: 0, count: height * 16)
    // Zero planes above/below the finite world reproduce ChunkData's air halo.
    var opaque = [UInt32](repeating: 0, count: (height + 2) * 18)
    let classification = includeWater ? Self.withWater : Self.withoutWater
    let complete = chunk.archiveCells.withUnsafeBufferPointer { cells -> Bool in
      for y in 0..<height {
        if Task.isCancelled { return false }
        for z in 0..<18 {
          let base = (y * 18 + z) * 18
          var solid: UInt32 = 0, present: UInt32 = 0
          for x in 0..<18 {
            let flags = classification[Int(cells[base + x])]
            solid |= (flags >> 1) << x
            present |= (flags & 1) << x
          }
          opaque[(y + 1) * 18 + z] = solid
          if (1...16).contains(z) {
            candidates[y * 16 + z - 1] = UInt16(truncatingIfNeeded: present >> 1)
          }
        }
      }
      return true
    }
    guard complete else { return nil }
    for y in 0..<height {
      if Task.isCancelled { return nil }
      for z in 1...16 {
        let index = (y + 1) * 18 + z, row = opaque[index]
        let enclosed = row & (row << 1) & (row >> 1)
          & opaque[index - 1] & opaque[index + 1]
          & opaque[index - 18] & opaque[index + 18]
        candidates[y * 16 + z - 1] &= ~UInt16(truncatingIfNeeded: enclosed >> 1)
      }
    }
    rows = candidates
  }

  func candidates(y: Int, z: Int) -> UInt16 {
    rows[(y - ChunkData.minimumY) * 16 + z]
  }
}
