/// Small solid sculptures use the same outward-wound face builder as terrain.
/// Adjacent cells share no internal faces; plants are real volumes, not cards.
public struct VoxelShape: Sendable {
  private var cells: [BlockPosition: Int] = [:]
  public init() {}
  public mutating func put(_ x: Int, _ y: Int, _ z: Int, tile: Int) {
    cells[.init(x, y, z)] = tile
  }
  public mutating func fill(_ x: ClosedRange<Int>, _ y: ClosedRange<Int>, _ z: ClosedRange<Int>, tile: Int) {
    for a in x { for b in y { for c in z { put(a, b, c, tile: tile) } } }
  }
  public func mesh(cellSize: Float, origin: SIMD3<Float> = .zero, material: UInt32? = 0) -> VoxelMesh {
    var result = VoxelMesh()
    let ordered = cells.keys.sorted(by: { ($0.y, $0.z, $0.x) < ($1.y, $1.z, $1.x) })
    for face in 0..<6 {
      var remaining = Set(ordered.filter { cells[$0 + VoxelMesher.offsets[face]] == nil })
      let axes = face < 2 ? [1, 2] : (face < 4 ? [0, 2] : [0, 1])
      func offset(_ cell: BlockPosition, _ a: Int, _ b: Int) -> BlockPosition {
        var point = [cell.x, cell.y, cell.z]
        point[axes[0]] += a; point[axes[1]] += b
        return .init(point[0], point[1], point[2])
      }
      for cell in ordered where remaining.contains(cell) {
        let tile = cells[cell]!
        var width = 1, height = 1
        while remaining.contains(offset(cell, width, 0)) && cells[offset(cell, width, 0)] == tile { width += 1 }
        rows: while true {
          for a in 0..<width {
            let next = offset(cell, a, height)
            if !remaining.contains(next) || cells[next] != tile { break rows }
          }
          height += 1
        }
        for a in 0..<width { for b in 0..<height { remaining.remove(offset(cell, a, b)) } }
        let d = VoxelMesher.offsets[face]
        result.appendQuad(VoxelMesher.corners[face].map {
          var corner = $0
          corner[axes[0]] *= Float(width); corner[axes[1]] *= Float(height)
          return (corner + SIMD3<Float>(Float(cell.x), Float(cell.y), Float(cell.z))) * cellSize + origin
        }, normal: [Float(d.x), Float(d.y), Float(d.z)], block: .grass,
          face: face, tileIndex: tile, materialIndex: material ?? UInt32(tile))
      }
    }
    return result
  }
}
