import RealityKit
import UIKit
import WorldCore

/// Bulbs are baked into streamed meshes. Only three nearby fixtures need real
/// lights; the city skyline retains its emissive windows at every draw distance.
@MainActor final class LampRenderer {
  private var sources = LocalLightSources()
  private var lights: [BlockPosition:Entity] = [:]
  var activeLightCount: Int { lights.values.filter(\.isEnabled).count }
  func install(_ tile: TerrainTile, positions: [SIMD3<Float>]) {
    sources.install(tile, positions: positions)
  }
  func remove(_ tile: TerrainTile) { sources.remove(tile) }
  func clear() { lights.values.forEach { $0.removeFromParent() }; lights=[:]; sources.clear() }
  func update(time: Double, eye: SIMD3<Float>, daylight: Float, root: Entity, block: (BlockPosition)->Block) {
    guard !RenderDiagnostics.current.disableLocalLights else { return }
    guard let nearby = sources.sample(time: time, interval: 0.2, eye: eye, radius: 44, limit: 3,
      isValid: { block($0) == .lantern }) else { return }
    let wanted=Set(nearby.map { BlockPosition($0) })
    for key in Array(lights.keys) where !wanted.contains(key) { lights.removeValue(forKey:key)?.removeFromParent() }
    for point in nearby {
      let key=BlockPosition(point)
      if lights[key] == nil {
        let entity=Entity(); entity.position=point
        entity.components.set(PointLightComponent(color:.init(red:1,green:0.79,blue:0.46,alpha:1),intensity:550,attenuationRadius:14))
        root.addChild(entity); lights[key]=entity
      }
      guard let entity=lights[key], var light=entity.components[PointLightComponent.self] else { continue }
      let roof=(1...10).contains { block(key + .init(0,$0,0)).isOpaque }
      let brightness: Float = roof ? 1 : 1-smoothstep(0.05,0.55,daylight)
      let enabled = brightness > 0.01
      if entity.isEnabled != enabled { entity.isEnabled = enabled }
      let intensity = 550 * brightness
      if abs(light.intensity - intensity) > 0.5 { light.intensity = intensity; entity.components.set(light) }
    }
  }
}
