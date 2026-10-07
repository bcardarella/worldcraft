import Metal
import QuartzCore
import RealityKit
import WorldCore

/// Bounded GPU deformation of the existing terrain meshes. No per-tree
/// entities, CPU vertex uploads, render-thread waits or AI dependencies.
@MainActor final class WindRenderer {
  private struct Entry {
    let mesh: LowLevelMesh
    let count: Int
    let admissionVertexCount: Int
    weak var entity: Entity?
  }
  private var entries: [TerrainTile: Entry] = [:]
  private var originals: [TerrainTile: any MTLBuffer] = [:]
  private var device: (any MTLDevice)?
  private var queue: (any MTLCommandQueue)?
  private var pipeline: (any MTLComputePipelineState)?
  private let gate = RenderSubmissionGate(limit: 1)
  private(set) var animatedVertexCount = 0
  private(set) var animatedTileCount = 0
  private var lastTime: Double = -.infinity
  func consumeGPUTiming() -> DurationTiming.Snapshot {
    gate.consume(at: CACurrentMediaTime()).gpu
  }
  func register(_ tile: TerrainTile, mesh: LowLevelMesh, count: Int, admissionVertexCount: Int, entity: Entity) {
    originals[tile] = nil
    entries[tile] = .init(mesh: mesh, count: count, admissionVertexCount: admissionVertexCount, entity: entity)
  }
  func remove(_ tile: TerrainTile) {
    entries[tile] = nil
    originals[tile] = nil
  }
  func clear() {
    entries.removeAll()
    originals.removeAll()
    // Keep an outstanding command in the budget across planet changes.
    // Its completion releases this slot directly, without a MainActor hop.
    lastTime = -.infinity
    animatedVertexCount = 0; animatedTileCount = 0
  }
  func configure() {
    guard pipeline == nil, let device = MTLCreateSystemDefaultDevice() else { return }
    do {
      let library = try device.makeLibrary(source: Self.shader, options: nil)
      guard let function = library.makeFunction(name: "swayVegetation") else { return }
      pipeline = try device.makeComputePipelineState(function: function)
      self.device = device
      queue = device.makeCommandQueue()
    } catch { print("WORLDCRAFT_WIND GPU vegetation unavailable: \(error.localizedDescription)") }
  }
  func update(time: Double, eye: SIMD3<Float>, seed: UInt64, weather: WorldWeather) {
    // Launch-only comparison: preserve meshes, appearance, physics and weather;
    // leave their original rest poses rather than dispatching deformation.
    guard !RenderDiagnostics.current.freezeWindAnimation else {
      animatedVertexCount = 0; animatedTileCount = 0; return
    }
    guard time - lastTime >= 1.0 / 30, let device, let pipeline
    else { return }
    lastTime = time
    let candidates = entries.keys.filter {
      entries[$0]?.entity?.isEnabled == true
        && simd_distance_squared($0.origin + [8, 0, 8], [eye.x, 0, eye.z]) < 96 * 96
    }
    .sorted { simd_distance_squared($0.origin, eye) < simd_distance_squared($1.origin, eye) }
    var chosen = Set<TerrainTile>()
    var count = 0
    var admissionCount = 0
    for tile in candidates.prefix(48) {
      let entry = entries[tile]!
      // Preserve the previous animated coverage. Spend the saving on rendering
      // headroom, rather than silently adding more deformation work to this pass.
      if admissionCount + entry.admissionVertexCount <= 200_000 {
        chosen.insert(tile)
        admissionCount += entry.admissionVertexCount
        count += entry.count
      }
    }
    animatedVertexCount = count; animatedTileCount = chosen.count
    guard !chosen.isEmpty || !originals.isEmpty,
      let token = gate.acquire(at: CACurrentMediaTime()) else { return }
    guard let command = queue?.makeCommandBuffer() else {
      gate.complete(token, at: CACurrentMediaTime(), failed: true); return
    }
    // Restore outgoing tiles and snapshot incoming rest poses entirely on GPU.
    if let blit = command.makeBlitCommandEncoder() {
      for tile in Array(originals.keys) where !chosen.contains(tile) {
        if let entry = entries[tile], let source = originals[tile] {
          blit.copy(
            from: source, sourceOffset: 0, to: entry.mesh.replace(bufferIndex: 0, using: command),
            destinationOffset: 0, size: entry.count * 40)
        }
        originals[tile] = nil
      }
      var admitted = 0
      for tile in chosen where originals[tile] == nil {
        guard admitted < 2, let entry = entries[tile],
          let source = device.makeBuffer(length: entry.count * 40, options: .storageModePrivate)
        else { continue }
        blit.copy(
          from: entry.mesh.read(bufferIndex: 0, using: command), sourceOffset: 0, to: source,
          destinationOffset: 0, size: entry.count * 40)
        originals[tile] = source
        admitted += 1
      }
      blit.endEncoding()
    }
    if let encoder = command.makeComputeCommandEncoder() {
      encoder.setComputePipelineState(pipeline)
      for tile in chosen {
        guard let entry = entries[tile], let source = originals[tile] else { continue }
        var frame = SIMD4<Float>(
          Float(time.truncatingRemainder(dividingBy: 100_000)), Float(seed % 1024) * 0.006135923,
          weather.cloudCover, weather.storminess)
        var origin = SIMD4<Float>(tile.origin.x, 0, tile.origin.z, Float(entry.count))
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(entry.mesh.replace(bufferIndex: 0, using: command), offset: 0, index: 1)
        encoder.setBytes(&frame, length: 16, index: 2)
        encoder.setBytes(&origin, length: 16, index: 3)
        encoder.dispatchThreads(
          .init(width: entry.count, height: 1, depth: 1),
          threadsPerThreadgroup: .init(
            width: min(128, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
      }
      encoder.endEncoding()
    }
    let gate = gate
    command.addCompletedHandler { result in
      let seconds = result.gpuEndTime - result.gpuStartTime
      gate.complete(token, at: CACurrentMediaTime(), gpuSeconds: seconds > 0 ? seconds : nil,
        failed: result.status == .error)
    }
    command.label = "Worldcraft bounded vegetation wind"
    command.commit()
  }
  private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { packed_float3 p; half2 uv; half4 n; half4 tangent; half4 bitangent; };
    static_assert(sizeof(V)==40,"Terrain wind stride");
    kernel void swayVegetation(device const V *base [[buffer(0)]],device V *out [[buffer(1)]],
      constant float4 &f [[buffer(2)]],constant float4 &o [[buffer(3)]],uint i [[thread_position_in_grid]]) {
      if(i>=uint(o.w)) return;
      V v=base[i];float weight=float(v.n.w);
      if(weight>0) {
        float3 p=float3(v.p)+o.xyz;float t=f.x,phase=f.y,storm=f.w;
        float angle=phase+.35f*sin(t*.002f+phase)+storm*.6f*sin(t*.009f+phase);
        float2 d=float2(cos(angle),sin(angle));
        float along=dot(p.xz,d)*.5f,across=dot(p.xz,float2(-d.y,d.x))*.5f;
        float wave=sin(along*.026f-t*(.22f+storm*.28f)+phase)*cos(across*.019f+t*.04f);
        float gust=pow(max(0.f,wave),2.f)*(.4f+storm*.6f);
        float speed=1.4f+f.z*2.f+storm*5.f+gust*(2.f+storm*9.f);
        float shift=(gust-.15f)*storm*.65f+sin(across*.013f-t*.07f)*.12f;
        float bend=min(.4f,speed*.022f)*weight*(.55f+.45f*sin(t*1.8f+along*.08f));
        float3 q=float3(v.p);q.x+=cos(angle+shift)*bend;q.z+=sin(angle+shift)*bend;
        v.p=packed_float3(q);
      }
      out[i]=v;
    }
    """
}
