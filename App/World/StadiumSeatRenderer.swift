import Foundation
import RealityKit
import WorldCore

/// Availability-gated comparison path. Spatial groups retain their tile's
/// coverage, haze and shadow ownership; templates alone are shared globally.
@MainActor final class StadiumSeatRenderer {
  private struct Key: Hashable { let color: UInt8; let repeatAtlas: Bool }
  private struct Template { let mesh: LowLevelMesh; let resource: MeshResource; let bytes: Int }
  private var templates: [Key: Template] = [:]
  private(set) var enabled: Bool
  enum Failure: Error { case unavailable, allocation(any Error) }
  struct Metrics: Sendable, Encodable {
    let enabled: Bool
    let templates: Int
    let templateBytes: Int
    let instances: Int
    let groups: Int
    let transformBytes: Int
  }
  init(requested: Bool = ProcessInfo.processInfo.arguments.contains("--instance-stadium-seats")) {
    // Requires an on-device matched comparison before default rollout: shared
    // vertices save upload/storage but extra groups may increase draw overhead.
    if #available(visionOS 26.0, macOS 26.0, iOS 26.0, *) { enabled = requested }
    else { enabled = false }
  }
  func disable() { enabled = false }
  func metrics(instances: Int, groups: Int) -> Metrics {
    .init(enabled: enabled, templates: templates.count,
      templateBytes: templates.values.reduce(0) { $0 + $1.bytes },
      instances: instances, groups: groups, transformBytes: instances * StadiumSeatInstance.transformBytes)
  }
  func attach(_ seats: [StadiumSeatInstance], repeatAtlas: Bool,
    materials: [any Material], to parent: Entity) throws -> [Entity] {
    guard !seats.isEmpty else { return [] }
    guard enabled else { throw Failure.unavailable }
    if #available(visionOS 26.0, macOS 26.0, iOS 26.0, *) {
      do { return try makeGroups(seats, repeatAtlas: repeatAtlas, materials: materials, parent: parent) }
      catch { throw Failure.allocation(error) }
    }
    throw Failure.unavailable
  }
  @available(visionOS 26.0, macOS 26.0, iOS 26.0, *)
  private func makeGroups(_ seats: [StadiumSeatInstance], repeatAtlas: Bool,
    materials: [any Material], parent: Entity) throws -> [Entity] {
    var result: [Entity] = []
    for color: UInt8 in [13, 21] {
      let group = seats.filter { $0.color == color }
      guard !group.isEmpty else { continue }
      let key = Key(color: color, repeatAtlas: repeatAtlas)
      let template: Template
      if let existing = templates[key] { template = existing }
      else {
        let source = StadiumSeatInstance.template(color: color, repeatAtlas: repeatAtlas)
        let mesh = try TerrainMeshResource.makeLowLevel(source)
        template = .init(mesh: mesh, resource: try MeshResource(from: mesh), bytes: source.byteCount)
        templates[key] = template // At most two colours x two atlas paths.
      }
      let data = try LowLevelInstanceData(instanceCount: group.count)
      data.withMutableTransforms { buffer in
        for (i, seat) in group.enumerated() { buffer[i] = seat.transform }
      }
      let low = group.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1.minimum) }
      let high = group.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1.maximum) }
      let instances = try MeshInstancesComponent(mesh: template.resource, instances: data,
        bounds: BoundingBox(min: low, max: high))
      let entity = Entity()
      entity.name = "Stadium seats \(color)"
      entity.components.set(ModelComponent(mesh: template.resource, materials: materials))
      entity.components.set(instances)
      // The parent owns partially completed groups even if a later allocation
      // fails, so its ordinary paced retirement also services those resources.
      parent.addChild(entity); result.append(entity)
    }
    return result
  }
}
