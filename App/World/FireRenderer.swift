import Metal
import QuartzCore
import RealityKit
import UIKit
import WorldCore

/// All village flames, smoke and embers share one mesh/material/compute dispatch.
/// No native emitter entities, per-torch material updates or simulation backlog.
@MainActor final class FireRenderer {
  private var sources = LocalLightSources()
  private var selected: [FireParticleSource] = []
  private(set) var audiblePositions: [SIMD3<Float>] = []
  private var lights: [Entity] = []
  private var mesh: LowLevelMesh?
  private var entity: ModelEntity?
  private var material: UnlitMaterial?
  private var gpu: FireCompute?
  private let preparation = FirePreparation()
  private let gate = RenderSubmissionGate(limit: 1)
  private var setupStarted = false
  private var meshFailed = false
  private var fallbackBusy = false
  private var revision: UInt64 = 0
  private var lastAnimation = -Double.infinity
  private var lastBounds: BoundingBox?
  private var lastIndexCount = 0
  private(set) var lightCount = 0
  var particlesEnabled = true {
    didSet {
      guard oldValue != particlesEnabled else { return }
      revision &+= 1
      if !particlesEnabled { entity?.isEnabled = false }
      lastAnimation = -.infinity
    }
  }
  var sourceCount: Int { sources.count }
  var rendersParticles: Bool { particlesEnabled && !RenderDiagnostics.current.disableFireParticles }
  var activeSourceCount: Int { audiblePositions.count }
  var particleCount: Int { entity?.isEnabled == true ? selected.count * FireParticles.particlesPerSource : 0 }
  var batchCount: Int { entity?.isEnabled == true ? 1 : 0 }
  var animationBackend: String {
    if !rendersParticles { return "Particles disabled for comparison" }
    if meshFailed { return "Fire mesh unavailable" }
    if material == nil { return setupStarted ? "Preparing shared fire" : "No nearby fire" }
    return gpu == nil ? "Shared fire · actor CPU" : "Shared fire · GPU"
  }
  func consumePerformanceTiming() -> RenderSubmissionGate.Snapshot {
    gate.consume(at: CACurrentMediaTime())
  }
  func install(_ tile: TerrainTile, positions: [SIMD3<Float>]) { sources.install(tile, positions: positions) }
  func remove(_ tile: TerrainTile) { sources.remove(tile) }
  func clear() {
    entity?.removeFromParent(); entity = nil; mesh = nil
    lights.forEach { $0.removeFromParent() }; lights.removeAll(); lightCount = 0
    sources.clear(); selected.removeAll(); audiblePositions.removeAll()
    lastAnimation = -.infinity; lastBounds = nil; lastIndexCount = 0
    if material != nil { meshFailed = false }
    revision &+= 1
    // GPU capacity and a running fallback remain occupied until completion,
    // including when changing planets. Prepared immutable assets can be reused.
  }

  func update(time: Double, eye: SIMD3<Float>, weather: WorldWeather, terrain: TerrainGenerator,
    root: Entity, paused: Bool, block: (BlockPosition) -> Block) {
    guard !paused else { return } // Freezes the mesh; no emitter pause messages.
    if let points = sources.sample(time: time, interval: 0.125, eye: eye,
      radius: FireParticles.radius, limit: FireParticles.sourceLimit, isValid: {
        block($0) == .torch && !block($0 + .init(0, 1, 0)).isLiquid
      }) {
      if points != audiblePositions { revision &+= 1 }
      audiblePositions = points
      // Farther torches draw before closer ones. Low-opacity smoke draws first
      // within each torch, followed by its bright flame and sparks.
      selected = points.reversed().map { point in
        let sheltered = block(BlockPosition(point) + .init(0, 3, 0)).isSolid
        let wind = sheltered ? SIMD3<Float>.zero
          : WorldWind.sample(seed: terrain.seed, time: time, position: point, weather: weather).velocity * 0.08
        return .init(position: point, breeze: wind)
      }
      updateLights(points: points, eye: eye, time: time, root: root)
    }
    guard rendersParticles, !selected.isEmpty else {
      if entity?.isEnabled == true { entity?.isEnabled = false }
      return
    }
    prepareIfNeeded()
    guard let material, !meshFailed, time - lastAnimation >= 1.0 / 30 || time < lastAnimation else { return }
    lastAnimation = time
    do {
      if mesh == nil { try makeMesh(material: material, root: root) }
      guard let mesh else { return }
      if let gpu { submit(gpu: gpu, mesh: mesh, time: time, eye: eye) }
      else if !fallbackBusy { submitFallback(mesh: mesh, time: time, eye: eye) }
    } catch {
      meshFailed = true
      print("WORLDCRAFT_FIRE mesh unavailable: \(error.localizedDescription)")
    }
  }

  private func prepareIfNeeded() {
    guard !setupStarted else { return }
    setupStarted = true
    // Compile off the main actor and load the atlas asynchronously; entering a
    // village must not synchronously compile another shader on the frame path.
    Task { [weak self, preparation] in
      async let compute = preparation.makeCompute()
      do {
        let texture = try await TextureResource(named: "FireParticles.png")
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        material.faceCulling = .none
        material.writesDepth = false; material.readsDepth = true
        let gpu = await compute
        guard let self else { return }
        self.material = material; self.gpu = gpu
        print("WORLDCRAFT_FIRE backend=\(gpu == nil ? "actor_cpu" : "batched_gpu") source_limit=20 particle_limit=800 native_emitters=0")
      } catch {
        self?.meshFailed = true
        print("WORLDCRAFT_FIRE atlas unavailable: \(error.localizedDescription)")
      }
    }
  }

  private func makeMesh(material: UnlitMaterial, root: Entity) throws {
    let mesh = try LowLevelMesh(descriptor: .init(vertexCapacity: FireParticles.vertexCapacity,
      vertexAttributes: [.init(semantic: .position, format: .float3, offset: 0),
        .init(semantic: .uv0, format: .float2, offset: 12)],
      vertexLayouts: [.init(bufferIndex: 0, bufferStride: MemoryLayout<FireParticleVertex>.stride)],
      indexCapacity: FireParticles.indices.count))
    mesh.withUnsafeMutableBytes(bufferIndex: 0) { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) }
    mesh.withUnsafeMutableIndices { target in FireParticles.indices.withUnsafeBytes { target.copyMemory(from: $0) } }
    updateParts(mesh)
    let entity = ModelEntity()
    entity.name = "Shared torch flames, smoke and embers"
    entity.model = .init(mesh: try MeshResource(from: mesh), materials: [material])
    entity.components.set(DynamicLightShadowComponent(castsShadow: false))
    entity.isEnabled = false
    root.addChild(entity)
    self.mesh = mesh; self.entity = entity
  }

  private func updateParts(_ mesh: LowLevelMesh) {
    var low = SIMD3<Float>(repeating: .infinity), high = -low
    for source in selected {
      let p = SIMD3<Float>(source.positionAndSeed.x, source.positionAndSeed.y, source.positionAndSeed.z)
      low = simd_min(low, p); high = simd_max(high, p)
    }
    let bounds = BoundingBox(min: low - [6, 1, 6], max: high + [6, 7, 6])
    let count = selected.count * FireParticles.particlesPerSource * 6
    guard lastBounds?.min != bounds.min || lastBounds?.max != bounds.max || count != lastIndexCount else { return }
    mesh.parts.replaceAll([.init(indexCount: count, materialIndex: 0, bounds: bounds)])
    lastBounds = bounds; lastIndexCount = count
  }

  private func submit(gpu: FireCompute, mesh: LowLevelMesh, time: Double, eye: SIMD3<Float>) {
    guard let token = gate.acquire(at: CACurrentMediaTime()) else { return }
    guard let command = gpu.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
      gate.complete(token, at: CACurrentMediaTime(), failed: true); return
    }
    encoder.setComputePipelineState(gpu.pipeline)
    selected.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
    encoder.setBuffer(mesh.replace(bufferIndex: 0, using: command), offset: 0, index: 1)
    var frame = FireParticleFrame(eye: eye, time: FireParticles.clock(time), sources: selected.count)
    encoder.setBytes(&frame, length: MemoryLayout<FireParticleFrame>.stride, index: 2)
    encoder.dispatchThreads(.init(width: FireParticles.vertexCapacity, height: 1, depth: 1),
      threadsPerThreadgroup: .init(width: min(128, gpu.pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
    encoder.endEncoding()
    let gate = gate
    command.addCompletedHandler { [weak self] result in
      let duration = result.gpuEndTime - result.gpuStartTime
      gate.complete(token, at: CACurrentMediaTime(), gpuSeconds: duration > 0 ? duration : nil, failed: result.status == .error)
      if result.status == .error {
        Task { @MainActor [weak self] in
          self?.gpu = nil
          print("WORLDCRAFT_FIRE compute failed; using actor CPU fallback")
        }
      }
    }
    updateParts(mesh)
    command.label = "Worldcraft shared torch particles"
    command.commit()
    if entity?.isEnabled == false { entity?.isEnabled = true }
  }

  private func submitFallback(mesh: LowLevelMesh, time: Double, eye: SIMD3<Float>) {
    fallbackBusy = true
    let sources = selected, revision = revision, clock = FireParticles.clock(time)
    Task { [weak self, preparation] in
      let vertices = await preparation.vertices(sources: sources, time: clock, eye: eye)
      guard let self else { return }
      self.fallbackBusy = false
      guard self.revision == revision, self.rendersParticles, self.gpu == nil else { return }
      mesh.withUnsafeMutableBytes(bufferIndex: 0) { target in vertices.withUnsafeBytes { target.copyMemory(from: $0) } }
      self.updateParts(mesh)
      if self.entity?.isEnabled == false { self.entity?.isEnabled = true }
    }
  }

  private func updateLights(points: [SIMD3<Float>], eye: SIMD3<Float>, time: Double, root: Entity) {
    guard !RenderDiagnostics.current.disableLocalLights else { return }
    let nearby = points.prefix(2).filter { simd_distance_squared($0, eye) < 24 * 24 }
    while lights.count < nearby.count {
      let light = Entity()
      light.components.set(PointLightComponent(color: .init(red: 1, green: 0.55, blue: 0.16, alpha: 1),
        intensity: 260, attenuationRadius: 7))
      light.name = "Torch light"; root.addChild(light); lights.append(light)
    }
    lightCount = nearby.count
    for (index, entity) in lights.enumerated() {
      let enabled = index < nearby.count
      if entity.isEnabled != enabled { entity.isEnabled = enabled }
      guard enabled else { continue }
      let point = nearby[index], position = point + SIMD3<Float>(0, 0.25, 0)
      if entity.position != position { entity.position = position }
      let phase = Float(time.truncatingRemainder(dividingBy: 1_000))
      let flicker = 0.86 + 0.09 * sin(phase * 13 + point.x) + 0.05 * sin(phase * 23 + point.z)
      if var light = entity.components[PointLightComponent.self] {
        light.intensity = 260 * flicker; entity.components.set(light)
      }
    }
  }
}

/// Metal command queues/pipelines are thread safe; these handles are immutable.
private final class FireCompute: @unchecked Sendable {
  let queue: any MTLCommandQueue
  let pipeline: any MTLComputePipelineState
  init(queue: any MTLCommandQueue, pipeline: any MTLComputePipelineState) {
    self.queue = queue; self.pipeline = pipeline
  }
}

/// Shader compilation and CPU fallback geometry never occupy the main actor.
private actor FirePreparation {
  func makeCompute() -> FireCompute? {
    do {
      guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
        let url = Bundle.main.url(forResource: "FireParticles", withExtension: "metal.txt") else { return nil }
      let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
      guard let function = library.makeFunction(name: "animateFireParticles") else { return nil }
      return try FireCompute(queue: queue, pipeline: device.makeComputePipelineState(function: function))
    } catch {
      print("WORLDCRAFT_FIRE compute unavailable: \(error.localizedDescription)")
      return nil
    }
  }
  func vertices(sources: [FireParticleSource], time: Float, eye: SIMD3<Float>) -> [FireParticleVertex] {
    FireParticles.vertices(sources: sources, time: time, eye: eye)
  }
}
