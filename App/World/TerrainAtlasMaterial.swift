import RealityKit
import UIKit

/// One shared program for static merged block faces. The shader repeats inside
/// padded atlas cells with explicit derivatives; it never stretches one block
/// texture over a wall. Loading is optional and does not gate scene startup.
@MainActor
struct TerrainAtlasMaterial {
  var surface: ShaderGraphMaterial

  static func load(atlas: TextureResource) async throws -> Self {
    guard let url = Bundle.main.url(forResource: "WorldcraftTerrain", withExtension: "usda") else {
      throw CocoaError(.fileNoSuchFile)
    }
    var surface = try await ShaderGraphMaterial(named: "/WorldcraftTerrain/Repeated", from: url)
    // Raw RGB is decoded to tangent-space normals by the graph, matching the
    // ordinary PBR material's normal-map contract without colour conversion.
    let normal = try await TextureResource(named: "BlockNormals.png", options: .init(semantic: .raw))
    let occlusion = try await TextureResource(named: "BlockOcclusion.png", options: .init(semantic: .raw))
    try surface.setParameter(name: "Atlas", value: .textureResource(atlas))
    try surface.setParameter(name: "Normals", value: .textureResource(normal))
    try surface.setParameter(name: "Occlusion", value: .textureResource(occlusion))
    surface.faceCulling = .back
    surface.writesDepth = true
    let result = Self(surface: surface)
    // Validate every dynamically used parameter before requesting greedy data.
    _ = try result.band(20, color: [0.3, 0.5, 0.6])
    return result
  }

  func band(_ band: Int, color: SIMD3<Float>) throws -> ShaderGraphMaterial {
    var material = surface
    let tint = UIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
    try material.setParameter(name: "HazeColor", value: .color(tint.cgColor))
    try material.setParameter(name: "HazeAmount", value: .float(Float(band) / 20))
    return material
  }
}
