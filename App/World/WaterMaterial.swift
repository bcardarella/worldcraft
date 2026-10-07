import RealityKit
import UIKit

/// Loaded asynchronously once, then shared by every regional mesh. Movement is
/// carried in GPU vertex data, so no per-frame shader parameter updates occur.
@MainActor
struct WaterMaterial {
  var surface: ShaderGraphMaterial
  var horizon: ShaderGraphMaterial

  static func load() async throws -> Self {
    guard let url = Bundle.main.url(forResource: "WorldcraftWater", withExtension: "usda") else {
      throw CocoaError(.fileNoSuchFile)
    }
    var surface = try await ShaderGraphMaterial(named: "/WorldcraftWater/Surface", from: url)
    var horizon = try await ShaderGraphMaterial(named: "/WorldcraftWater/Horizon", from: url)
    // The graph decodes the normal maps explicitly. Raw prevents sRGB conversion.
    let normals = try await TextureResource(named: "WaterNormals.png", options: .init(semantic: .raw))
    let foam = try await TextureResource(named: "WaterFoam.png", options: .init(semantic: .raw))
    for key in ["Normals", "Foam"] {
      let value = key == "Normals" ? normals : foam
      try surface.setParameter(name: key, value: .textureResource(value))
      try horizon.setParameter(name: key, value: .textureResource(value))
    }
    surface.faceCulling = .none
    surface.writesDepth = false
    horizon.faceCulling = .none
    horizon.writesDepth = true
    return .init(surface: surface, horizon: horizon)
  }

  func band(_ band: Int, color: SIMD3<Float>, opaque: Bool) throws -> [any Material] {
    let tint = UIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
    var material = opaque ? horizon : surface
    try material.setParameter(name: "HazeColor", value: .color(tint.cgColor))
    try material.setParameter(name: "HazeAmount", value: .float(Float(band) / 20))
    return [material, material]
  }
}
