import Foundation
import Metal

/// Run on a Mac with a Metal device. Checks the shipped shader against the CPU
/// swimming/wave model, including large coordinates, lakes, rivers, lava and body IDs.
@main struct ValidateWaterGPU {
  struct Source {
    var geometry: SIMD4<Float>
    var identity: SIMD4<UInt32>
  }
  struct Uniforms {
    var clockAndOrigin: SIMD4<Float>
    var counts: SIMD4<UInt32>
  }
  struct Ripple {
    var wave: SIMD4<Float>
    var identity: SIMD4<UInt32>
  }
  struct Vertex {
    var px, py, pz: Float
    var uv: SIMD2<Float>
    var normal, tangent, bitangent: SIMD4<UInt16>
    var detailUV: SIMD2<Float>
    var optics: SIMD4<UInt16>
  }
  static func main() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      print("SKIPPED: no Metal device is exposed to this process. GPU execution is unverified.")
      return
    }
    let lavaLibrary = try device.makeLibrary(
      source: String(contentsOfFile: "App/Shaders/LavaSurface.metal.txt", encoding: .utf8), options: nil)
    _ = try device.makeComputePipelineState(function: lavaLibrary.makeFunction(name: "animateLavaSurface")!)
    let library = try device.makeLibrary(
      source: String(contentsOfFile: "App/Shaders/WaterAnimation.metal.txt", encoding: .utf8),
      options: nil)
    let pipeline = try device.makeComputePipelineState(
      function: library.makeFunction(name: "animateWorldWater")!)
    precondition(MemoryLayout<Vertex>.stride == 64)
    let lake = WaterBody(id: 0x1234_5678_8765_4321, kind: .lake, level: 41)
    let bodies = [WaterBody.ocean, lake, .lava, WaterBody(id: 0x7269766572, kind: .river, level: 24, current: [0.5, 0, 2])]
    var cases = 0
    var maximumHeightError: Float = 0
    var maximumNormalError: Float = 0
    var maximumOpticsError: Float = 0
    for time in [0.0, 456, 9_999.9, 10_000.1, 2_400_123] {
      for origin: SIMD2<Float> in [[0, 0], [-8_192, 4_096], [131_072, -65_536]] {
        var environment = WorldEnvironment(elapsed: time)
        for body in bodies {
          environment.disturbWater(atX: origin.x + 12, z: origin.y + 9, body: body, energy: 0.24)
        }
        environment.advance(1.25)
        let samples = (0..<96).map { i -> Source in
          let body = bodies[i % bodies.count]
          return .init(
            geometry: [Float(i % 12) * 2, Float(i / 12) * 2, Float(i % 9), body.level],
            identity: [
              UInt32(truncatingIfNeeded: body.id), UInt32(truncatingIfNeeded: body.id >> 32),
              UInt32(body.kind.rawValue), UInt32(Float16(body.current.x).bitPattern) | (UInt32(Float16(body.current.z).bitPattern) << 16),
            ])
        }
        let input = samples.withUnsafeBytes {
          device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)!
        }
        let output = device.makeBuffer(
          length: samples.count * MemoryLayout<Vertex>.stride, options: .storageModeShared)!
        var uniforms = Uniforms(
          clockAndOrigin: [
            Float(environment.elapsed.truncatingRemainder(dividingBy: 10_000)), environment.tide,
            origin.x, origin.y,
          ],
          counts: [UInt32(samples.count), UInt32(environment.disturbances.count), 0, 0])
        let ripples = environment.disturbances.map { r in
          Ripple(
            wave: [r.x, r.z, Float(environment.elapsed - r.onset), r.energy],
            identity: [
              UInt32(truncatingIfNeeded: r.bodyID), UInt32(truncatingIfNeeded: r.bodyID >> 32), 0,
              0,
            ])
        }
        let command = queue.makeCommandBuffer()!
        let encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
        ripples.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 3) }
        encoder.dispatchThreads(
          .init(width: samples.count, height: 1, depth: 1),
          threadsPerThreadgroup: .init(width: 32, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        let vertices = output.contents().bindMemory(to: Vertex.self, capacity: samples.count)
        for i in samples.indices {
          let s = samples[i]
          let v = vertices[i]
          let expected = environment.water(
            atX: origin.x + s.geometry.x, z: origin.y + s.geometry.y, depth: s.geometry.z,
            body: bodies[i % bodies.count])
          let n = SIMD3<Float>(
            Float(Float16(bitPattern: v.normal.x)), Float(Float16(bitPattern: v.normal.y)),
            Float(Float16(bitPattern: v.normal.z)))
          maximumHeightError = max(maximumHeightError, abs(v.py - expected.height))
          let optics = WaterAppearance.optics(depth: s.geometry.z, body: bodies[i % bodies.count], sample: expected)
          for axis in 0..<4 {
            maximumOpticsError = max(maximumOpticsError, abs(Float(Float16(bitPattern: v.optics[axis])) - optics[axis]))
          }
          maximumNormalError = max(
            maximumNormalError,
            max(
              abs(n.x - expected.normal.x), abs(n.y - expected.normal.y),
              abs(n.z - expected.normal.z)))
          precondition(v.px == s.geometry.x && v.pz == s.geometry.y)
          precondition(v.py.isFinite && v.uv.x.isFinite && v.uv.y.isFinite)
          cases += 1
        }
      }
    }
    precondition(
      maximumHeightError < 0.015 && maximumNormalError < 0.008 && maximumOpticsError < 0.02, "Water GPU/CPU models differ")
    print(
      "PASS: \(cases) GPU/CPU samples on \(device.name); max height error \(maximumHeightError) blocks; max normal error \(maximumNormalError); max optical error \(maximumOpticsError)"
    )
  }
}
