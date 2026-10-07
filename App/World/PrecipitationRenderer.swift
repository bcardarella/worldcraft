import RealityKit
import UIKit
import WorldCore

/// Sixteen shared meshes, no per-drop entities or per-frame mesh uploads.
@MainActor final class PrecipitationRenderer {
  private var columns: [Entity] = []
  private var anchors: [SIMD3<Float>] = []
  private var lastPlacement: Double = -.infinity
  private var snow = false
  func configure(root: Entity, snow: Bool) {
    clear(); self.snow = snow
    let prototype = Entity()
    var material = UnlitMaterial(color: snow ? .white : .init(red: 0.58, green: 0.77, blue: 0.94, alpha: 1))
    material.blending = .transparent(opacity: .init(floatLiteral: 0.55))
    let builder = SculptureBuilder(materials: [material])
    for i in 0..<24 {
      let x = Float((i * 17) % 23) / 6 - 1.8, z = Float((i * 11) % 19) / 5 - 1.8
      builder.box(snow ? [0.07, 0.07, 0.07] : [0.025, 0.6, 0.025],
        [x, Float(i) * 0.6 + 1.5, z], 0, parent: prototype)
    }
    builder.finish()
    for _ in 0..<16 {
      let column = prototype.clone(recursive: true)
      column.isEnabled = false; root.addChild(column); columns.append(column); anchors.append(.zero)
    }
  }
  func update(weather: WorldWeather, time: Double, eye: SIMD3<Float>, loaded: Set<ChunkCoordinate>,
    terrain: TerrainGenerator, block: (BlockPosition) -> Block) {
    let active = weather.wet && eye.y < 260 && block(.init(eye)) != .water
    if !active { for column in columns { column.isEnabled = false }; return }
    if time - lastPlacement > 0.7 {
      lastPlacement = time
      for i in columns.indices {
        let x = Int(eye.x) + (i % 4 - 2) * 5 + 2, z = Int(eye.z) + (i / 4 - 2) * 5 + 2
        let y = terrain.height(atX: x, z: z)
        let p = BlockPosition(x, y, z)
        columns[i].isEnabled = loaded.contains(p.chunk) && abs(Float(y) - eye.y) < 20
        guard columns[i].isEnabled else { continue }
        var floor = y
        // Rain remains above tree canopies, homes and roofs built by the player.
        for height in stride(from: ChunkData.height - 1, through: y, by: -1) {
          if block(.init(x, height, z)).isSolid { floor = height; break }
        }
        anchors[i] = [Float(x), Float(floor + 1), Float(z)]
        columns[i].components.set(OpacityComponent(opacity: weather.precipitation))
      }
    }
    for i in columns.indices where columns[i].isEnabled {
      let wind=WorldWind.sample(seed:terrain.seed,time:time,position:anchors[i],weather:weather)
      let phase = Float((time * (snow ? 0.65 : 9) + Double(i) * 0.31).truncatingRemainder(dividingBy: 1.4))
      columns[i].position = anchors[i] + wind.velocity*(snow ? 0.18:0.05) + [0,-phase,0]
      columns[i].orientation=simd_quatf(from:[0,1,0],to:simd_normalize([-wind.velocity.x*0.02,1,-wind.velocity.z*0.02]))
    }
  }
  func clear() {
    columns.forEach { $0.removeFromParent() }; columns = []; anchors = []; lastPlacement = -.infinity
  }
}
