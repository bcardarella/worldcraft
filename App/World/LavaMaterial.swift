import Metal
import RealityKit
import UIKit

/// One bounded set of GPU textures for the entire molten sea, not per tile.
@MainActor
final class LavaMaterial {
  private let pipeline: any MTLComputePipelineState
  private let textures: [LowLevelTexture]
  let material: PhysicallyBasedMaterial
  private var lastUpdate: Double = -.infinity

  init(device: any MTLDevice, queue: any MTLCommandQueue) throws {
    guard let url = Bundle.main.url(forResource: "LavaSurface", withExtension: "metal.txt") else { throw CocoaError(.fileNoSuchFile) }
    let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
    guard let function = library.makeFunction(name: "animateLavaSurface") else { throw CocoaError(.coderInvalidValue) }
    pipeline = try device.makeComputePipelineState(function: function)
    textures = try (0..<4).map { _ in
      try LowLevelTexture(descriptor: .init(pixelFormat: .rgba8Unorm,
        width: 256, height: 256, mipmapLevelCount: 9, textureUsage: [.shaderRead, .shaderWrite]))
    }
    material = try Self.makeMaterial(textures.map { try TextureResource(from: $0) })
    if let command = queue.makeCommandBuffer() { encode(command: command, elapsed: 0); command.commit() }
  }

  static func fallback() throws -> PhysicallyBasedMaterial {
    try makeMaterial(["LavaSurface.png", "LavaEmission.png", "LavaNormals.png", "LavaRoughness.png"].enumerated().map { i, name in
      try TextureResource.load(named: name, options: .init(semantic: i == 2 ? .normal : .raw))
    })
  }

  private static func makeMaterial(_ maps: [TextureResource]) throws -> PhysicallyBasedMaterial {
    let sampler = MTLSamplerDescriptor()
    sampler.sAddressMode = .repeat; sampler.tAddressMode = .repeat
    sampler.minFilter = .linear; sampler.magFilter = .linear; sampler.mipFilter = .linear
    sampler.maxAnisotropy = 4
    let textures = maps.map { MaterialParameters.Texture($0, sampler: .init(sampler)) }
    var material = PhysicallyBasedMaterial()
    material.baseColor = .init(tint: .white, texture: textures[0])
    material.emissiveColor = .init(color: .white, texture: textures[1])
    material.emissiveIntensity = 0.95
    material.normal = .init(texture: textures[2])
    material.roughness = .init(texture: textures[3])
    material.specular = .init(floatLiteral: 0.08)
    material.blending = .opaque
    material.faceCulling = .none
    return material
  }

  func encode(command: any MTLCommandBuffer, elapsed: Double) {
    guard elapsed < lastUpdate || elapsed - lastUpdate >= 1.0 / 15,
      let encoder = command.makeComputeCommandEncoder() else { return }
    lastUpdate = elapsed
    let targets = textures.map { $0.replace(using: command) }
    encoder.label = "Lava crust, emission and normals"
    encoder.setComputePipelineState(pipeline)
    for (i, target) in targets.enumerated() { encoder.setTexture(target, index: i) }
    var time = Float(elapsed.truncatingRemainder(dividingBy: 10_000))
    encoder.setBytes(&time, length: MemoryLayout<Float>.stride, index: 0)
    encoder.dispatchThreads(.init(width: 256, height: 256, depth: 1),
      threadsPerThreadgroup: .init(width: 8, height: 8, depth: 1))
    encoder.endEncoding()
    if let blit = command.makeBlitCommandEncoder() {
      for target in targets { blit.generateMipmaps(for: target) }
      blit.endEncoding()
    }
  }
}
