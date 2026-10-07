import Metal
import RealityKit
import WorldCore

@MainActor enum TerrainMeshResource {
  static func make(_ source: PackedTerrainMesh) throws -> MeshResource {
    try MeshResource(from:makeLowLevel(source))
  }
  static func makeLowLevel(_ source: PackedTerrainMesh, capacity supplied: TerrainMeshCapacity? = nil) throws -> LowLevelMesh {
    let capacity = supplied ?? .init(vertices: source.vertices.count, indices: source.indices.count, rounded: false)
    precondition(capacity.vertices >= source.vertices.count && capacity.indices >= source.indices.count)
    let layout = LowLevelMesh.Descriptor(
      vertexCapacity: capacity.vertices,
      vertexAttributes: [
        .init(semantic: .position, format: .float3, offset: 0),
        .init(semantic: .normal, format: .half3, offset: 16),
        .init(semantic: .uv0, format: .half2, offset: 12),
        // UV1.y aliases tangent.w (an exact half-float atlas tile, 0...127).
        // UV1.x aliases tangent.z and is deliberately ignored by the graph.
        // This preserves the existing 40-byte ABI, including wind kernels.
        .init(semantic: .uv1, format: .half2, offset: TerrainVertex.repeatingAtlasUVOffset),
        .init(semantic: .tangent, format: .half3, offset: 24),
        .init(semantic: .bitangent, format: .half3, offset: 32),
      ], vertexLayouts: [.init(bufferIndex: 0, bufferStride: MemoryLayout<TerrainVertex>.stride)],
      indexCapacity: capacity.indices)
    let mesh = try LowLevelMesh(descriptor: layout)
    // Keep the existing initialization path for new meshes, including wind
    // and actor callers. Only reused resources need replacement accessors.
    mesh.withUnsafeMutableBytes(bufferIndex: 0) { target in
      source.vertices.withUnsafeBytes { copy($0, into: target) }
    }
    mesh.withUnsafeMutableIndices { target in
      source.indices.withUnsafeBytes { copy($0, into: target) }
    }
    replaceParts(source, in: mesh)
    return mesh
  }

  /// Replacement accessors supply fresh contents instead of reading the old
  /// GPU data back to the CPU. Only detached static resources are pooled; an
  /// in-flight wind mesh is never overwritten by a new terrain owner.
  static func replace(_ source: PackedTerrainMesh, in mesh: LowLevelMesh) {
    precondition(source.vertices.count <= mesh.vertexCapacity && source.indices.count <= mesh.indexCapacity)
    mesh.replaceUnsafeMutableBytes(bufferIndex: 0) { target in
      source.vertices.withUnsafeBytes { copy($0, into: target) }
    }
    mesh.replaceUnsafeMutableIndices { target in
      source.indices.withUnsafeBytes { copy($0, into: target) }
    }
    replaceParts(source, in: mesh)
  }

  private static func copy(_ source: UnsafeRawBufferPointer, into target: UnsafeMutableRawBufferPointer) {
    precondition(source.count <= target.count)
    UnsafeMutableRawBufferPointer(rebasing: target.prefix(source.count)).copyMemory(from: source)
    if source.count < target.count {
      target.baseAddress!.advanced(by: source.count).initializeMemory(as: UInt8.self, repeating: 0, count: target.count - source.count)
    }
  }

  private static func replaceParts(_ source: PackedTerrainMesh, in mesh: LowLevelMesh) {
    mesh.parts.replaceAll(
      source.parts.map {
        .init(
          indexOffset: $0.offset * 4, indexCount: $0.count, materialIndex: $0.material,
          bounds: .init(min: $0.minimum-[0.5,0.1,0.5], max: $0.maximum+[0.5,0.1,0.5]))
      })
  }
}
