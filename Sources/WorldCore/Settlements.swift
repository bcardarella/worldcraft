import Foundation

public enum SettlementKind: Int, Sendable { case village, town, city }

public enum SettlementHabitat: String, Sendable { case surface, solar, aquatic }

public struct Settlement: Sendable {
  public let id: UInt64
  public let kind: SettlementKind
  public let name: String
  public let x: Int
  public let z: Int
  public let floor: Int
  public let ground: Block
  public var biome: Biome = .meadow
  public var habitat: SettlementHabitat = .surface
  public var waterLevel: Float? = nil
  public var radiusLimit:Int? = nil
  public var setting: String {
    switch habitat {
    case .surface: biome.name
    case .solar: "Sun lava world: basalt streets, geothermal forges and sheltered markets"
    case .aquatic: "Underwater reef: flooded homes, kelp gardens and swimming aqua people"
    }
  }
  public var foundation: Block { habitat == .solar ? .basalt : habitat == .aquatic ? .limestone : .stone }
  private func openBlock(at y: Int) -> Block {
    habitat == .aquatic && Float(y) < (waterLevel ?? 0) ? .water : .air
  }
  // Blocks are half a metre: cities span 896 m, with 36 m city blocks and
  // 10.5 m carriageways. The extra area remains part of the normal terrain LOD.
  public var radius: Int { habitat == .aquatic ? 22 : radiusLimit ?? [64, 384, 896][kind.rawValue] }
  public var spacing: Int { habitat == .aquatic ? 12 : [24, 48, 72][kind.rawValue] }
  public var streetHalfWidth: Int { habitat == .aquatic ? 1 : [3, 8, 10][kind.rawValue] }
  public var sidewalkWidth: Int { habitat == .aquatic ? 0 : [1, 3, 4][kind.rawValue] }
  public var buildingSetback: Int { habitat == .aquatic ? 3 : streetHalfWidth + sidewalkWidth + (kind == .village ? 1 : 2) }
  public func isRoad(atX px: Int, z pz: Int) -> Bool {
    let rx = px - x, rz = pz - z
    if sportsGround(atX:px,z:pz) != nil { return false }
    let lx = rx - floorDivide(rx, by: spacing)*spacing
    let lz = rz - floorDivide(rz, by: spacing)*spacing
    if habitat == .aquatic { return lx < 2 || lz < 2 || abs(rx) <= 1 || abs(rz) <= 1 }
    return min(lx, spacing-lx) <= streetHalfWidth || min(lz, spacing-lz) <= streetHalfWidth
  }
  public var population: Int { [28, 320, 1200][kind.rawValue] }
  /// Only nearby residents run the detailed actor simulation. Identities,
  /// relationships and homes remain stable as other districts stream in.
  public var activePopulationLimit: Int { [10, 32, 48][kind.rawValue] }
  public var center: SIMD3<Float> { [Float(x), Float(floor), Float(z)] }
  public func contains(_ p: BlockPosition) -> Bool {
    abs(p.x - x) < radius && abs(p.z - z) < radius
  }
  public func distanceSquared(to point: SIMD3<Float>) -> Float {
    let dx = max(0, abs(point.x-Float(x))-Float(radius))
    let dz = max(0, abs(point.z-Float(z))-Float(radius))
    let dy = max(0, point.y-Float(ChunkData.height), Float(floor-8)-point.y)
    return dx*dx+dy*dy+dz*dz
  }

  /// A procedural grammar of streets, plots, buildings, interiors and lamps.
  /// Returning air clears trees and terrain above each graded settlement pad.
  public func block(at p: BlockPosition, terrain: TerrainGenerator, building cached: BuildingDescriptor? = nil) -> Block? {
    guard contains(p), p.y >= ChunkData.minimumY else { return nil }
    // Basement air must override natural rock before the ordinary shallow pad.
    if let sports = sportsGround(atX:p.x,z:p.z) {
      if let block = sports.stadium?.column(x:p.x,z:p.z).block(y:p.y-floor) { return block }
      if p.y >= floor-4 { return p.y < floor-1 ? foundation : sports.surfaceBlock(x:p.x,y:p.y-floor,z:p.z) }
    }
    if p.y < floor - 4 { return p.y > terrain.height(atX: p.x, z: p.z) ? foundation : nil }
    let rx = p.x - x
    let rz = p.z - z
    let y = p.y - floor
    if let port = rocketPort, port.contains(x: p.x, z: p.z) {
      if y < -1 { return foundation }
      if y == -1 {
        let dx = abs(p.x - port.x), dz = abs(p.z - port.z)
        return max(dx, dz) == 6 || (dx <= 1 && dz <= 3) ? .limestone : .basalt
      }
      if y == 0 && abs(p.x - port.x) == 7 && abs(p.z - port.z) == 7 { return .lantern }
      return .air
    }
    let lotX = floorDivide(rx, by: spacing)
    let lotZ = floorDivide(rz, by: spacing)
    let lx = rx - lotX * spacing
    let lz = rz - lotZ * spacing
    let road = habitat == .aquatic ? (lx < 2 || lz < 2 || abs(rx) <= 1 || abs(rz) <= 1)
      : (min(lx,spacing-lx) <= streetHalfWidth || min(lz,spacing-lz) <= streetHalfWidth)
    let sidewalk = habitat != .aquatic && !road
      && (min(lx, spacing-lx) <= streetHalfWidth+sidewalkWidth || min(lz, spacing-lz) <= streetHalfWidth+sidewalkWidth)
    if y < -1 { return foundation }
    if y == -1 {
      if sidewalk { return habitat == .solar ? .brick : .limestone }
      if road && kind != .village && (lx == 0 || lz == 0) && abs(rx + rz) % 8 < 4 { return .limestone }
      return road ? (habitat == .aquatic || kind == .village ? foundation : .basalt) : ground
    }
    if road || sidewalk {
      return openBlock(at: p.y)
    }
    // Roadside lamps and benches give every size a lived-in street edge.
    if lx == buildingSetback && lz == buildingSetback {
      if (0...2).contains(y) { return habitat == .surface ? .wood : foundation }
      if y == 3 { return kind == .village && habitat != .aquatic ? .torch : .lantern }
    }
    let park = lotUse(x:lotX,z:lotZ,terrain:terrain) == .park
    let completeLot =
      abs(lotX * spacing + spacing / 2) <= radius - spacing / 2
      && abs(lotZ * spacing + spacing / 2) <= radius - spacing / 2
    if park || !completeLot {
      let gardenX = lx - spacing/2, gardenZ = lz - spacing/2
      if habitat == .solar {
        // Basalt vents with protected, recessed molten cores and glowing caps.
        if abs(gardenX) <= 3 && abs(gardenZ) <= 3 {
          if y == 0 { return abs(gardenX) == 3 || abs(gardenZ) == 3 ? .basalt : .lava }
          if y == 1 && abs(gardenX) == 3 && abs(gardenZ) == 3 { return .brick }
          if y == 3 && gardenX == 0 && gardenZ == 0 { return .lantern }
        }
      } else if habitat == .aquatic {
        // Branching coral and lantern-tipped reef gardens; lanes remain flooded.
        if lx == 6 && lz == 6 && (0...4).contains(y) { return .coral }
        if y == 3 && (5...8).contains(lx) && lz == 6 { return .coral }
        if y == 5 && lx == 6 && lz == 6 { return .lantern }
      } else {
        // Shade trees and benches sit inside the plaza, clear of both pavements.
        let treeX = abs(gardenX)-min(7, max(0, spacing/2-buildingSetback-3))
        let treeZ = abs(gardenZ)-min(7, max(0, spacing/2-buildingSetback-3))
        if treeX == 0 && treeZ == 0 && (0...5).contains(y) { return .wood }
        if abs(treeX) <= 2 && abs(treeZ) <= 2 && (5...8).contains(y) { return .leaves }
        if abs(gardenX) <= 3 && abs(gardenZ) == 3 {
          if y == 0 { return .wood }
          if y == 1 && abs(gardenX) == 3 { return .wood }
        }
      }
      return openBlock(at: p.y)
    }
    guard let building = cached ?? building(lotX: lotX, lotZ: lotZ, terrain: terrain) else { return openBlock(at: p.y) }
    let minimum = building.minimum
    let maximum = building.maximum
    guard (minimum...maximum).contains(lx), (minimum...maximum).contains(lz) else {
      // A little hedge along cottage gardens and town sidewalks.
      return y == 0 && lz == maximum + 1 && (minimum...maximum).contains(lx) && kind != .city
        ? (habitat == .solar ? .basalt : habitat == .aquatic ? .coral : .leaves) : openBlock(at: p.y)
    }
    let result = building.block(x: lx, y: y, z: lz)
    return result == .air ? openBlock(at: p.y) : result
  }

  public func residentPosition(_ index: Int) -> SIMD3<Float> {
    let lanes = max(0, (radius-4)/spacing)
    let road = (index % (lanes*2+1) - lanes) * spacing
    let along = (index * 13) % (radius * 2 - 10) - radius + 5
    return [Float(x + road) + 0.5, Float(floor), Float(z + along) + 0.5]
  }

  public var vehicleCount: Int { habitat == .aquatic ? 0 : kind == .village ? 2 : (radius/spacing)*(radius/spacing) }
  public func vehicleDistrict(_ index: Int) -> SIMD3<Float> {
    guard kind != .village else { return center }
    let width = radius/spacing
    return center + [Float((index%width-width/2)*spacing*2),0,Float((index/width-width/2)*spacing*2)]
  }
  public func vehiclePosition(_ index: Int) -> SIMD3<Float> {
    if kind == .village { return center + [0.5,0,Float(6+index*7)+0.5] }
    let original = vehicleDistrict(index) + [3.5,0,Float(spacing/2)+0.5]
    guard let field = sportsGround(atX:Int(original.x.rounded(.down)),z:Int(original.z.rounded(.down))) else { return original }
    // Sports superblocks replace interior streets. Park on the nearest
    // perimeter carriageway instead of inside dugouts, stands or the field.
    let border = Float(streetHalfWidth+sidewalkWidth+2)
    let candidates: [SIMD3<Float>] = [
      [Float(field.x0)-border+3.5,original.y,original.z],
      [Float(field.x1)+border+3.5,original.y,original.z],
      [original.x,original.y,Float(field.z0)-border+3.5],
      [original.x,original.y,Float(field.z1)+border+3.5],
    ]
    return candidates.min { a,b in
      let da=a-original,db=b-original
      return da.x*da.x+da.z*da.z < db.x*db.x+db.z*db.z
    } ?? original
  }
}

public enum SettlementGenerator {
  public static let regionSize = 2_048
  private struct Key:Hashable, Sendable { let seed:UInt64; let style:Int; let region:ChunkCoordinate }
  private static let cache = RegionalPlanCache<Key, Settlement?>(capacity: 1024)
  static var cacheMetrics: RegionalCacheMetrics { cache.metrics }
  public static func site(in region: ChunkCoordinate, terrain: TerrainGenerator) -> Settlement? {
    // Settlement placement precedes marinas; surveying either feature must not
    // recursively request the other or depend on which streaming job ran first.
    let key = Key(seed: terrain.seed, style: terrain.style.rawValue, region: region)
    return cache.value(for: key) { make(in: region, terrain: terrain.marinaSurveyTerrain) }
  }
  private static func make(in region: ChunkCoordinate, terrain: TerrainGenerator) -> Settlement? {
    let hash = terrain.hash(region.x, region.z, salt: 2_017)
    let home = region == .init(0, 0)
    guard home || hash % 10 < 3 else { return nil }
    let roll = Int((hash >> 8) % 10)
    let kind: SettlementKind = home ? .village : (roll < 6 ? .village : (roll < 9 ? .town : .city))
    let ox = region.x * regionSize
    let oz = region.z * regionSize
    // Preserve the starting village near spawn; larger settlements reserve
    // enough land to contain their entire street grid inside their region.
    let cx = (home ? 96 : regionSize/2-64) + Int((hash >> 16) % UInt64(home ? 65 : 129))
    let cz = (home ? 96 : regionSize/2-64) + Int((hash >> 24) % UInt64(home ? 65 : 129))
    let margins = home ? [72,36] : [[64,384,896][kind.rawValue]+8]
    let searchStep = home ? 40 : 160
    if !home && terrain.style != .solar && (hash >> 32) % 3 == 0,
      let reef = aquaticSite(in: region, hash: hash, terrain: terrain) { return reef }
    for margin in margins {
    for (dx, dz) in [
      (0, 0), (-40, 0), (40, 0), (0, -40), (0, 40), (-40, -40), (40, 40), (-40, 40), (40, -40),
    ] {
      let x = ox + min(home ? 192 : regionSize-margin, max(home ? 64 : margin, cx + dx*searchStep/40))
      let z = oz + min(home ? 192 : regionSize-margin, max(home ? 64 : margin, cz + dz*searchStep/40))
      let h = terrain.height(atX: x, z: z)
      guard h > TerrainGenerator.seaLevel + 3 && h < ChunkData.height - 50,
        terrain.waterBody(atX: x, z: z) == nil,
        !WorldDrainage.intersects(x:x,z:z,halfX:margin,halfZ:margin,terrain:terrain)
      else { continue }
      let solar = terrain.style == .solar
      let names = solar ? ["Cinder", "Ember", "Obsidian", "Furnace", "Flare", "Basalt", "Magma", "Sol"]
        : ["Oak", "Willow", "Birch", "Copper", "Meadow", "Silver", "Amber", "Maple"]
      let first = names[Int(hash % 8)]
      let last = solar ? (kind == .village ? " Hearth" : " Forge")
        : (kind == .village ? " Hollow" : (kind == .town ? " Crossing" : " City"))
      return .init(
        id: hash, kind: kind, name: first + last, x: x, z: z, floor: h + 1,
        ground: solar ? .basalt : terrain.surface(atX: x, z: z), biome: terrain.biome(atX: x, z: z),
        habitat: solar ? .solar : .surface,radiusLimit:margin-8)
    }
    }
    return terrain.style == .solar || home ? nil : aquaticSite(in: region, hash: hash, terrain: terrain)
  }

  private static func aquaticSite(in region: ChunkCoordinate, hash: UInt64, terrain: TerrainGenerator) -> Settlement? {
    // One settlement per region. Test a bounded footprint so roofs remain below
    // even low tide and the village never drains a lake or becomes a dry island.
    for dz in [regionSize/2, regionSize/4, regionSize*3/4] {
      for dx in [regionSize/2, regionSize/4, regionSize*3/4] {
        let x = region.x * regionSize + dx, z = region.z * regionSize + dz
        let center = terrain.column(atX: x, z: z)
        guard let water = center.water, water.kind == .ocean,
          Float(center.height) < water.level - 18 else { continue }
        var highest = center.height
        var submerged = true
        for oz in stride(from: -21, through: 21, by: 7) {
          for ox in stride(from: -21, through: 21, by: 7) {
            let column = terrain.column(atX: x + ox, z: z + oz)
            if column.water?.id != water.id || Float(column.height) >= water.level - 18 { submerged = false; break }
            highest = max(highest, column.height)
          }
          if !submerged { break }
        }
        guard submerged else { continue }
        let names = ["Pearl", "Coral", "Lagoon", "Azure", "Nacre", "Sapphire", "Anemone", "Tidal"]
        return .init(id: hash, kind: .village, name: names[Int(hash % 8)] + " Reef", x: x, z: z,
          floor: highest + 1, ground: .sand, biome: .ocean, habitat: .aquatic, waterLevel: water.level)
      }
    }
    return nil
  }
  public static func site(at p: BlockPosition, terrain: TerrainGenerator) -> Settlement? {
    let region = ChunkCoordinate(floorDivide(p.x, by: regionSize), floorDivide(p.z, by: regionSize))
    guard let site = site(in: region, terrain: terrain), site.contains(p) else { return nil }
    return site
  }
  public static func sites(overlapping chunk: ChunkCoordinate, terrain: TerrainGenerator)
    -> [Settlement]
  {
    let x0 = floorDivide(chunk.x * 16 - 1, by: regionSize)
    let x1 = floorDivide(chunk.x * 16 + 16, by: regionSize)
    let z0 = floorDivide(chunk.z * 16 - 1, by: regionSize)
    let z1 = floorDivide(chunk.z * 16 + 16, by: regionSize)
    return (x0...x1).flatMap { x in
      (z0...z1).compactMap { z in site(in: .init(x, z), terrain: terrain) }
    }
  }
}
