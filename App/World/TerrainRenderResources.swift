import Foundation
import QuartzCore
import RealityKit
import WorldCore

@MainActor final class TerrainMeshAllocation {
  let mesh: LowLevelMesh
  let resource: MeshResource
  let capacity: TerrainMeshCapacity
  init(source: PackedTerrainMesh, capacity: TerrainMeshCapacity) throws {
    mesh = try TerrainMeshResource.makeLowLevel(source, capacity: capacity)
    resource = try MeshResource(from: mesh)
    self.capacity = capacity
  }
  init(mesh: LowLevelMesh, resource: MeshResource, capacity: TerrainMeshCapacity) {
    self.mesh = mesh; self.resource = resource; self.capacity = capacity
  }
}

@MainActor struct TerrainPreparedMeshes {
  struct Animation {
    let mesh: LowLevelMesh
    let resource: MeshResource
    let bytes: Int
  }
  let allocation: TerrainMeshAllocation?
  let animation: Animation?
}

/// Owns detached static resources and retired scene objects. CPU preparation
/// remains on workers. RealityKit resource/scene access stays on MainActor.
@MainActor final class TerrainRenderResources {
  private struct Retired {
    let entity: Entity?
    // Keep the old parent alive during planet switches. Otherwise releasing the
    // root could tear down its entire child collection before we pace the work.
    let parent: Entity?
    let allocation: TerrainMeshAllocation?
    let orphanMesh: LowLevelMesh?
    let orphanResource: MeshResource?
  }
  struct Metrics: Sendable, Encodable {
    let reuseEnabled: Bool
    let pool: TerrainMeshReuseMetrics
    let retirement: TerrainRetirementMetrics
    let allocations, reused, admissionDeferrals: Int
    let allocationCPU, rewriteCPU, retirementCPU: DurationTiming.Snapshot
    let bufferCreationCPU, bufferStageCPU, resourceLatency: DurationTiming.Snapshot
  }
  private var pool = TerrainMeshReuseCache<TerrainMeshAllocation>()
  private var retiring = TerrainRetirementQueue<Retired>()
  private var maintenance: Task<Void, Never>?
  private var allocations = 0, reused = 0, admissionDeferrals = 0
  private var allocationTiming = DurationTiming(), rewriteTiming = DurationTiming(), retirementTiming = DurationTiming()
  private var bufferTiming = DurationTiming(), resourceTiming = DurationTiming()
  private var bufferStageTiming = DurationTiming()
  private var bufferBudget = TerrainBufferBudget()
  let reuseEnabled: Bool
  var onAdmissionAvailable: (@MainActor () -> Void)?
  init(reuseEnabled: Bool = !ProcessInfo.processInfo.arguments.contains("--fresh-terrain-resources")) {
    self.reuseEnabled = reuseEnabled
  }
  var permitsPublication: Bool {
    if retiring.appliesBackpressure { admissionDeferrals += 1; return false }
    return true
  }
  func acquire(_ source: PackedTerrainMesh) throws -> TerrainMeshAllocation {
    let demand = TerrainMeshCapacity(vertices: source.vertices.count, indices: source.indices.count, rounded: reuseEnabled)
    if let allocation = takeReusable(source, demand: demand) { return allocation }
    let began = CACurrentMediaTime()
    defer { allocationTiming.record(seconds: CACurrentMediaTime() - began) }
    let allocation = try TerrainMeshAllocation(source: source, capacity: demand)
    allocations += 1
    return allocation
  }
  private func takeReusable(_ source: PackedTerrainMesh, demand: TerrainMeshCapacity) -> TerrainMeshAllocation? {
    if reuseEnabled, let allocation = pool.take(fitting: demand) {
      let began = CACurrentMediaTime()
      TerrainMeshResource.replace(source, in: allocation.mesh)
      rewriteTiming.record(seconds: CACurrentMediaTime() - began); reused += 1
      return allocation
    }
    return nil
  }
  private func makeBuffer(_ source: PackedTerrainMesh, capacity: TerrainMeshCapacity) throws -> LowLevelMesh {
    let began = CACurrentMediaTime()
    defer { bufferTiming.record(seconds: CACurrentMediaTime() - began) }
    return try TerrainMeshResource.makeLowLevel(source, capacity: capacity)
  }
  private func pacedBuffer<Value>(_ operation: @MainActor () throws -> Value) async throws -> Value {
    while true {
      try Task.checkCancellation()
      let delay = bufferBudget.delay(at: CACurrentMediaTime())
      if delay > 0 { try await Task.sleep(for: .seconds(delay)); continue }
      let began = CACurrentMediaTime()
      defer {
        let cost = CACurrentMediaTime() - began
        bufferBudget.record(seconds: cost); bufferStageTiming.record(seconds: cost)
      }
      // No suspension between admission, allocation/rewrite and accounting.
      return try operation()
    }
  }
  private enum StaticBuffer {
    case reused(TerrainMeshAllocation)
    case fresh(LowLevelMesh, TerrainMeshCapacity)
  }
  private func makeResource(_ mesh: LowLevelMesh, bytes: Int) async throws -> MeshResource {
    let began = CACurrentMediaTime()
    // This duration includes suspension and framework scheduling, not CPU time.
    defer { resourceTiming.record(seconds: CACurrentMediaTime() - began) }
    do { return try await MeshResource(from: mesh) }
    catch {
      retiring.append(.init(entity: nil, parent: nil, allocation: nil,
        orphanMesh: mesh, orphanResource: nil), bytes: bytes, at: CACurrentMediaTime())
      scheduleMaintenance()
      throw error
    }
  }
  func prepare(_ input: PreparedTerrainTile) async throws -> TerrainPreparedMeshes {
    var allocation: TerrainMeshAllocation?
    var animation: TerrainPreparedMeshes.Animation?
    do {
      try Task.checkCancellation()
      if !input.mesh.vertices.isEmpty {
        let buffer: StaticBuffer = try await pacedBuffer {
          let demand = TerrainMeshCapacity(vertices: input.mesh.vertices.count,
            indices: input.mesh.indices.count, rounded: reuseEnabled)
          if let reused = takeReusable(input.mesh, demand: demand) { return .reused(reused) }
          return .fresh(try makeBuffer(input.mesh, capacity: demand), demand)
        }
        switch buffer {
        case let .reused(reused): allocation = reused
        case let .fresh(mesh, demand):
          let resource = try await makeResource(mesh, bytes: demand.bytes)
          allocation = .init(mesh: mesh, resource: resource, capacity: demand)
          allocations += 1
        }
      }
      try Task.checkCancellation()
      if let source = input.animated, !source.vertices.isEmpty {
        // Give input/presentation an opportunity between static and wind buffers,
        // including when a reused static resource required no framework await.
        await Task.yield()
        try Task.checkCancellation()
        let capacity = TerrainMeshCapacity(vertices: source.vertices.count, indices: source.indices.count, rounded: false)
        let mesh = try await pacedBuffer { try makeBuffer(source, capacity: capacity) }
        let resource = try await makeResource(mesh, bytes: capacity.bytes)
        animation = .init(mesh: mesh, resource: resource, bytes: capacity.bytes)
      }
      try Task.checkCancellation()
      return .init(allocation: allocation, animation: animation)
    } catch {
      discard(.init(allocation: allocation, animation: animation))
      throw error
    }
  }
  func discard(_ prepared: TerrainPreparedMeshes) {
    guard prepared.allocation != nil || prepared.animation != nil else { return }
    retiring.append(.init(entity: nil, parent: nil, allocation: prepared.allocation,
      orphanMesh: prepared.animation?.mesh, orphanResource: prepared.animation?.resource),
      bytes: (prepared.allocation?.capacity.bytes ?? 0) + (prepared.animation?.bytes ?? 0), at: CACurrentMediaTime())
    scheduleMaintenance()
  }
  func retire(_ entity: Entity, allocation: TerrainMeshAllocation?, bytes: Int) {
    entity.isEnabled = false
    retiring.append(.init(entity: entity, parent: entity.parent, allocation: allocation,
      orphanMesh: nil, orphanResource: nil), bytes: bytes, at: CACurrentMediaTime())
    scheduleMaintenance()
  }
  private func scheduleMaintenance() {
    guard maintenance == nil else { return }
    maintenance = Task(priority: .utility) { @MainActor [weak self] in
      // No strong self across suspension and no dependence on frame callbacks:
      // retirement also progresses in space, when paused, or after leaving play.
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(16))
        guard !Task.isCancelled, let self else { break }
        self.drain()
        if self.retiring.isEmpty && self.pool.metrics.entries == 0 {
          self.maintenance = nil
          break
        }
      }
    }
  }
  private func drain() {
    let began = CACurrentMediaTime()
    let wasBackpressured = retiring.appliesBackpressure
    defer {
      if wasBackpressured && !retiring.appliesBackpressure { onAdmissionAvailable?() }
    }
    var released = 0
    repeat {
      if !retiring.isEmpty {
        autoreleasepool {
          guard let old = retiring.popFirst() else { return }
          old.entity?.removeFromParent()
          old.entity?.components.remove(ModelComponent.self)
          old.entity?.children.removeAll()
          if reuseEnabled, let allocation = old.allocation {
            pool.offer(allocation, capacity: allocation.capacity, at: CACurrentMediaTime())
          }
        }
      } else {
        // Dropping one expired resource per iteration participates in the same
        // budget; never clear all retained meshes at once.
        let expired = autoreleasepool {
          guard let allocation = pool.takeExpired(before: CACurrentMediaTime() - 5) else { return false }
          withExtendedLifetime(allocation) {}
          return true
        }
        guard expired else { break }
      }
      released += 1
    } while released < 32 && CACurrentMediaTime() - began < 0.0005
    if released > 0 { retirementTiming.record(seconds: CACurrentMediaTime() - began) }
  }
  func consumeMetrics() -> Metrics {
    defer {
      allocationTiming.reset(); rewriteTiming.reset(); retirementTiming.reset()
      bufferTiming.reset(); bufferStageTiming.reset(); resourceTiming.reset()
    }
    return .init(reuseEnabled: reuseEnabled, pool: pool.metrics, retirement: retiring.metrics(at: CACurrentMediaTime()),
      allocations: allocations, reused: reused, admissionDeferrals: admissionDeferrals,
      allocationCPU: allocationTiming.snapshot, rewriteCPU: rewriteTiming.snapshot, retirementCPU: retirementTiming.snapshot,
      bufferCreationCPU: bufferTiming.snapshot, bufferStageCPU: bufferStageTiming.snapshot,
      resourceLatency: resourceTiming.snapshot)
  }
}
