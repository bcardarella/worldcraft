public struct VoxelMesh: Sendable {
  public var positions: [SIMD3<Float>] = []
  public var normals: [SIMD3<Float>] = []
  public var textureCoordinates: [SIMD2<Float>] = []
  public var indices: [UInt32] = []
  public var materials: [UInt32] = []
  public var windWeights: [Float] = []
  // One atlas tile per quad when repeated UVs are present. Material slot 6
  // identifies repeated faces; zeros on ordinary faces are not interpreted.
  public var repeatingAtlasTiles: [UInt16] = []
  public var lampPositions: [SIMD3<Float>] = []
  public var firePositions: [SIMD3<Float>] = []
  public var stadiumSeats: [StadiumSeatInstance] = []
  public var faceCount: Int { indices.count / 6 }
  public init() {}

  mutating func appendQuad(
    _ points: [SIMD3<Float>], normal: SIMD3<Float>, block: Block, face: Int,
    tileIndex: Int? = nil, materialIndex: UInt32? = nil, occlusion: Int = 0
  )
  {
    let start = UInt32(positions.count)
    let tile = TerrainAtlas.tile(block: block, face: face, tileIndex: tileIndex, occlusion: occlusion)
    let u = Float(tile % 16) / 16
    // USD UVs start at bottom-left, PNG atlas rows start at top-left.
    let v = 1 - Float(tile / 16) / 8
    let iu: Float = 4.5 / 1024
    let iv: Float = 4.5 / 512
    positions += points
    normals += Array(repeating: normal, count: 4)
    textureCoordinates += [
      [u + iu, v - 0.125 + iv], [u + iu, v - iv], [u + 0.0625 - iu, v - iv],
      [u + 0.0625 - iu, v - 0.125 + iv],
    ]
    indices += [start, start + 1, start + 2, start, start + 2, start + 3]
    let material: UInt32 = materialIndex
      ?? (block == .water ? 1 : (block == .glass ? 2 : (block == .lamp ? 3 : (block.isFoliage ? 4 : (block == .lava ? 5 : 0)))))
    materials += [material, material]
    if !repeatingAtlasTiles.isEmpty { repeatingAtlasTiles.append(0) }
  }

  mutating func appendRepeatedQuad(_ points: [SIMD3<Float>], normal: SIMD3<Float>,
    tile: Int, repeats: SIMD2<Float>) {
    let start = UInt32(positions.count)
    if repeatingAtlasTiles.isEmpty {
      repeatingAtlasTiles = Array(repeating: 0, count: positions.count / 4)
    }
    positions += points
    normals += Array(repeating: normal, count: 4)
    textureCoordinates += [[0, 0], [0, repeats.y], repeats, [repeats.x, 0]]
    indices += [start, start + 1, start + 2, start, start + 2, start + 3]
    materials += [6, 6]
    repeatingAtlasTiles.append(UInt16(tile))
  }

  public mutating func appendBox(size: SIMD3<Float>, center: SIMD3<Float>, material: UInt32) {
    for face in 0..<6 {
      let d = VoxelMesher.offsets[face]
      appendQuad(VoxelMesher.corners[face].map { center + ($0 - SIMD3<Float>(repeating: 0.5)) * size },
        normal: [Float(d.x), Float(d.y), Float(d.z)], block: .stone, face: face, materialIndex: material)
    }
  }

  public mutating func append(_ mesh: VoxelMesh) {
    let offset = UInt32(positions.count)
    if !repeatingAtlasTiles.isEmpty || !mesh.repeatingAtlasTiles.isEmpty {
      if repeatingAtlasTiles.isEmpty { repeatingAtlasTiles = Array(repeating: 0, count: positions.count / 4) }
      repeatingAtlasTiles += mesh.repeatingAtlasTiles.isEmpty
        ? Array(repeating: 0, count: mesh.positions.count / 4) : mesh.repeatingAtlasTiles
    }
    if !windWeights.isEmpty || !mesh.windWeights.isEmpty {
      if windWeights.isEmpty {windWeights=Array(repeating:0,count:positions.count)}
      windWeights += mesh.windWeights.isEmpty ? Array(repeating:0,count:mesh.positions.count) : mesh.windWeights
    }
    positions += mesh.positions
    normals += mesh.normals
    textureCoordinates += mesh.textureCoordinates
    firePositions += mesh.firePositions
    lampPositions += mesh.lampPositions
    stadiumSeats += mesh.stadiumSeats
    indices += mesh.indices.map { $0 + offset }
    materials += mesh.materials
  }
}

public enum VoxelMesher {
  public static let offsets: [BlockPosition] = [
    .init(1, 0, 0), .init(-1, 0, 0), .init(0, 1, 0), .init(0, -1, 0), .init(0, 0, 1),
    .init(0, 0, -1),
  ]
  static let corners: [[SIMD3<Float>]] = [
    [[1, 0, 0], [1, 1, 0], [1, 1, 1], [1, 0, 1]],
    [[0, 0, 1], [0, 1, 1], [0, 1, 0], [0, 0, 0]],
    [[0, 1, 1], [1, 1, 1], [1, 1, 0], [0, 1, 0]],
    [[0, 0, 0], [1, 0, 0], [1, 0, 1], [0, 0, 1]],
    [[1, 0, 1], [1, 1, 1], [0, 1, 1], [0, 0, 1]],
    [[0, 0, 0], [0, 1, 0], [1, 1, 0], [1, 0, 0]],
  ]

  public static func build(_ chunk: ChunkData, includeWater: Bool = true,
    repeatAtlas: Bool = false) -> VoxelMesh {
    build(chunk, includeWater: includeWater, repeatAtlas: repeatAtlas, cullHidden: true)
  }

  /// Emit only owned columns, retaining the same visibility, attributes and
  /// fixtures as complete voxel geometry. The source halo remains authoritative.
  /// An optional boundary omits its horizontal cube faces; a validated seam
  /// must replace them before publication. Shaped/liquid boundaries need detail.
  public static func build(_ chunk: ChunkData, columns: VoxelColumnMask,
    includeWater: Bool = true, repeatAtlas: Bool = false, boundary: VoxelColumnBoundary? = nil) -> VoxelMesh {
    precondition(boundary == nil || boundary!.columns == columns)
    return build(chunk, includeWater: includeWater, repeatAtlas: repeatAtlas, cullHidden: true, columns: columns, boundary: boundary)
  }

  /// Optional preparation path for a validated, bounded feature patch. Omit
  /// ordinary cube faces only when they border known enclosed air in this same
  /// immutable chunk source. Liquids, cutout/transparent neighbours, fixtures,
  /// unknown columns and halo faces retain their normal rendering rules.
  /// A stale visibility source falls back to the complete owned geometry.
  /// The caller still owns connectivity seeds, view/world validity and seams;
  /// this overload alone does not authorize publishing the resulting patch.
  public static func build(_ source: VoxelPatchExposure.Source, columns: VoxelColumnMask,
    enclosedAir: VoxelPatchExposure.EnclosedAir, includeWater: Bool = true,
    repeatAtlas: Bool = false, boundary: VoxelColumnBoundary? = nil) -> VoxelMesh {
    precondition(boundary == nil || boundary!.columns == columns)
    return build(source.chunk, includeWater: includeWater, repeatAtlas: repeatAtlas, cullHidden: true,
      columns: columns, boundary: boundary, enclosedAir: enclosedAir.matches(source) ? enclosedAir : nil)
  }

  // Retain the scalar traversal as an independent comparison for exact-output
  // tests and host measurements. It shares the unchanged face/shading rules.
  static func build(_ chunk: ChunkData, includeWater: Bool,
    repeatAtlas: Bool, cullHidden: Bool, columns: VoxelColumnMask? = nil,
    boundary: VoxelColumnBoundary? = nil, enclosedAir: VoxelPatchExposure.EnclosedAir? = nil) -> VoxelMesh {
    var mesh = VoxelMesh()
    guard chunk.maximumFilledY >= ChunkData.minimumY, columns?.isEmpty != true else { return mesh }
    let visibility = cullHidden ? VoxelVisibility(chunk, includeWater: includeWater) : nil
    if Task.isCancelled { return mesh }
    var merged = repeatAtlas ? GreedyTerrainFaces(maximumY: chunk.maximumFilledY) : nil
    for y in ChunkData.minimumY...chunk.maximumFilledY {
      if Task.isCancelled { return mesh }
      for z in 0..<16 {
        let owned = columns?.row(z) ?? UInt16.max
        if owned == 0 { continue }
        var candidates = (visibility?.candidates(y: y, z: z) ?? UInt16.max) & owned
        while candidates != 0 {
          let x = candidates.trailingZeroBitCount
          candidates &= candidates - 1
          let block = chunk[x, y, z]
          guard block != .air, includeWater || !block.isLiquid else { continue }
          if block == .lantern {
            let origin=SIMD3<Float>(Float(x),Float(y),Float(z))
            // Warm frosted diffuser, a bright bulb, metal cap, base and guard.
            var pieces: [(SIMD3<Float>,SIMD3<Float>,Block)] = [
              ([0.5,0.1,0.5],[0.64,0.16,0.64],.basalt),
              ([0.5,0.9,0.5],[0.76,0.14,0.76],.basalt),
              ([0.5,0.5,0.5],[0.4,0.62,0.4],.lamp)]
            for dx: Float in [0.22,0.78] { for dz: Float in [0.22,0.78] { pieces.append(([dx,0.5,dz],[0.06,0.72,0.06],.basalt)) } }
            for (center,size,material) in pieces { for face in 0..<6 {
              let d=offsets[face]
              mesh.appendQuad(corners[face].map { origin+center+($0-SIMD3<Float>(repeating:0.5))*size },
                normal:[Float(d.x),Float(d.y),Float(d.z)],block:material,face:face)
            } }
            mesh.lampPositions.append(origin+[0.5,0.5,0.5]); continue
          }
          if block.isStair {
            let origin=SIMD3<Float>(Float(x),Float(y),Float(z))
            for box in block.collisionBoxes { for face in 0..<6 {
              let d=offsets[face]
              mesh.appendQuad(corners[face].map { origin+box.center+($0-SIMD3<Float>(repeating:0.5))*box.size },
                normal:[Float(d.x),Float(d.y),Float(d.z)],block:block.stairMaterial,face:face)
            } }
            continue
          }
          if block == .torch {
            let origin = SIMD3<Float>(Float(x), Float(y), Float(z))
            // A timber handle and dark brazier, with fire supplied by the GPU
            // particle system. No opaque glowing cube pretending to be flame.
            for (center, size, material) in [
              (SIMD3<Float>(0.5,0.38,0.5), SIMD3<Float>(0.16,0.76,0.16), Block.wood),
              (SIMD3<Float>(0.5,0.75,0.5), SIMD3<Float>(0.38,0.16,0.38), Block.basalt),
              (SIMD3<Float>(0.5,0.84,0.5), SIMD3<Float>(0.25,0.025,0.25), Block.lamp)
            ] {
              for face in 0..<6 {
                let d = offsets[face]
                mesh.appendQuad(corners[face].map { origin+center+($0-SIMD3<Float>(repeating:0.5))*size },
                  normal:[Float(d.x),Float(d.y),Float(d.z)],block:material,face:face)
              }
            }
            if chunk[x,y+1,z] != .water && chunk[x,y+1,z] != .lava {
              mesh.firePositions.append(origin+[0.5,0.85,0.5])
            }
            continue
          }
          for face in 0..<6 {
            if boundary?.contains(x: x, z: z, face: face) == true { continue }
            let d = offsets[face]
            let neighbor = chunk[x + d.x, y + d.y, z + d.z]
            if neighbor.isOpaque || neighbor == block || (y == ChunkData.minimumY && face == 3) {
              continue
            }
            if neighbor == .air && !block.isLiquid
              && enclosedAir?.contains(x: x + d.x, y: y + d.y, z: z + d.z) == true { continue }
            // Solid blocks still draw their boundary against transparent blocks.
            let contact = face == 2 && !block.isFoliage
              ? [chunk[x - 1, y + 1, z], chunk[x + 1, y + 1, z],
                 chunk[x, y + 1, z - 1], chunk[x, y + 1, z + 1]].filter(\.isOpaque).count : 0
            if repeatAtlas && block.isOpaque && !block.isFoliage && block != .lamp {
              merged!.insert(x: x, y: y, z: z, face: face,
                tile: TerrainAtlas.tile(block: block, face: face, occlusion: min(2, contact)))
            } else {
              mesh.appendQuad(
                corners[face].map { $0 + SIMD3(Float(x), Float(y), Float(z)) },
                normal: [Float(d.x), Float(d.y), Float(d.z)], block: block, face: face,
                occlusion: min(2, contact))
            }
          }
        }
      }
    }
    merged?.append(to: &mesh)
    return mesh
  }
}
