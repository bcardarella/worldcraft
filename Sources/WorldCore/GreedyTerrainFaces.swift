/// The padded atlas contract shared by ordinary quads and the repeating shader.
/// Tile selection includes face shading and contact occlusion, so faces with
/// different lighting or grass/log orientations never merge.
public enum TerrainAtlas {
  public static let repeatSpan = SIMD2<Float>(55.0 / 1024, 55.0 / 512)
  public static func tile(block: Block, face: Int, tileIndex: Int? = nil, occlusion: Int = 0) -> Int {
    let shade = min(3, (face == 2 ? 0 : (face == 3 ? 3 : (face < 2 ? 1 : 2))) + occlusion)
    return (tileIndex ?? block.tile(face: face)) + shade * 32
  }
  public static func origin(tile: Int) -> SIMD2<Float> {
    [Float(tile % 16) / 16 + 4.5 / 1024, 1 - Float(tile / 16 + 1) / 8 + 4.5 / 512]
  }
  /// CPU reference for shader sampling tests. Derivatives in the shader come
  /// from unwrapped UVs, not this discontinuous fractional coordinate.
  public static func textureCoordinate(tile: Int, repeatedUV: SIMD2<Float>) -> SIMD2<Float> {
    let fraction = repeatedUV - SIMD2(repeatedUV.x.rounded(.down), repeatedUV.y.rounded(.down))
    return origin(tile: tile) + fraction * repeatSpan
  }
}

/// Bounded chunk-local masks for static, opaque cube faces. Greedy rectangles
/// are limited to a single plane and identical atlas/shading keys. Leaves,
/// transparent surfaces and shaped blocks keep their existing geometry.
struct GreedyTerrainFaces {
  private let height: Int
  private let faceStride: Int
  private var cells: [UInt16]
  private var occupiedPlanes: [[Bool]]

  init(maximumY: Int) {
    let height = maximumY - ChunkData.minimumY + 1
    self.height = height
    faceStride = 16 * 16 * height
    cells = Array(repeating: 0, count: 6 * faceStride)
    occupiedPlanes = (0..<6).map { Array(repeating: false, count: (2...3).contains($0) ? height : 16) }
  }

  mutating func insert(x: Int, y: Int, z: Int, face: Int, tile: Int) {
    let slice: Int, u: Int, v: Int, planeHeight: Int
    switch face {
    case 0, 1: slice = x; u = z; v = y - ChunkData.minimumY; planeHeight = height
    case 2, 3: slice = y - ChunkData.minimumY; u = x; v = z; planeHeight = 16
    default: slice = z; u = x; v = y - ChunkData.minimumY; planeHeight = height
    }
    cells[face * faceStride + slice * 16 * planeHeight + v * 16 + u] = UInt16(tile + 1)
    occupiedPlanes[face][slice] = true
  }

  mutating func append(to mesh: inout VoxelMesh) {
    for face in 0..<6 {
      let planeHeight = (2...3).contains(face) ? 16 : height
      let d = VoxelMesher.offsets[face]
      for slice in occupiedPlanes[face].indices where occupiedPlanes[face][slice] {
        if Task.isCancelled { return }
        let start = face * faceStride + slice * 16 * planeHeight
        for v in 0..<planeHeight {
          var u = 0
          while u < 16 {
            let index = start + v * 16 + u, key = cells[index]
            guard key != 0 else { u += 1; continue }
            var width = 1, rows = 1
            while u + width < 16 && cells[index + width] == key { width += 1 }
            grow: while v + rows < planeHeight {
              for column in 0..<width where cells[index + rows * 16 + column] != key { break grow }
              rows += 1
            }
            for row in 0..<rows { for column in 0..<width { cells[index + row * 16 + column] = 0 } }
            let origin: SIMD3<Float>, size: SIMD3<Float>, repeats: SIMD2<Float>
            switch face {
            case 0, 1:
              origin = [Float(slice), Float(v + ChunkData.minimumY), Float(u)]
              size = [1, Float(rows), Float(width)]; repeats = [Float(width), Float(rows)]
            case 2, 3:
              origin = [Float(u), Float(slice + ChunkData.minimumY), Float(v)]
              size = [Float(width), 1, Float(rows)]; repeats = [Float(rows), Float(width)]
            default:
              origin = [Float(u), Float(v + ChunkData.minimumY), Float(slice)]
              size = [Float(width), Float(rows), 1]; repeats = [Float(width), Float(rows)]
            }
            mesh.appendRepeatedQuad(VoxelMesher.corners[face].map { origin + $0 * size },
              normal: [Float(d.x), Float(d.y), Float(d.z)], tile: Int(key) - 1, repeats: repeats)
            u += width
          }
        }
      }
    }
  }
}
