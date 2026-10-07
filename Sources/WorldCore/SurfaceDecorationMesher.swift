public enum PlantKind: Int, CaseIterable, Codable, Sendable {
  case grass, fern, daisy, goldenFlower, lavender, berryBush, mushroom, reed, succulent, coral
  case poppy, sunflower, clover, bluebell, heather, bamboo, broadleaf, orchid, dryGrass, aloe, kelp, seagrass
}

/// Solid voxel plants share a chunk mesh. Shapes are reused within each job,
/// with no image cards, individual entities or decorative collision bodies.
public enum SurfaceDecorationMesher {
  public static let shapes = PlantKind.allCases.map { shape($0).mesh(cellSize: 0.125) }
  public static func build(_ chunk: ChunkData, terrain: TerrainGenerator, lush: Bool = true,
    changes: [BlockPosition: PlantEdit] = [:]) -> VoxelMesh {
    mesh(instances(in: chunk, terrain: terrain, lush: lush, changes: changes), chunk: chunk.coordinate)
  }
  public static func mesh(_ instances: [PlantInstance], chunk: ChunkCoordinate) -> VoxelMesh {
    var mesh = VoxelMesh()
    for instance in instances {
      var plant = shapes[instance.kind.rawValue]
      let center = instance.origin - chunk.origin
      plant.positions = plant.positions.map { $0 * instance.scale + center }
      plant.windWeights = plant.positions.map { min(1,max(0,$0.y-center.y))*0.8 }
      mesh.append(plant)
    }
    return mesh
  }
  public static func instances(in chunk: ChunkData, terrain: TerrainGenerator, lush: Bool = true,
    changes: [BlockPosition: PlantEdit] = [:]) -> [PlantInstance] {
    var result: [PlantInstance] = []
    // Maintained sports turf is not wild habitat. Resolve reservations once per
    // chunk, before scanning columns, so this adds no per-plant world queries.
    let grounds = SettlementGenerator.sites(overlapping: chunk.coordinate, terrain: terrain)
      .flatMap(\.sportsGrounds)
    let marinas=MarinaGenerator.sites(x:chunk.coordinate.x*16,z:chunk.coordinate.z*16,width:16,terrain:terrain)
    for z in 0..<16 {
      for x in 0..<16 {
        let wx = chunk.coordinate.x * 16 + x, wz = chunk.coordinate.z * 16 + z
        guard !grounds.contains(where: { $0.contains(x: wx, z: wz) }) else { continue }
        guard !marinas.contains(where: { $0.contains(x:wx,z:wz) }) else { continue }
        for y in stride(from: min(chunk.maximumFilledY, ChunkData.height - 2), through: 0, by: -1) {
          let ground = chunk[x, y, z]
          guard ground.isSolid else { continue }
          if ground.isFoliage { continue }
          let h = terrain.hash(wx, wz, salt: UInt64(y) &+ 8_291)
          guard chunk[x, y + 1, z] == .air, chunk[x, y + 2, z] == .air,
            h % (lush ? 12 : 48) == 0 else { break }
          let kind: PlantKind
          if ground == .grass || ground == .snow || ground == .sand {
            let wet = terrain.waterBody(atX: wx + 2, z: wz) != nil || terrain.waterBody(atX: wx, z: wz + 2) != nil
            if wet { kind = .reed }
            else {
              let patch = terrain.hash(floorDivide(wx, by: 8), floorDivide(wz, by: 8), salt: 3_719)
              let choices = terrain.biome(atX: wx, z: wz).plants
              guard !choices.isEmpty else { break }
              kind = choices[Int(((h >> 24) &+ patch) % UInt64(choices.count))]
            }
            if ground != .grass && h % 5 != 0 { break }
          } else { break }
          let position = BlockPosition(wx, y + 1, wz)
          if changes[position] == nil {
            result.append(.init(position: position, kind: kind, scale: 0.8 + Float((h >> 16) % 5) * 0.07))
          }
          break
        }
        if lush, let body = terrain.waterBody(atX: wx, z: wz), body.kind == .ocean,
          terrain.hash(wx, wz, salt: 9_811) % 51 == 0 {
          let floor = terrain.height(atX: wx, z: wz)
          let position = BlockPosition(wx, floor + 1, wz)
          if floor >= Int(body.level) - 9 && floor < Int(body.level) - 2,
            chunk[x, floor, z] == .sand, chunk[x, floor + 1, z] == .water, changes[position] == nil {
            let kind: PlantKind = [.coral, .kelp, .seagrass][Int(terrain.hash(wx, wz, salt: 4_987) % 3)]
            result.append(.init(position: position, kind: kind))
          }
        }
      }
    }
    for change in changes.values.sorted(by: { ($0.position.y, $0.position.z, $0.position.x) < ($1.position.y, $1.position.z, $1.position.x) }) {
      guard change.position.chunk == chunk.coordinate, let kind = change.kind,
        kind.canPlant(at: change.position, block: { chunk[$0.x - chunk.coordinate.x * 16, $0.y, $0.z - chunk.coordinate.z * 16] }) else { continue }
      result.append(.init(position: change.position, kind: kind))
    }
    return result
  }

  public static func shape(_ kind: PlantKind) -> VoxelShape {
    var s = VoxelShape()
    switch kind {
    case .grass:
      s.fill(-2 ... -2, 0...3, 0...0, tile: 29)
      s.fill(0...0, 0...5, 1...1, tile: 30)
      s.fill(2...2, 0...4, -1 ... -1, tile: 29)
    case .fern:
      s.fill(0...0, 0...4, 0...0, tile: 31)
      for y in [1, 3] { for axis in 0..<2 {
        for side in [-1, 1] {
          for i in 1...3 { s.put(axis == 0 ? i * side : 0, y + i / 2, axis == 1 ? i * side : 0, tile: i == 3 ? 29 : 30) }
        }
      } }
    case .daisy, .goldenFlower, .lavender:
      s.fill(0...0, 0...4, 0...0, tile: 31)
      s.put(-1, 2, 0, tile: 30); s.put(1, 1, 0, tile: 29)
      let tile = kind == .daisy ? 26 : (kind == .goldenFlower ? 25 : 27)
      for d in [(-1, 0), (1, 0), (0, -1), (0, 1)] { s.put(d.0, 5, d.1, tile: tile) }
      s.put(0, 5, 0, tile: 25)
      if kind == .lavender { s.fill(0...0, 6...7, 0...0, tile: 27) }
    case .berryBush:
      s.fill(0...0, 0...1, 0...0, tile: 31)
      s.fill(-2...2, 2...3, -1...1, tile: 30)
      s.fill(-1...1, 4...4, -1...1, tile: 29)
      for x in [-2, 1] { s.put(x, 3, -2, tile: 27) }
    case .mushroom:
      s.fill(0...0, 0...2, 0...0, tile: 26)
      s.fill(-2...2, 3...3, -1...1, tile: 21)
      s.put(-1, 3, 0, tile: 26); s.put(1, 3, -1, tile: 26)
      s.fill(-1...1, 4...4, 0...0, tile: 21)
    case .reed:
      for x in [-2, 0, 2] {
        s.fill(x...x, 0...(x == 0 ? 9 : 7), 0...0, tile: 31)
        s.fill(x...x, 7...(x == 0 ? 10 : 8), 0...0, tile: 5)
      }
    case .succulent:
      s.fill(-1...1, 0...3, -1...1, tile: 30)
      s.fill(0...0, 4...7, 0...0, tile: 29)
      s.fill(-3 ... -2, 2...4, 0...0, tile: 30)
      s.put(2, 2, 0, tile: 30); s.fill(3...3, 2...5, 0...0, tile: 29)
      s.put(0, 8, 0, tile: 27)
    case .coral:
      s.fill(0...0, 0...4, 0...0, tile: 20)
      s.fill(-2...2, 2...2, 0...0, tile: 20)
      s.fill(-2 ... -2, 3...5, 0...0, tile: 27)
      s.fill(2...2, 3...4, 0...0, tile: 25)
      s.fill(0...0, 1...1, -2...2, tile: 20)
    case .poppy, .bluebell, .orchid, .heather:
      let tile = kind == .poppy ? 21 : kind == .orchid ? 20 : 27
      s.fill(0...0, 0...5, 0...0, tile: 31)
      s.fill(-1...1, 4...5, -1...1, tile: tile)
      s.put(0, 6, 0, tile: kind == .poppy ? 5 : 26)
      if kind == .heather { s.fill(2...2, 0...4, 1...1, tile: 27) }
      if kind == .orchid { s.fill(-3 ... -1, 1...1, 0...0, tile: 30) }
    case .sunflower:
      s.fill(0...0, 0...10, 0...0, tile: 31)
      s.fill(-2...2, 8...12, 0...0, tile: 25)
      s.fill(-1...1, 9...11, -1 ... -1, tile: 5)
      s.fill(1...3, 4...4, 0...0, tile: 30)
    case .clover:
      for x in [-2, 1] { for z in [-2, 1] {
        s.fill(x...(x + 1), 0...1, z...(z + 1), tile: 30)
      } }
      s.put(0, 2, 0, tile: 26)
    case .bamboo:
      for x in [-2, 1] {
        s.fill(x...x, 0...14, 0...0, tile: 30)
        for y in [4, 8, 12] {
          s.put(x, y, 0, tile: 31)
          s.fill((x - 2)...(x + 2), (y + 1)...(y + 1), 0...0, tile: 29)
        }
      }
    case .broadleaf, .aloe:
      s.fill(0...0, 0...5, 0...0, tile: 31)
      for side in [-1, 1] { for i in 1...4 {
        let y = kind == .aloe ? i : 5 - i / 2
        s.fill((side * i)...(side * i), y...y, -1...1, tile: 30)
        s.fill(-1...1, y...y, (side * i)...(side * i), tile: 29)
      } }
    case .dryGrass:
      for x in [-2, 0, 2] { s.fill(x...x, 0...(4 + abs(x)), 0...0, tile: 25) }
    case .kelp:
      for y in 0...15 {
        s.put(y / 4 % 2, y, 0, tile: 31)
        if y % 3 == 0 { s.fill(-1...2, y...y, 0...0, tile: 30) }
      }
    case .seagrass:
      for x in [-2, 0, 2] { s.fill(x...x, 0...(6 - abs(x)), 0...0, tile: 29) }
    }
    return s
  }
}
