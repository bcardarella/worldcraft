/// A stepped, solid voxel silhouette with separate joints for a bipedal gait,
/// tail sway and a hinged toothy jaw. Material slots: coat, belly, dark, teeth.
public enum RexSculpture {
  public enum Part: CaseIterable, Sendable { case body, head, jaw, leg, tail }
  public static func mesh(_ part: Part, pattern: Int = 0) -> VoxelMesh {
    var s = VoxelShape()
    switch part {
    case .body:
      s.fill(-3...3, 7...13, -2...4, tile: 0)
      s.fill(-2...2, 12...16, -4...0, tile: 0)
      s.fill(-2...2, 8...12, -3 ... -3, tile: 1)
      s.fill(-2...2, 14...15, 1...3, tile: 2)
      for side in [-1, 1] {
        s.fill((side * 4)...(side * 4), 10...11, -3 ... -1, tile: 0)
        s.fill((side * 4)...(side * 4), 9...9, -4 ... -3, tile: 1)
        if pattern == 1 {
          for z in [-1, 2, 4] { s.fill((side * 3)...(side * 3), 9...13, z...z, tile: 2) }
        } else if pattern == 2 {
          for z in [-1, 1, 3] { s.put(side * 3, 11 + z % 2, z, tile: 1) }
        }
      }
      for z in [0, 2, 4] { s.put(0, 14, z, tile: 2) }
    case .head:
      s.fill(-3...3, 0...4, -5...0, tile: 0)
      s.fill(-2...2, 0...2, -8 ... -6, tile: 0)
      for side in [-1, 1] {
        s.put(side * 3, 2, -4, tile: 3)
        s.put(side * 3, 2, -5, tile: 2)
        s.fill((side * 3)...(side * 3), 3...3, -5 ... -3, tile: 2)
        for z in [-7, -5, -3] { s.put(side * 2, -1, z, tile: 3) }
        s.put(side * 2, 1, -8, tile: 2)
        s.fill((side * 3)...(side * 3), 0...0, -4 ... -2, tile: 1)
        s.put(side * 2, 4, -4, tile: pattern == 2 ? 1 : 2)
      }
      s.fill(-1...1, 5...5, -3 ... -1, tile: 0)
    case .jaw:
      s.fill(-2...2, -1...0, -8 ... -1, tile: 1)
      s.fill(-1...1, 0...0, -7 ... -2, tile: 2)
      for side in [-1, 1] { for z in [-6, -4, -2] { s.put(side * 2, 1, z, tile: 3) } }
    case .leg:
      s.fill(-1...1, -4...0, -1...1, tile: 0)
      s.fill(0...1, -7 ... -4, 0...1, tile: 1)
      s.fill(-1...1, -7 ... -7, -3...1, tile: 0)
      for x in [-1, 0, 1] { s.put(x, -7, -4, tile: 3) }
    case .tail:
      for z in 0...13 {
        let radius = max(0, 2 - z / 5), y = max(-2, -z / 4)
        s.fill(-radius...radius, y...(y + radius * 2), z...z, tile: z % 5 == 0 ? 2 : 0)
      }
    }
    return s.mesh(cellSize: 0.3, material: nil)
  }
}
