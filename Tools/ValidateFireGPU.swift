import Foundation
import Metal
import WorldCore

/// Run after building WorldCore on a Mac with Metal. Exercises the actual shipped
/// kernel, including its unused-slot writes, atlas UVs and CPU fallback parity.
@main struct ValidateFireGPU {
  static func main() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      print("SKIPPED: no Metal device exposed; fire kernel execution remains unverified.")
      return
    }
    let library = try device.makeLibrary(source: String(contentsOfFile: "App/Shaders/FireParticles.metal.txt", encoding: .utf8), options: nil)
    let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "animateFireParticles")!)
    var maxPositionError: Float = 0, tested = 0
    for count in [1, 2, 20] {
      let sources = (0..<count).map { i in
        FireParticleSource(position: [Float(i * 4) - 31.5, 8.85, Float(i * 2) + 14.5], breeze: [-1, 0, 1])
      }
      for time: Float in [0, 0.017, 7.75, 331.3, 4_095.9] {
        let eye = SIMD3<Float>(20, 14, -30)
        let reference = FireParticles.vertices(sources: sources, time: time, eye: eye)
        let output = device.makeBuffer(length: FireParticles.vertexCapacity * MemoryLayout<FireParticleVertex>.stride, options: .storageModeShared)!
        memset(output.contents(), 0xff, output.length)
        var frame = FireParticleFrame(eye: eye, time: time, sources: count)
        let command = queue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline)
        sources.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBytes(&frame, length: MemoryLayout<FireParticleFrame>.stride, index: 2)
        encoder.dispatchThreads(.init(width: FireParticles.vertexCapacity, height: 1, depth: 1),
          threadsPerThreadgroup: .init(width: 64, height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        let vertices = output.contents().bindMemory(to: FireParticleVertex.self, capacity: reference.count)
        for i in reference.indices {
          let a = reference[i], b = vertices[i]
          precondition(b.px.isFinite && b.py.isFinite && b.pz.isFinite && b.u.isFinite && b.v.isFinite)
          if i >= count * FireParticles.particlesPerSource * 4 { precondition(b == FireParticleVertex()); continue }
          let delta = max(abs(a.px-b.px), abs(a.py-b.py), abs(a.pz-b.pz))
          maxPositionError = max(maxPositionError, delta)
          // Fast-math division can select the adjacent lifetime atlas frame.
          precondition(abs(a.u-b.u) <= 1.0/32 + 0.00001 && abs(a.v-b.v) < 0.00001)
          tested += 1
        }
      }
    }
    precondition(maxPositionError < 0.02, "Fire GPU/fallback motion diverged")
    print("PASS: \(tested) fire vertices on \(device.name); maximum position error \(maxPositionError) blocks; unused slots initialized.")
  }
}
