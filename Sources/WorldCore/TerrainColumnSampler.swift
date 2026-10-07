/// A small immutable regional snapshot for the bulk column loop. Taking it once
/// per tile removes a shared cache lock from every sampled column. Keep the
/// scalar TerrainGenerator itself cheap to copy in its noise hot path.
struct TerrainColumnSampler: Sendable {
  private let terrain: TerrainGenerator
  private let patches: [ChunkCoordinate: DrainagePatch]
  private let marinas: [Marina]
  init(x: Int, z: Int, width: Int, terrain: TerrainGenerator, marinas: [Marina]) {
    self.terrain = terrain; self.marinas = marinas
    let spacing = WorldDrainage.spacing
    var patches: [ChunkCoordinate: DrainagePatch] = [:]
    for rz in floorDivide(z, by: spacing)...floorDivide(z + width, by: spacing) {
      for rx in floorDivide(x, by: spacing)...floorDivide(x + width, by: spacing) {
        patches[.init(rx, rz)] = WorldDrainage.patch(atX: rx * spacing, z: rz * spacing, terrain: terrain)
      }
    }
    self.patches = patches
  }
  func column(atX x: Int, z: Int) -> TerrainColumn {
    let key = ChunkCoordinate(floorDivide(x, by: WorldDrainage.spacing), floorDivide(z, by: WorldDrainage.spacing))
    guard let drainage = patches[key] else { return terrain.column(atX: x, z: z) }
    let natural = terrain.naturalColumn(atX: x, z: z, drainage: drainage)
    guard terrain.style != .solar, natural.height > TerrainGenerator.seaLevel - 7,
      natural.height <= TerrainGenerator.seaLevel + 7,
      natural.water == nil || natural.water?.kind == .ocean else { return natural }
    return marinas.first(where: { $0.contains(x: x, z: z) })?.waterColumn(natural, x: x, z: z) ?? natural
  }
}
