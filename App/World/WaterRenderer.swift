import Metal
import RealityKit
import UIKit
import WorldCore
import os

@MainActor
final class WaterRenderer {
  private struct Uniforms {
    var clockAndOrigin: SIMD4<Float>
    var counts: SIMD4<UInt32>
  }
  private struct Ripple {
    var wave: SIMD4<Float>
    var identity: SIMD4<UInt32>
  }
  private final class Surface {
    let geometry: WaterMeshBatch
    let mesh: LowLevelMesh?
    let source: (any MTLBuffer)?
    let entity: ModelEntity?
    var parts: [WaterMeshBatch.Part] = []
    var animationBounds: WaterAnimationSchedule.Bounds?
    var paletteRevision = -1
    init(geometry: WaterMeshBatch, mesh: LowLevelMesh?, source: (any MTLBuffer)?, entity: ModelEntity?) {
      self.geometry = geometry; self.mesh = mesh; self.source = source; self.entity = entity
    }
  }
  private struct Prepared {
    let input: WaterGeometryRequests.Preparation
    let geometry: WaterMeshBatch
    let vertices: [WaterMeshVertex]
  }
  private let preparation = WaterMeshPreparation()
  private var preparationTask: Task<Void, Never>?
  private var cpuAnimationTask: Task<Void, Never>?
  private var prepared: Prepared?
  private let retainsRejectedGeometry = ProcessInfo.processInfo.arguments.contains("--retain-rejected-water")
  private var lifetime = UUID()
  private weak var root: Entity?
  private var requests = WaterGeometryRequests(coalescesIdentical:
    !ProcessInfo.processInfo.arguments.contains("--rebuild-identical-water"),
    acceptsPartialCompletions: !ProcessInfo.processInfo.arguments.contains("--strict-water-batches"),
    prioritizesCoverage: !ProcessInfo.processInfo.arguments.contains("--strict-water-batches"))
  private var requestedVisible: Set<TerrainTile> = []
  private var coverage = WaterPresentationCoverage()
  private var publishedSources = WaterSurfaceSources()
  private var owners: [TerrainTile: UUID] = [:]
  private var surfaces: [UUID: Surface] = [:]
  private var bands: [TerrainTile: Int] = [:]
  private var visibilityDirty = false
  private var paletteRevision = 0
  private let gate = RenderSubmissionGate()
  private var materials: [any Material] = []
  private var hazeMaterials: [[any Material]] = []
  private var opaqueMaterials: [[any Material]] = []
  private var pendingPaletteColor: SIMD3<Float>?
  private var nextHazeMaterials: [[any Material]] = []
  private var nextOpaqueMaterials: [[any Material]] = []
  private var hazeColor = SIMD3<Float>(repeating: -1)
  private var lastHazeUpdate: Double = -.infinity
  private var lastAnimation: Double = -.infinity
  private var animationSchedule = WaterAnimationSchedule()
  private var frozenEnvironment: WorldEnvironment?
  private var lastPresentationEnvironment: WorldEnvironment?
  private var device: (any MTLDevice)?
  private var queue: (any MTLCommandQueue)?
  private var pipeline: (any MTLComputePipelineState)?
  private var shaderPrepared = false
  var measuresPerformance = false
  var animationBackend: String {
    if isLava { return "\(pipeline == nil ? "CPU" : "GPU") lava · \(lavaMaterial == nil ? "static maps" : "animated crust")" }
    let surface = waterMaterial != nil ? "depth / foam" : waterMaterialTask != nil ? "material loading" : "PBR fallback"
    return "\(pipeline == nil ? "CPU" : "GPU") water · \(surface)"
  }
  var count: Int { requests.count }
  var batchCount: Int { surfaces.values.filter { $0.entity != nil }.count }
  var activeBatchCount: Int { surfaces.values.filter { $0.entity?.isEnabled == true }.count }
  var queuedBatchCount: Int { requests.dirty.count }
  var geometryMetrics: WaterGeometryRequests.Metrics { requests.metrics }
  var sourceMetrics: WaterSurfaceSources.Metrics { publishedSources.metrics }
  // Capture the ownership used by native parts, which can intentionally lag
  // terrain/requested ownership while replacement water prepares.
  func visibleSurfaceSources() -> WaterSurfaceSources.Snapshot? {
    guard !visibilityDirty else { return nil }
    return publishedSources.snapshot(visible: coverage.visible)
  }
  func isCurrentSurfaceSource(_ lease: WaterSurfaceSources.Lease) -> Bool {
    !visibilityDirty && publishedSources.isCurrent(lease, visible: coverage.visible)
  }
  var animationMetrics: WaterAnimationSchedule.Metrics { animationSchedule.metrics }
  private(set) var deformationWork = PerformanceTrace.WaterWork(compactsRejectedGeometry:
    !ProcessInfo.processInfo.arguments.contains("--retain-rejected-water"))
  var metalAllocatedBytes: Int? { device?.currentAllocatedSize }
  var metalRecommendedBytes: UInt64? { device?.recommendedMaxWorkingSetSize }
  var triangleCount: Int { requests.triangleCount }
  private(set) var drawParts = 0

  private var isLava = false
  private var lavaMaterial: LavaMaterial?
  private var waterMaterial: WaterMaterial?
  private var waterMaterialTask: Task<Void, Never>?
  private var fallbackMaterials: [any Material] = []

  func configure(style: PlanetStyle = .verdant) throws {
    clear()
    if !shaderPrepared {
      guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
      else {
        throw NSError(
          domain: "Worldcraft.Water", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Metal is unavailable on this device."])
      }
      self.device = device
      self.queue = queue
      shaderPrepared = true
      do {
        guard let url = Bundle.main.url(forResource: "WaterAnimation", withExtension: "metal.txt")
        else {
          throw CocoaError(.fileNoSuchFile)
        }
        // Compile once per session. This also supports Xcode installations
        // without Apple's optional offline Metal Toolchain component.
        let library = try device.makeLibrary(
          source: String(contentsOf: url, encoding: .utf8), options: nil)
        guard let function = library.makeFunction(name: "animateWorldWater") else {
          throw CocoaError(.coderInvalidValue)
        }
        pipeline = try device.makeComputePipelineState(function: function)
      } catch {
        os_log(
          .error, log: PerformanceTrace.log, "Water compute unavailable; using CPU: %{public}@",
          error.localizedDescription)
      }
    }
    isLava = style == .solar
    if isLava {
      let lava: PhysicallyBasedMaterial
      do {
        guard let device, let queue else { throw CocoaError(.coderInvalidValue) }
        let animated = try LavaMaterial(device: device, queue: queue)
        lavaMaterial = animated
        lava = animated.material
      } catch {
        os_log(.error, log: PerformanceTrace.log, "Lava texture compute unavailable; using static PBR maps: %{public}@", error.localizedDescription)
        lava = try LavaMaterial.fallback()
      }
      materials = [lava, lava]
    } else {
      materials = [
        material(color: UIColor(red: 0.10, green: 0.70, blue: 0.69, alpha: 1), opacity: 0.67),
        material(color: UIColor(red: 0.035, green: 0.32, blue: 0.47, alpha: 1), opacity: 0.90),
      ]
      let normal = try TextureResource.load(
        named: "WaterNormals.png", options: .init(semantic: .normal))
      let sampler = MTLSamplerDescriptor()
      sampler.sAddressMode = .repeat
      sampler.tAddressMode = .repeat
      sampler.minFilter = .linear
      sampler.magFilter = .linear
      sampler.mipFilter = .linear
      materials = materials.map { original -> any Material in
        guard var water = original as? PhysicallyBasedMaterial else { return original }
        water.normal = .init(texture: .init(normal, sampler: .init(sampler)))
        return water
      }
      fallbackMaterials = materials
      if let waterMaterial {
        materials = [waterMaterial.surface, waterMaterial.surface]
      } else if !RenderDiagnostics.current.waterPBR {
        let epoch = lifetime
        waterMaterialTask = Task { [weak self] in
          do {
            let loaded = try await WaterMaterial.load()
            guard let self, self.lifetime == epoch, !Task.isCancelled else { return }
            self.waterMaterial = loaded
            self.materials = [loaded.surface, loaded.surface]
            self.hazeMaterials.removeAll(); self.opaqueMaterials.removeAll()
            self.pendingPaletteColor = nil; self.nextHazeMaterials = []; self.nextOpaqueMaterials = []
            self.lastHazeUpdate = -.infinity
            self.waterMaterialTask = nil
            os_log(.info, log: PerformanceTrace.log, "WORLDCRAFT_WATER material=depth_foam_fresnel")
          } catch {
            guard let self, self.lifetime == epoch, !Task.isCancelled else { return }
            self.waterMaterialTask = nil
            os_log(.error, log: PerformanceTrace.log, "Water graph unavailable; using PBR fallback: %{public}@", error.localizedDescription)
          }
        }
      }
    }
  }

  private func material(color: UIColor, opacity: Float) -> PhysicallyBasedMaterial {
    var water = PhysicallyBasedMaterial()
    water.baseColor = .init(tint: color)
    water.roughness = .init(floatLiteral: 0.095)
    water.metallic = .init(floatLiteral: 0)
    water.specular = .init(floatLiteral: 1)
    water.clearcoat = .init(floatLiteral: 1)
    water.clearcoatRoughness = .init(floatLiteral: 0.06)
    water.blending = .transparent(opacity: .init(floatLiteral: opacity))
    water.faceCulling = .none
    return water
  }

  func install(
    _ geometry: WaterGeometry, tile: TerrainTile, root: Entity,
    environment: WorldEnvironment
  ) throws {
    guard device != nil else { throw CocoaError(.coderInvalidValue) }
    self.root = root
    requests.install(geometry, tile: tile)
  }

  /// One actor job and one ready result, with at most one native mesh upload
  /// per frame. Revision checks discard superseded edits and planet changes.
  private func publishAndPrepare(environment: WorldEnvironment, eye: SIMD3<Float>) {
    if let ready = prepared {
      prepared = nil
      let tiles = requests.publishableTiles(in: ready.input)
      if !tiles.isEmpty {
        do {
          try publish(ready, tiles: tiles)
          requests.acknowledge(ready.input, published: tiles)
        } catch {
          os_log(.error, log: PerformanceTrace.log, "Water batch upload failed: %{public}@", error.localizedDescription)
        }
      } else {
        requests.acknowledge(ready.input, published: [])
      }
    }
    if visibilityDirty { refreshCoverage(eye: eye) }
    guard preparationTask == nil, prepared == nil,
      let key = requests.nextBatch(visible: requestedVisible, covered: coverage.visible, eye: eye),
      let input = requests.beginPreparation(for: key)
    else { return }
    let worker = preparation, epoch = lifetime
    preparationTask = Task { [weak self] in
      let (batch, vertices) = await worker.prepare(key: key, geometry: input.geometry, environment: environment)
      guard let self, self.lifetime == epoch, !Task.isCancelled else { return }
      self.preparationTask = nil
      self.prepared = .init(input: input, geometry: batch, vertices: vertices)
    }
  }

  private func publish(_ ready: Prepared, tiles: Set<TerrainTile>) throws {
    guard let device, let root else { throw CocoaError(.coderInvalidValue) }
    let selected = PerformanceTrace.measure(.waterCompaction) {
      retainsRejectedGeometry ? (batch: ready.geometry, vertices: ready.vertices)
        : ready.geometry.retaining(tiles, vertices: ready.vertices)
    }
    let batch = selected.batch
    let surface: Surface
    if batch.indices.isEmpty {
      // Dry replacements participate in coverage, so old ocean parents can retire.
      surface = .init(geometry: batch, mesh: nil, source: nil, entity: nil)
    } else {
      guard let source = batch.sources.withUnsafeBytes({ bytes in
        device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
      }) else { throw CocoaError(.coderInvalidValue) }
      source.label = "Water batch sources"
      let mesh = try LowLevelMesh(descriptor: .init(vertexCapacity: batch.sources.count,
        vertexAttributes: [
          .init(semantic: .position, format: .float3, offset: 0),
          .init(semantic: .normal, format: .half3, offset: 24),
          .init(semantic: .uv0, format: .float2, offset: 16),
          .init(semantic: .tangent, format: .half3, offset: 32),
          .init(semantic: .bitangent, format: .half3, offset: 40),
          .init(semantic: .uv1, format: .float2, offset: 48),
          .init(semantic: .color, format: .half4, offset: 56),
        ], vertexLayouts: [.init(bufferIndex: 0, bufferStride: MemoryLayout<WaterMeshVertex>.stride)],
        indexCapacity: batch.indices.count))
      mesh.withUnsafeMutableIndices { target in
        batch.indices.withUnsafeBytes { target.copyMemory(from: $0) }
      }
      mesh.withUnsafeMutableBytes(bufferIndex: 0) { target in
        selected.vertices.withUnsafeBytes { target.copyMemory(from: $0) }
      }
      let low = batch.sources.map(\.geometry.w).min() ?? WorldEnvironment.meanWaterLevel
      let high = batch.sources.map(\.geometry.w).max() ?? WorldEnvironment.meanWaterLevel
      mesh.parts.replaceAll([.init(indexCount: batch.indices.count, materialIndex: 0,
        bounds: .init(min: [0, low - 10, 0], max: [Float(batch.key.size * 16), high + 10, Float(batch.key.size * 16)]))])
      let entity = ModelEntity()
      entity.model = .init(mesh: try MeshResource(from: mesh), materials: materials)
      entity.position = batch.key.origin
      entity.name = isLava ? "Molten surface batch" : "Water surface batch"
      entity.isEnabled = false
      entity.components.set(DynamicLightShadowComponent(castsShadow: false))
      root.addChild(entity)
      surface = .init(geometry: batch, mesh: mesh, source: source, entity: entity)
    }
    let id = UUID()
    surfaces[id] = surface
    // Only independently validated current tiles acquire ownership. Compaction
    // removes rejected members from both CPU and GPU wave work without changing
    // the coverage switch or adding another asynchronous preparation/publication.
    for tile in tiles { owners[tile] = id }
    publishedSources.install(ready.input, published: tiles)
    deformationWork.publications += 1
    if tiles != ready.geometry.tiles { deformationWork.partialPublications += 1 }
    if batch.indices.isEmpty { deformationWork.dryPublications += 1 }
    else {
      deformationWork.uploadedVertices += batch.sources.count
      deformationWork.uploadedIndices += batch.indices.count
    }
    deformationWork.rejectedVerticesRemoved += ready.geometry.sources.count - batch.sources.count
    deformationWork.rejectedIndicesRemoved += ready.geometry.indices.count - batch.indices.count
    visibilityDirty = true
  }

  private func refreshCoverage(eye: SIMD3<Float>) {
    coverage.update(desired: requestedVisible, available: Set(owners.keys))
    for tile in Array(owners.keys) where requests[tile] == nil && !coverage.visible.contains(tile) {
      owners[tile] = nil; bands[tile] = nil
      publishedSources.remove(tile)
    }
    let retained = Set(owners.values)
    for id in Array(surfaces.keys) where !retained.contains(id) {
      surfaces.removeValue(forKey: id)?.entity?.removeFromParent()
    }
    for tile in owners.keys where bands[tile] == nil { bands[tile] = hazeBand(tile, eye: eye) }
    for (id, surface) in surfaces { updateParts(id, surface) }
    drawParts = surfaces.values.reduce(0) { $0 + $1.parts.count }
    visibilityDirty = false
  }

  private func hazeBand(_ tile: TerrainTile, eye: SIMD3<Float>) -> Int {
    min(20, Int(AtmosphericPerspective.strength(
      distance: simd_distance(tile.center + [0, eye.y, 0], eye), altitude: eye.y) * 20))
  }

  private func updateParts(_ id: UUID, _ surface: Surface) {
    guard let entity = surface.entity, let mesh = surface.mesh else { return }
    let visible = Set(surface.geometry.tiles.filter { coverage.visible.contains($0) && owners[$0] == id })
    // The explicit PBR comparison keeps graph-path draw grouping. Ordinary
    // material-load failure still retains the two-colour depth fallback.
    let parts = surface.geometry.parts(visible: visible, bands: bands,
      continuousDepth: !isLava && (waterMaterial != nil || RenderDiagnostics.current.waterPBR))
    let changed = surface.parts != parts
    guard changed || surface.paletteRevision != paletteRevision else { return }
    let slots = Array(Set(parts.map(\.materialIndex))).sorted()
    let local = Dictionary(uniqueKeysWithValues: slots.enumerated().map { ($1, $0) })
    if changed {
      mesh.parts.replaceAll(parts.map {
        .init(indexOffset: $0.indexStart * MemoryLayout<UInt32>.stride, indexCount: $0.indexCount,
          materialIndex: local[$0.materialIndex]!, bounds: .init(min: $0.minimum, max: $0.maximum))
      })
      surface.parts = parts
      surface.animationBounds = surface.geometry.animationBounds(for: parts)
      entity.isEnabled = !parts.isEmpty
    }
    // Only bind materials actually used by this regional batch.
    entity.model?.materials = slots.map { slot in
      let depth = slot % 2, band = (slot % 42) / 2
      return hazeMaterials.isEmpty ? materials[depth]
        : slot < 42 ? hazeMaterials[band][depth] : opaqueMaterials[band][depth]
    }
    surface.paletteRevision = paletteRevision
  }

  func update(_ environment: WorldEnvironment, eye: SIMD3<Float>, style: PlanetStyle,
    view: WaterAnimationSchedule.View? = nil) {
    let interval = PerformanceTrace.begin("Animate water")
    defer { PerformanceTrace.end("Animate water", interval) }
    let hazeUpdate = environment.elapsed - lastHazeUpdate >= 0.25
    let color = AtmosphericPerspective.color(environment: environment, style: style)
    var paletteChanged = false
    if hazeUpdate {
      lastHazeUpdate = environment.elapsed
      if pendingPaletteColor == nil && (hazeMaterials.isEmpty || simd_distance(color, hazeColor) > 0.025) {
        pendingPaletteColor = color; nextHazeMaterials = []; nextOpaqueMaterials = []
      }
    }
    // Rebuilding 42 graph materials in a single frame competes with input
    // and terrain publication. Build one pair per frame, retain the complete old palette,
    // and publish all bands together so neighboring water never has seams.
    if let targetColor = pendingPaletteColor {
      let band = nextHazeMaterials.count
      do {
        let transparent: [any Material]
        let opaque: [any Material]
        if !isLava, let waterMaterial {
          transparent = try waterMaterial.band(band, color: targetColor, opaque: false)
          opaque = try waterMaterial.band(band, color: targetColor, opaque: true)
        } else {
          transparent = materials.map { original -> any Material in
            guard var material = original as? PhysicallyBasedMaterial else { return original }
            let amount = Float(band) / 20, glow = targetColor * amount
            let emission = material.emissiveColor
            material.baseColor.tint = material.baseColor.tint.withAlphaComponent(1).scaled(by: 1 - amount)
            material.emissiveColor = .init(color: UIColor(
              red: CGFloat(glow.x), green: CGFloat(glow.y), blue: CGFloat(glow.z), alpha: 1))
            material.emissiveIntensity = 1
            if isLava { material.emissiveColor = emission; material.emissiveIntensity = 0.95 * (1 - amount) }
            return material
          }
          opaque = transparent.map { original -> any Material in
            guard var material = original as? PhysicallyBasedMaterial else { return original }
            material.blending = .opaque; return material
          }
        }
        nextHazeMaterials.append(transparent); nextOpaqueMaterials.append(opaque)
        if nextHazeMaterials.count == 21 {
          hazeMaterials = nextHazeMaterials; opaqueMaterials = nextOpaqueMaterials
          nextHazeMaterials = []; nextOpaqueMaterials = []; pendingPaletteColor = nil
          hazeColor = targetColor; paletteRevision += 1; paletteChanged = true
        }
      } catch {
        waterMaterial = nil; materials = fallbackMaterials
        pendingPaletteColor = nil; nextHazeMaterials = []; nextOpaqueMaterials = []
        lastHazeUpdate = -.infinity
        os_log(.error, log: PerformanceTrace.log, "Water palette unavailable; using PBR fallback: %{public}@", error.localizedDescription)
      }
    }
    // Freeze only presentation for diagnostic captures; newly streamed batches
    // use the same frozen snapshot so adjacent water does not get mixed clocks.
    if RenderDiagnostics.current.freezeWaterAnimation && frozenEnvironment == nil { frozenEnvironment = environment }
    PerformanceTrace.measure(.waterPublication) {
      publishAndPrepare(environment: frozenEnvironment ?? environment, eye: eye)
    }
    if hazeUpdate || paletteChanged {
      var bandChanged = false
      for tile in owners.keys {
        let band = hazeBand(tile, eye: eye)
        if bands[tile] != band { bands[tile] = band; bandChanged = true }
      }
      if paletteChanged || bandChanged { refreshCoverage(eye: eye) }
    }
    guard !RenderDiagnostics.current.freezeWaterAnimation else { return }
    let due = environment.elapsed - lastAnimation >= 1.0 / 30 - 0.000_001
    guard RenderDiagnostics.current.cullRearWaterAnimation || due else { return }
    // Re-entry between regular ticks uses the latest shared presentation
    // snapshot, preserving adjacent wave phases/UVs. It is at most one normal
    // tick old when submissions are healthy, never a replay of skipped frames.
    let sampleEnvironment = due ? environment : (lastPresentationEnvironment ?? environment)
    let plan = PerformanceTrace.measure(.waterVisibility) {
      animationSchedule.select(surfaces.compactMap { id, surface in
        guard surface.entity?.isEnabled == true, let bounds = surface.animationBounds else { return nil }
        return .init(id: id, bounds: bounds, vertices: surface.geometry.sources.count)
      }, view: view, now: CACurrentMediaTime(), enabled: RenderDiagnostics.current.cullRearWaterAnimation,
        sample: sampleEnvironment.waterAnimationSample)
    }
    // Re-entry uses the shared presentation clock and bypasses the cadence gate
    // for urgent batches only, never the bounded GPU/CPU gate. No catch-up loop.
    guard !plan.selected.isEmpty, !plan.urgent.isEmpty || due else { return }
    let work = due ? plan.selected : plan.urgent
    if lastAnimation.isFinite {
      lastAnimation += floor((environment.elapsed - lastAnimation) * 30 + 0.000_001) / 30
    } else {
      lastAnimation = environment.elapsed
    }
    guard let pipeline else {
      animateCPU(sampleEnvironment, plan: plan, work: work, regular: due)
      if let lavaMaterial, let token = gate.acquire(at: CACurrentMediaTime()) {
        if let command = queue?.makeCommandBuffer() {
          lavaMaterial.encode(command: command, elapsed: sampleEnvironment.elapsed); submit(command, token: token)
        } else { gate.complete(token, at: CACurrentMediaTime(), failed: true) }
      }
      return
    }
    guard let token = gate.acquire(at: CACurrentMediaTime()) else { return }
    guard let command = queue?.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
      gate.complete(token, at: CACurrentMediaTime(), failed: true); return
    }

    command.label = "Worldcraft water animation"
    encoder.setComputePipelineState(pipeline)
    var ripples = sampleEnvironment.disturbances.map { ripple in
      Ripple(
        wave: [ripple.x, ripple.z, Float(sampleEnvironment.elapsed - ripple.onset), ripple.energy],
        identity: [
          UInt32(truncatingIfNeeded: ripple.bodyID),
          UInt32(truncatingIfNeeded: ripple.bodyID >> 32), 0, 0,
        ])
    }
    if ripples.isEmpty { ripples.append(.init(wave: .zero, identity: .zero)) }
    ripples.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 3) }
    let time = Float(sampleEnvironment.elapsed.truncatingRemainder(dividingBy: 10_000))
    let tide = sampleEnvironment.tide
    var replacementSeconds = 0.0
    var encoded = Set<UUID>()
    var encodedVertices = 0
    for (id, surface) in surfaces where work.contains(id) {
      guard let mesh = surface.mesh, let source = surface.source else { continue }
      let geometry = surface.geometry
      var uniforms = Uniforms(
        clockAndOrigin: [time, tide, geometry.key.origin.x, geometry.key.origin.z],
        counts: [UInt32(geometry.sources.count), UInt32(sampleEnvironment.disturbances.count), 0, 0])
      encoder.setBuffer(source, offset: 0, index: 0)
      let start = measuresPerformance ? CACurrentMediaTime() : 0
      encoder.setBuffer(mesh.replace(bufferIndex: 0, using: command), offset: 0, index: 1)
      if measuresPerformance { replacementSeconds += CACurrentMediaTime() - start }
      encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
      encoder.dispatchThreads(.init(width: geometry.sources.count, height: 1, depth: 1),
        threadsPerThreadgroup: .init(width: min(128, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
      encoded.insert(id)
      encodedVertices += geometry.sources.count
    }
    PerformanceTrace.record(.waterBufferReplacement, seconds: replacementSeconds)
    encoder.endEncoding()
    lavaMaterial?.encode(command: command, elapsed: sampleEnvironment.elapsed)
    submit(command, token: token)
    deformationWork.gpuCommands += 1
    deformationWork.gpuBufferUpdates += encoded.count; deformationWork.gpuVertices += encodedVertices
    animationSchedule.didSubmit(plan, ids: encoded)
    if due && !encoded.isEmpty { lastPresentationEnvironment = sampleEnvironment }
  }

  private func submit(_ command: any MTLCommandBuffer, token: UInt64) {
    let gate = gate, epoch = lifetime
    command.addCompletedHandler { [weak self] command in
      let start = command.gpuStartTime, end = command.gpuEndTime
      let duration = start > 0 && end > start && start.isFinite && end.isFinite ? end - start : nil
      gate.complete(token, at: CACurrentMediaTime(), gpuSeconds: duration, failed: command.status == .error)
      if let message = command.error?.localizedDescription {
        os_log(.error, log: PerformanceTrace.log, "Water compute failed; using CPU: %{public}@", message)
        Task { @MainActor [weak self] in
          guard let self, self.lifetime == epoch else { return }
          self.pipeline = nil
          self.lastPresentationEnvironment = nil
          if self.isLava {
            self.lavaMaterial = nil
            if let fallback = try? LavaMaterial.fallback() {
              self.materials = [fallback, fallback]
              self.hazeMaterials.removeAll(); self.opaqueMaterials.removeAll()
              self.lastHazeUpdate = -.infinity
            }
          }
        }
      }
    }
    PerformanceTrace.measure(.waterCommit) { command.commit() }
  }

  private func animateCPU(_ environment: WorldEnvironment, plan: WaterAnimationSchedule.Plan,
    work: Set<UUID>, regular: Bool) {
    guard cpuAnimationTask == nil else { return }
    let batches = surfaces.filter { work.contains($0.key) }.mapValues(\.geometry)
    let worker = preparation, epoch = lifetime
    cpuAnimationTask = Task { [weak self] in
      let vertices = await worker.animate(batches, environment: environment)
      guard let self, self.lifetime == epoch, !Task.isCancelled else { return }
      self.cpuAnimationTask = nil
      PerformanceTrace.measure(.waterCPUFallbackPublication) {
        var installed = Set<UUID>()
        var installedVertices = 0
        for (id, vertices) in vertices {
          guard self.animationSchedule.allowsPublication(plan, id: id),
            self.surfaces[id]?.entity?.isEnabled == true, let mesh = self.surfaces[id]?.mesh else { continue }
          mesh.withUnsafeMutableBytes(bufferIndex: 0) { target in
            vertices.withUnsafeBytes { target.copyMemory(from: $0) }
          }
          installed.insert(id)
          installedVertices += vertices.count
        }
        self.animationSchedule.didSubmit(plan, ids: installed)
        if !installed.isEmpty {
          self.deformationWork.cpuPublications += 1
          self.deformationWork.cpuBufferUpdates += installed.count
          self.deformationWork.cpuVertices += installedVertices
        }
        if regular && !installed.isEmpty { self.lastPresentationEnvironment = environment }
      }
    }
  }

  func setVisible(_ tile: TerrainTile, _ visible: Bool) {
    if visible {
      if requestedVisible.insert(tile).inserted { visibilityDirty = true }
    } else if requestedVisible.remove(tile) != nil { visibilityDirty = true }
  }
  func remove(_ tile: TerrainTile) {
    requests.remove(tile)
    requestedVisible.remove(tile)
    visibilityDirty = true
  }
  func resetPerformanceTiming() { _ = gate.consume(at: CACurrentMediaTime()) }
  func consumePerformanceTiming() -> RenderSubmissionGate.Snapshot { gate.consume(at: CACurrentMediaTime()) }
  func clear() {
    lifetime = UUID()
    animationSchedule.reset(); frozenEnvironment = nil; lastPresentationEnvironment = nil
    deformationWork = .init(compactsRejectedGeometry: !retainsRejectedGeometry)
    waterMaterialTask?.cancel(); waterMaterialTask = nil
    preparationTask?.cancel(); preparationTask = nil
    cpuAnimationTask?.cancel(); cpuAnimationTask = nil
    prepared = nil
    // Old-world commands may still be executing. Keep the same limiter across
    // resets so changing planets cannot bypass GPU backpressure.
    resetPerformanceTiming()
    lavaMaterial = nil
    surfaces.values.forEach { $0.entity?.removeFromParent() }
    surfaces.removeAll(); owners.removeAll(); bands.removeAll()
    publishedSources.reset()
    requests = .init(coalescesIdentical: requests.coalescesIdentical,
      acceptsPartialCompletions: requests.acceptsPartialCompletions,
      prioritizesCoverage: requests.prioritizesCoverage)
    requestedVisible.removeAll()
    coverage = .init(); visibilityDirty = false; root = nil
    drawParts = 0; paletteRevision = 0
    hazeMaterials.removeAll(); opaqueMaterials.removeAll()
    hazeColor = .init(repeating: -1)
    pendingPaletteColor = nil; nextHazeMaterials = []; nextOpaqueMaterials = []
    lastHazeUpdate = -.infinity; lastAnimation = -.infinity
  }

}

extension UIColor {
  fileprivate func scaled(by value: Float) -> UIColor {
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    getRed(&r, green: &g, blue: &b, alpha: &a)
    return UIColor(
      red: r * CGFloat(value), green: g * CGFloat(value), blue: b * CGFloat(value), alpha: a)
  }
}
