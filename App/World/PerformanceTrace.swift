import Foundation
import QuartzCore
import Darwin
import WorldCore
import os

/// Device traces expose CPU update, streaming preparation and mesh uploads in
/// Instruments' Points of Interest alongside RealityKit and Metal frame timing.
enum PerformanceTrace {
  static let log = OSLog(subsystem: "com.worldcraft.vision", category: .pointsOfInterest)

  struct Sample: Sendable, Encodable {
    let version = 35
    let run: String
    let sequence: Int
    let windowSeconds: Double
    let build: String
    let os: String
    let thermalState: String
    let gameUpdate: FrameTiming.Snapshot
    let stateAtEnd: State
    let sceneAtEnd: Scene
    let waterComputeGPU: DurationTiming.Snapshot
    let vegetationComputeGPU: DurationTiming.Snapshot
    let simulation: LifeCoordinator.Metrics
    let hazeCPU: DurationTiming.Snapshot
    let terrainUploadCPU: DurationTiming.Snapshot
    let terrainStreaming: TerrainStreamingExchange.Metrics
    let terrainDemandCache: TerrainDemandCache.Metrics
    let terrainFrontierPlanner: ProgressiveTerrainPlanner.Metrics
    let terrainPublicationBudget: StreamingBudget.Metrics
    let incrementalTerrainCoverage: Bool
    let terrainCoverageTracker: TerrainCoverageTracker.Metrics
    let asynchronousTerrainPublication: Bool
    let terrainNativePublication: TerrainPublicationMetrics
    let terrainNativeAdmission: TerrainPublicationFeederMetrics
    let terrainTravelPrefetch: TerrainTravelPrefetch.Metrics
    let terrainDryRegions: DryRegions
    let terrainCoverage: TerrainCoverageMetrics
    let regionalCaches: [String: RegionalCacheMetrics]
    let terrainTreePlans: TerrainTreePlanMetrics
    let terrainPayloadCache: TerrainPayloadCacheMetrics
    let terrainRefinement: TerrainRefinementMetrics
    let terrainBaseCache: TerrainBaseCacheMetrics
    let indexedTerrainWindPartition: Bool
    let terrainDiskCache: TerrainDiskCacheMetrics
    let terrainCoverageDetails: TerrainCoverageDiagnosticsMetrics
    let terrainResources: TerrainResources
    let phasesCPU: [String: DurationTiming.Snapshot]
    let waterQueue: RenderSubmissionGate.Snapshot
    let waterGeometry: WaterGeometryRequests.Metrics
    let waterSurfaceSources: WaterSurfaceSources.Metrics
    let waterAnimation: WaterAnimationSchedule.Metrics
    let waterDeformationWork: WaterWork
    let renderDiagnostics: RenderDiagnostics
    let fireQueue: RenderSubmissionGate.Snapshot
    let memory: Memory
    let renderTiming = "Update Hz is not presented FPS; water, vegetation and fire compute are not full-frame GPU time."
  }
  struct DryRegions: Sendable, Encodable {
    let enabled: Bool
    let transaction: TerrainRegionTransactionMetrics
    let active, published, restored, logicalBytes: Int
    let activeTriangles, retainedFallbackTriangles: Int
  }
  struct State: Sendable, Encodable {
    let mode: String
    let paused: Bool
    let loading: Bool
    let planet: String
    let seed: String
    let drawDistanceChunks: Int
    let drawDistanceMetres: Int
    let detailDistanceChunks: Int
    let detailDistanceMetres: Int
    let positionBlocks: [Float]?
  }
  struct Scene: Sendable, Encodable {
    let terrainMesher: String
    let terrainCaveSampling: String
    let terrainTiles: Int
    let terrainTriangles: Int
    let terrainMaterialParts: Int
    let waterTiles: Int
    let waterTriangles: Int
    let waterMaterialParts: Int
    let streamingJobs: Int
    let queuedTerrainTiles: Int
    let latestUploadMilliseconds: Double
    let animals: Int
    let dinosaurs: Int
    let residents: Int
    let waterBackend: String
    let waterBatches: Int
    let activeWaterBatches: Int
    let queuedWaterBatches: Int
    let terrainWorkers: Int
    let readyTerrainTiles: Int
    let windVertices: Int
    let windTiles: Int
    let fireSources: Int
    let activeFireSources: Int
    let fireParticles: Int
    let fireBatches: Int
    let fireLights: Int
    let fireBackend: String
    let fireParticlesEnabled: Bool
    let localLampLights: Int
    let headlightBeams: Int
    let preparedCollisionChunks: Int
    let collisionCachedBlocks: Int
    let collisionProceduralSamples: Int
    let collisionCacheHits: Int
  }

  struct Memory: Sendable, Encodable {
    let physicalFootprintBytes: UInt64?
    let metalAllocatedBytes: Int?
    let metalRecommendedWorkingSetBytes: UInt64?
  }
  /// Cumulative per planet: encoded GPU work, not completed/displayed frames;
  /// CPU counts include only arrays actually installed by the fallback.
  struct WaterWork: Sendable, Encodable {
    var compactsRejectedGeometry = true
    var gpuCommands = 0, gpuBufferUpdates = 0, gpuVertices = 0
    var cpuPublications = 0, cpuBufferUpdates = 0, cpuVertices = 0
    // Successful initial publications and logical uploads, including dry
    // ownership updates. These do not measure framework copies or GPU residency.
    var publications = 0, partialPublications = 0, dryPublications = 0
    var uploadedVertices = 0, uploadedIndices = 0
    var rejectedVerticesRemoved = 0, rejectedIndicesRemoved = 0
  }
  /// Logical vertex/index and collision payload sizes, excluding RealityKit's
  /// internal copies and allocation overhead. Use device tools for GPU residency.
  struct TerrainResources: Sendable, Encodable {
    let residentMeshBytes: Int
    let residentMeshCapacityBytes: Int
    let residentVoxelBytes: Int
    let sceneRemovalCPU: DurationTiming.Snapshot
    let rendering: TerrainRenderResources.Metrics
    let seatInstancing: StadiumSeatRenderer.Metrics
    let surfaceSources: TerrainSurfaceSources.Metrics
    let replacementVisibility: TerrainReplacementVisibility
  }
  /// Sampled CPU ownership of existing terrain meshes, not displayed pixels or
  /// framework GPU allocation. Hidden children and retained parents are already
  /// included in residentMeshBytes; these are subsets, not additional charges.
  struct TerrainReplacementVisibility: Sendable, Encodable {
    let hiddenTiles, hiddenMeshBytes: Int
    let retainedParents, retainedParentMeshBytes: Int
  }

  enum Phase: String, CaseIterable {
    case input, streaming, tracking, locomotion, worldTransform, sky, terrainHaze, water
    case precipitation, interactions, audio, hud, fire, lamps
    case lifeSnapshot = "life_snapshot", actorPresentation = "actor_presentation"
    case waterPublication = "water_publication", waterBufferReplacement = "water_buffer_replacement"
    case waterVisibility = "water_visibility"
    case waterCompaction = "water_compaction"
    case waterCommit = "water_commit", waterCPUFallbackPublication = "water_cpu_fallback_publication"
    case vegetationWind = "vegetation_wind"
    case colossalDestruction = "colossal_destruction"
    case terrainDemand = "terrain_demand"
    case terrainFrontier = "terrain_frontier"
    case terrainCoverage = "terrain_coverage"
    case terrainPrefetch = "terrain_prefetch"
  }
  @MainActor static var measuresPhases = false
  @MainActor private static var phases: [Phase: DurationTiming] = [:]

  /// Durations are wall time spent inside each synchronous stage, so driver
  /// waits are included. Water buffer replacement aggregates an entire pass.
  @MainActor static func measure<T>(_ phase: Phase, _ body: () -> T) -> T {
    guard measuresPhases else { return body() }
    let start = CACurrentMediaTime()
    defer { record(phase, since: start) }
    return body()
  }
  @MainActor static func record(_ phase: Phase, since start: Double) {
    record(phase, seconds: CACurrentMediaTime() - start)
  }
  @MainActor static func record(_ phase: Phase, seconds: Double) {
    guard measuresPhases else { return }
    phases[phase, default: .init()].record(seconds: seconds)
  }
  @MainActor static func consumePhases() -> [String: DurationTiming.Snapshot] {
    defer { phases.removeAll(keepingCapacity: true) }
    return Dictionary(uniqueKeysWithValues: phases.map { ($0.key.rawValue, $0.value.snapshot) })
  }

  static var physicalFootprint: UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : nil
  }

  static var build: String {
    #if DEBUG
      "Debug"
    #else
      "Release"
    #endif
  }
  static var thermalState: String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
  }

  /// One copyable JSON line every five seconds, only when explicitly enabled.
  /// Standard output keeps the full JSON visible in Xcode's Release console.
  static func emit(_ sample: Sample) {
    Task(priority: .utility) { await PerformanceLogWriter.shared.emit(sample) }
  }

  static func begin(_ name: StaticString) -> OSSignpostID {
    let id = OSSignpostID(log: log)
    os_signpost(.begin, log: log, name: name, signpostID: id)
    return id
  }
  static func end(_ name: StaticString, _ id: OSSignpostID) {
    os_signpost(.end, log: log, name: name, signpostID: id)
  }
}

/// Encoding and console I/O do not belong in a headset frame callback.
private actor PerformanceLogWriter {
  static let shared = PerformanceLogWriter()
  func emit(_ sample: PerformanceTrace.Sample) {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(sample), let json = String(data: data, encoding: .utf8) else { return }
    print("WORLDCRAFT_PERF \(json)")
  }
}
