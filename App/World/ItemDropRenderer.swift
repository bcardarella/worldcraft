import Foundation
import RealityKit
import WorldCore

@MainActor
final class ItemDropRenderer {
  private var items: [UUID: DroppedItem] = [:]
  private var models: [UUID: Entity] = [:]
  private var meshes: [InventoryItem: MeshResource] = [:]
  var records: [DroppedItem] { items.values.sorted { $0.id.uuidString < $1.id.uuidString } }
  var freeSlots: Int { max(0, 128 - items.count) }
  func restore(_ records: [DroppedItem]) {
    clear()
    items = Dictionary(records.filter(\.isValid).prefix(128).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
  }
  @discardableResult func add(_ stack: ItemStack, at position: SIMD3<Float>, delay: Float = 0.35) -> Bool {
    guard stack.isValid else { return false }
    if let id = items.first(where: { $0.value.stack.item == stack.item && $0.value.stack.count + stack.count <= Inventory.stackLimit
      && simd_distance_squared($0.value.position, position) < 2.25 })?.key {
      items[id]!.stack.count += stack.count
      items[id]!.pickupDelay = max(items[id]!.pickupDelay, delay)
      return true
    }
    guard freeSlots > 0 else { return false }
    let drop = DroppedItem(stack: stack, position: position, pickupDelay: delay)
    items[drop.id] = drop
    return true
  }
  func update(seconds: Float, time: Double, player: SIMD3<Float>, root: Entity,
    materials: [any Material], loaded: Set<ChunkCoordinate>, terrain: TerrainGenerator, block: (BlockPosition) -> Block) {
    var created = 0
    for id in Array(items.keys) {
      guard var item = items[id] else { continue }
      let visible = loaded.contains(BlockPosition(item.position).chunk) && simd_distance_squared(item.position, player) < 64 * 64
      if !visible { models.removeValue(forKey: id)?.removeFromParent(); continue }
      if seconds > 0 {
        item.update(seconds: seconds, current: terrain.waterCurrent(at:item.position,time:time),
          block: { loaded.contains($0.chunk) ? block($0) : .stone })
        items[id] = item
      }
      if models[id] == nil && created < 2 {
        do {
          if meshes[item.stack.item] == nil {
            var source = InventoryGeometry.mesh(for: item.stack.item)
            let lo = source.positions.reduce(SIMD3<Float>(repeating: .infinity), simd_min)
            let hi = source.positions.reduce(SIMD3<Float>(repeating: -.infinity), simd_max)
            let size = hi - lo, scale = 0.5 / max(size.x, size.y, size.z, 0.1)
            source.positions = source.positions.map { ($0 - (lo + hi) / 2) * scale }
            meshes[item.stack.item] = try TerrainMeshResource.make(PackedTerrainMesh(source))
          }
          if let mesh = meshes[item.stack.item] {
            let entity = ModelEntity(mesh: mesh, materials: materials)
            root.addChild(entity); models[id] = entity; created += 1
          }
        } catch { /* Collection remains available if a thumbnail mesh cannot load. */ }
      }
      let phase = Float(time.truncatingRemainder(dividingBy: 100)) * 1.4
      models[id]?.position = item.position + [0, 0.07 * sin(phase * 2), 0]
      models[id]?.orientation = simd_quatf(angle: phase, axis: [0, 1, 0])
    }
  }
  func nearby(player: SIMD3<Float>, block: (BlockPosition) -> Block) -> [DroppedItem] {
    let center = player + [0, PlayerPhysics.height * 0.45, 0]
    return items.values.filter {
      let distance = simd_distance($0.position, center)
      return $0.pickupDelay <= 0 && distance < 3
        && VoxelRaycast.cast(origin: center, direction: $0.position - center, reach: max(0, distance - 0.3), block: block) == nil
    }
  }
  func collect(id: UUID, amount: Int) {
    guard let item = items[id], amount > 0 else { return }
    if amount >= item.stack.count { items[id] = nil; models.removeValue(forKey: id)?.removeFromParent() }
    else { items[id]!.stack.count -= amount }
  }
  func clear() {
    models.values.forEach { $0.removeFromParent() }
    models.removeAll(); items.removeAll()
  }
}
