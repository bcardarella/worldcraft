/// Vertex layout shared with RealityKit's LowLevelMesh. Float positions retain world precision; half-precision
/// normals, UVs and tangent frames reduce bandwidth to 40 bytes per vertex.
/// tangent.w carries a constant atlas tile for repeated opaque faces (slot 6).
/// It does not alter the xyz tangent frame or wind's normal.w weight.
public struct TerrainVertex: Sendable {
  // UV1 aliases tangent.zw; y carries the tile, x is ignored. Four-byte aligned
  // for both Apple GPUs and the Mac GPU families used by the Simulator.
  public static let repeatingAtlasUVOffset = 28
  public var px, py, pz: Float
  public var u, v: UInt16
  public var normal: SIMD4<UInt16>
  public var tangent: SIMD4<UInt16>
  public var bitangent: SIMD4<UInt16>
  public init(
    position p: SIMD3<Float>, normal n: SIMD3<Float>, uv: SIMD2<Float>,
    tangent t: SIMD3<Float>, bitangent b: SIMD3<Float>
  ) {
    px = p.x
    py = p.y
    pz = p.z
    u = Float16(uv.x).bitPattern
    v = Float16(uv.y).bitPattern
    func packed(_ vector: SIMD3<Float>) -> SIMD4<UInt16> {
      [Float16(vector.x).bitPattern, Float16(vector.y).bitPattern, Float16(vector.z).bitPattern, 0]
    }
    normal = packed(n)
    tangent = packed(t)
    bitangent = packed(b)
  }
}
public struct PackedTerrainMesh: Sendable {
  public struct Part: Sendable {
    public let offset: Int
    public let count: Int
    public let material: Int
    public let minimum: SIMD3<Float>
    public let maximum: SIMD3<Float>
  }
  public let vertices: [TerrainVertex]
  public let indices: [UInt32]
  public let parts: [Part]
  public var byteCount: Int {
    vertices.count * MemoryLayout<TerrainVertex>.stride + indices.count * 4
  }
  // Internal archive decoding validates indices, bounds and material slots first.
  init(vertices: [TerrainVertex], indices: [UInt32], parts: [Part]) {
    self.vertices = vertices; self.indices = indices; self.parts = parts
  }

  /// Keep buildings, ground and stone out of the buffer replaced by wind.
  /// Preserves every triangle, UV, material and weight; only ownership changes.
  public func separatingWind(indexed: Bool = true) -> (stationary: Self, animated: Self?) {
    guard vertices.contains(where: { $0.normal.w != 0 }) else { return (self, nil) }
    if !indexed { return separatingWindHashed() }
    // Source indices already form a dense, bounded address space. A pair of
    // direct maps avoids hashing each triangle corner, without welding vertices
    // or changing first-use ordering. A shared vertex can belong to both groups.
    var stationary = WindPartition(vertexCount: vertices.count)
    var animated = WindPartition(vertexCount: vertices.count)
    for part in parts {
      stationary.beginPart(); animated.beginPart()
      for triangle in stride(from: part.offset, to: part.offset + part.count, by: 3) {
        let a = indices[triangle], b = indices[triangle+1], c = indices[triangle+2]
        if vertices[Int(a)].normal.w != 0 || vertices[Int(b)].normal.w != 0 || vertices[Int(c)].normal.w != 0 {
          animated.append(a, source: vertices); animated.append(b, source: vertices); animated.append(c, source: vertices)
        } else {
          stationary.append(a, source: vertices); stationary.append(b, source: vertices); stationary.append(c, source: vertices)
        }
      }
      stationary.finishPart(material: part.material); animated.finishPart(material: part.material)
    }
    return (stationary.mesh, animated.mesh)
  }

  private struct WindPartition {
    var vertices: [TerrainVertex] = []
    var indices: [UInt32] = []
    var parts: [Part] = []
    var remap: [UInt32]
    var start = 0
    var minimum = SIMD3<Float>(repeating: .infinity)
    var maximum = SIMD3<Float>(repeating: -.infinity)
    init(vertexCount: Int) { remap = .init(repeating: .max, count: vertexCount) }
    mutating func beginPart() {
      start = indices.count
      minimum = .init(repeating: .infinity); maximum = .init(repeating: -.infinity)
    }
    mutating func append(_ old: UInt32, source: [TerrainVertex]) {
      let vertex = source[Int(old)]
      var index = remap[Int(old)]
      if index == .max {
        index = UInt32(vertices.count); remap[Int(old)] = index
        vertices.append(vertex)
      }
      indices.append(index)
      let position = SIMD3(vertex.px, vertex.py, vertex.pz)
      minimum = componentMin(minimum, position); maximum = componentMax(maximum, position)
    }
    mutating func finishPart(material: Int) {
      if indices.count > start {
        parts.append(.init(offset: start, count: indices.count-start, material: material,
          minimum: minimum, maximum: maximum))
      }
    }
    var mesh: PackedTerrainMesh { .init(vertices: vertices, indices: indices, parts: parts) }
  }

  /// Original path retained for matched measurements and device rollback.
  private func separatingWindHashed() -> (stationary: Self, animated: Self?) {
    var outputVertices = [[TerrainVertex](), [TerrainVertex]()]
    var outputIndices = [[UInt32](), [UInt32]()]
    var outputParts = [[Part](), [Part]()]
    var remaps = [[UInt32: UInt32](), [UInt32: UInt32]()]
    for part in parts {
      let starts = outputIndices.map(\.count)
      var lows = [SIMD3<Float>](repeating: .init(repeating: .infinity), count: 2)
      var highs = [SIMD3<Float>](repeating: .init(repeating: -.infinity), count: 2)
      for triangle in stride(from: part.offset, to: part.offset + part.count, by: 3) {
        let corners = indices[triangle..<(triangle + 3)]
        let group = corners.contains { vertices[Int($0)].normal.w != 0 } ? 1 : 0
        for old in corners {
          let vertex = vertices[Int(old)]
          let index: UInt32
          if let existing = remaps[group][old] { index = existing }
          else {
            index = UInt32(outputVertices[group].count)
            remaps[group][old] = index; outputVertices[group].append(vertex)
          }
          outputIndices[group].append(index)
          let position = SIMD3(vertex.px, vertex.py, vertex.pz)
          lows[group] = componentMin(lows[group], position)
          highs[group] = componentMax(highs[group], position)
        }
      }
      for group in 0..<2 where outputIndices[group].count > starts[group] {
        outputParts[group].append(.init(offset: starts[group], count: outputIndices[group].count - starts[group],
          material: part.material, minimum: lows[group], maximum: highs[group]))
      }
    }
    return (.init(vertices: outputVertices[0], indices: outputIndices[0], parts: outputParts[0]),
      .init(vertices: outputVertices[1], indices: outputIndices[1], parts: outputParts[1]))
  }
  public init(_ mesh: VoxelMesh, repeatOpaqueAtlas: Bool = false) {
    var vertices: [TerrainVertex] = []
    vertices.reserveCapacity(mesh.positions.count)
    // All current mesh builders emit independent textured quads. Derive their
    // actual UV basis instead of asking MeshResource.generate to rebuild it.
    for start in stride(from: 0, to: mesh.positions.count, by: 4) {
      let convertOpaque = repeatOpaqueAtlas && mesh.materials[start / 2] == 0
      let ordinaryUV = mesh.textureCoordinates[start]
      let ordinaryTile = Int(ordinaryUV.x * 16) + Int((1 - ordinaryUV.y) * 8) * 16
      let e1 = mesh.positions[start + 1] - mesh.positions[start]
      let e2 = mesh.positions[start + 2] - mesh.positions[start]
      let uv1 = mesh.textureCoordinates[start + 1] - mesh.textureCoordinates[start]
      let uv2 = mesh.textureCoordinates[start + 2] - mesh.textureCoordinates[start]
      let determinant = uv1.x * uv2.y - uv1.y * uv2.x
      let reciprocal: Float = abs(determinant) < 0.000001 ? 0 : 1 / determinant
      let tangent = normalized((e1 * uv2.y - e2 * uv1.y) * reciprocal)
      let bitangent = normalized((e2 * uv1.x - e1 * uv2.x) * reciprocal)
      for i in start..<(start + 4) {
        let p = mesh.positions[i]
        let n = mesh.normals[i]
        // Shaped fixtures and wind-driven plants retain their original quads,
        // but share the repeating opaque material. A single repeat reproduces
        // the old padded atlas mapping without adding another draw per chunk.
        let uv: SIMD2<Float> = convertOpaque
          ? (i - start == 0 ? [0, 0] : i - start == 1 ? [0, 1] : i - start == 2 ? [1, 1] : [1, 0])
          : mesh.textureCoordinates[i]
        vertices.append(
          .init(position: p, normal: n, uv: uv, tangent: tangent, bitangent: bitangent))
        let foliage:Float=mesh.materials[start/2] == 4 ? 0.35:0
        let weight=mesh.windWeights.indices.contains(i) ? max(foliage,mesh.windWeights[i]):foliage
        vertices[vertices.count-1].normal.w=Float16(weight).bitPattern
        if mesh.materials[start / 2] == 6, mesh.repeatingAtlasTiles.indices.contains(start / 4) {
          vertices[vertices.count - 1].tangent.w = Float16(mesh.repeatingAtlasTiles[start / 4]).bitPattern
        } else if convertOpaque {
          vertices[vertices.count - 1].tangent.w = Float16(ordinaryTile).bitPattern
        }
      }
    }
    // This packer also handles actor sculptures. Their palettes can contain
    // more materials than the six terrain slots (residents already use seven).
    let mappedMaterials = repeatOpaqueAtlas ? mesh.materials.map { $0 == 0 ? 6 : $0 } : mesh.materials
    let materialCount = mappedMaterials.max().map { Int($0) + 1 } ?? 0
    var grouped = [[UInt32]](repeating: [], count: materialCount)
    var lows = [SIMD3<Float>](repeating: .init(repeating: .infinity), count: materialCount)
    var highs = [SIMD3<Float>](repeating: .init(repeating: -.infinity), count: materialCount)
    for triangle in mesh.materials.indices {
      let material = Int(mappedMaterials[triangle])
      for index in mesh.indices[(triangle * 3)..<(triangle * 3 + 3)] {
        grouped[material].append(index)
        lows[material] = componentMin(lows[material], mesh.positions[Int(index)])
        highs[material] = componentMax(highs[material], mesh.positions[Int(index)])
      }
    }
    var indices: [UInt32] = []
    var parts: [Part] = []
    indices.reserveCapacity(mesh.indices.count)
    for material in grouped.indices where !grouped[material].isEmpty {
      parts.append(
        .init(
          offset: indices.count, count: grouped[material].count,
          material: material, minimum: lows[material], maximum: highs[material]))
      indices += grouped[material]
    }
    self.vertices = vertices
    self.indices = indices
    self.parts = parts
  }
}
