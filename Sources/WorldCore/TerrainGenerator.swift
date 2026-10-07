import Foundation

public struct TerrainGenerator: Sendable {
  public let seed: UInt64
  public let style: PlanetStyle
  public let bulkCaves: Bool
  // Indexing only reuses exact procedural tree descriptors. It is excluded
  // from cache identity; scalar/indexed complete archives must stay identical.
  public let indexedTrees: Bool
  private var includesMarinas = true
  // bulkCaves changes evaluation cost, not a single generated cell. It is not
  // part of content identity; scalar/bulk archives are tested byte-for-byte.
  var cacheVariant: Int { includesMarinas ? 1 : 0 }
  var marinaSurveyTerrain: Self { var copy=self;copy.includesMarinas=false;return copy }
  public var landmarks: [WorldLandmark] { WorldLandmarks.cached(terrain: marinaSurveyTerrain) }
  public static let seaLevel = 23
  public init(seed: UInt64, style: PlanetStyle = .verdant, bulkCaves: Bool = true, indexedTrees: Bool = true) {
    self.seed = seed
    self.style = style
    self.bulkCaves = bulkCaves
    self.indexedTrees = indexedTrees
  }

  public func hash(_ x: Int, _ z: Int, salt: UInt64 = 0) -> UInt64 {
    var n = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B1_85EB_CA87
    n ^= UInt64(bitPattern: Int64(z)) &* 0xC2B2_AE3D_27D4_EB4F
    n ^= seed &+ salt
    n = (n ^ (n >> 30)) &* 0xBF58_476D_1CE4_E5B9
    n = (n ^ (n >> 27)) &* 0x94D0_49BB_1331_11EB
    return n ^ (n >> 31)
  }

  func noise(_ x: Double, _ z: Double, salt: UInt64) -> Double {
    let ix = Int(floor(x))
    let iz = Int(floor(z))
    let dx = x - floor(x)
    let dz = z - floor(z)
    let sx = dx * dx * (3 - 2 * dx)
    let sz = dz * dz * (3 - 2 * dz)
    func value(_ a: Int, _ b: Int) -> Double { Double(hash(a, b, salt: salt) & 65535) / 65535 }
    let a = value(ix, iz) * (1 - sx) + value(ix + 1, iz) * sx
    let b = value(ix, iz + 1) * (1 - sx) + value(ix + 1, iz + 1) * sx
    return a * (1 - sz) + b * sz
  }

  public func height(atX x: Int, z: Int) -> Int {
    column(atX: x, z: z).height
  }

  /// Sample noise and the lake basin once for all consumers of a terrain column.
  public func column(atX x: Int, z: Int) -> TerrainColumn {
    let natural=naturalColumn(atX:x,z:z)
    guard includesMarinas,style != .solar,natural.height>Self.seaLevel-7,natural.height<=Self.seaLevel+7,
      natural.water == nil || natural.water?.kind == .ocean else {return natural}
    let site=MarinaGenerator.site(in:.init(floorDivide(x,by:MarinaGenerator.regionSize),floorDivide(z,by:MarinaGenerator.regionSize)),terrain:self)
    return site?.waterColumn(natural,x:x,z:z) ?? natural
  }

  /// Unmodified drainage for deterministic shoreline surveys (no recursive
  /// feature discovery). Tile workers resolve marina plans before sampling.
  public func naturalColumn(atX x:Int,z:Int)->TerrainColumn {
    naturalColumn(atX: x, z: z, drainage: WorldDrainage.patch(atX: x, z: z, terrain: self))
  }

  func naturalColumn(atX x: Int, z: Int, drainage: DrainagePatch) -> TerrainColumn {
    let original = rawHeight(atX: x, z: z)
    var height = original
    var water: WaterBody?
    if let lake = drainage.lake(atX:x,z:z) {
      let distance = lake.distance(x: x, z: z)
      if distance < 1 {
        height = max(ChunkData.minimumY+1,lake.level - max(1,Int((18+Float(lake.id%15))*pow(1-distance,0.7))))
      } else if distance < 1.35 {
        let blend = smoothstep(1, 1.35, distance)
        height = Int(Float(lake.level + 2) * (1 - blend) + Float(max(original, lake.level + 1)) * blend)
      }
      if distance < 1 { water = lake.body }
    }
    if water == nil, let river = drainage.river(atX:Float(x),z:Float(z)) {
      // Grade the valley and contain the water through small local dips. The
      // same channel cuts through lake shoulders, leaving inlets/outlets open.
      let bankHeight=max(Float(height),river.body.level+1)
      let channel=Float(river.bed)*(1-river.bankBlend)+bankHeight*river.bankBlend
      height=Int(floor(channel))
      if Float(height)<river.body.level { water=river.body }
      if original<=Self.seaLevel+1 && river.body.level<=Float(Self.seaLevel+1) {
        water = .ocean
      }
    }
    if water == nil && height <= Self.seaLevel + 1 { water = style == .solar ? .lava : .ocean }
    return .init(height: height, surface: surface(atHeight: height, water: water), water: water)
  }

  public func rawHeight(atX x: Int, z: Int) -> Int {
    let broad = noise(Double(x) / 1_700, Double(z) / 1_700, salt: 11)
    let hills = noise(Double(x) / 24, Double(z) / 24, salt: 29)
    let detail = noise(Double(x) / 9, Double(z) / 9, salt: 47)
    let mountains = pow(max(0, broad - 0.57), 2) * 290
    let elevation: Double = [0, 7, -2, 10, 3, -3][style.rawValue]
    let height = Int(4 + broad * 29 + hills * 9 + detail * 2 + mountains + elevation)
    if height < Self.seaLevel {
      let depth = Double(Self.seaLevel - height)
      return max(ChunkData.minimumY + 1, height - Int(pow(depth * 1.6, 1.25)))
    }
    return height
  }

  public func surface(atX x: Int, z: Int) -> Block {
    column(atX: x, z: z).surface
  }

  private func surface(atHeight h: Int, water: WaterBody?) -> Block {
    // Submerged frost coasts and high mountain lake beds are sediment, not snow.
    if let water, Float(h) < water.snowLine { return water.kind == .lava ? .basalt : style == .ember ? .stone : .sand }
    if style == .dune { return .sand }
    if style == .frost { return .snow }
    if style == .ember { return .stone }
    if style == .solar { return .stone }
    if h <= Self.seaLevel + 1 { return .sand }
    if h >= 58 { return .snow }
    if h >= 49 { return .stone }
    return .grass
  }

  /// Snow melts on submerged blocks, including old saved edits. The shoreline
  /// accounts for the highest tide and swell, rather than only mean sea level.
  public func waterSafeMaterial(_ block: Block, at p: BlockPosition) -> Block {
    guard block == .snow else { return block }
    for (dx, dz) in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)] {
      if let water = column(atX: p.x+dx, z: p.z+dz).water, Float(p.y) < water.snowLine {
        return water.kind == .lava ? .basalt : .sand
      }
    }
    return block
  }

  public func lake(nearX x: Int, z: Int) -> InlandLake? {
    WorldDrainage.patch(atX:x,z:z,terrain:self).lake(atX:x,z:z)
  }

  public func waterBody(atX x: Int, z: Int) -> WaterBody? {
    column(atX: x, z: z).water
  }

  public func tree(atX x: Int, z: Int) -> TreeDescriptor? {
    tree(atX: x, z: z, column: column(atX: x, z: z))
  }
  // Autoclosure preserves the hash rejection before evaluating a column. Bulk
  // regions supply one immutable drainage/marina snapshot for all candidates.
  func tree(atX x: Int, z: Int, column sample: @autoclosure () -> TerrainColumn) -> TreeDescriptor? {
    let hash = hash(x, z, salt: 67)
    guard style != .dune && style != .ember && style != .solar,
      hash % 89 == 0 || hash % 29 == 0 else { return nil }
    let column = sample()
    let ground = column.height
    guard ground > Self.seaLevel + 2, ground < 58, column.water == nil else {
      return nil
    }
    let biome = self.biome(atX: x, z: z, height: ground, water: column.water)
    let choices = biome.trees
    guard !choices.isEmpty else { return nil }
    if hash % 89 != 0 {
      guard biome.hasDenseForest else { return nil }
      // Keep existing trees and fill forest stands with additional trees.
      // Broad patches leave occasional clearings instead of uniform noise.
      let cover = noise(Double(x) / 72, Double(z) / 72, salt: 10_127)
      guard cover > 0.23, (hash >> 32) % 100 < UInt64(55 + cover * 45) else { return nil }
    }
    if (biome == .meadow || biome == .savanna || biome == .tundra) && hash % 3 != 0 { return nil }
    let species = choices[Int((hash >> 16) % UInt64(choices.count))]
    let height: Int
    switch species {
    case .redwood: height = 26 + Int((hash >> 24) % 10)
    case .spruce: height = 18 + Int((hash >> 24) % 8)
    case .birch, .palm: height = 12 + Int((hash >> 24) % 8)
    case .acacia: height = 8 + Int((hash >> 24) % 5)
    default: height = 10 + Int((hash >> 24) % 9)
    }
    guard
      !CaveGenerator(seed: seed).isCarved(
        at: .init(x, ground, z), surface: ground, waterCovered: false)
    else { return nil }
    return .init(species: species, x: x, z: z, ground: ground, height: height)
  }

  public func block(at p: BlockPosition) -> Block {
    guard p.y >= ChunkData.minimumY else { return .stone }
    guard p.y < ChunkData.height else { return .air }
    if includesMarinas,let marina = MarinaGenerator.site(in:.init(floorDivide(p.x,by:MarinaGenerator.regionSize),floorDivide(p.z,by:MarinaGenerator.regionSize)),terrain:self),
      marina.contains(x:p.x,z:p.z), let block=marina.block(at:p,natural:height(atX:p.x,z:p.z)) { return block }
    if let site = SettlementGenerator.site(at: p, terrain: self),
      let block = site.block(at: p, terrain: self)
    {
      return waterSafeMaterial(block, at: p)
    }
    let h = height(atX: p.x, z: p.z)
    if let landmark = landmarks.first(where: { $0.contains(x:p.x,z:p.z) }),
      let material = landmark.block(at:p, surface:landmark.surface(x:p.x,z:p.z,natural:h), natural:h) { return material }
    if let road = WorldRoads.sample(x:p.x,z:p.z,segments:WorldRoads.segments(x:p.x,z:p.z,width:0,terrain:self)),
      let block = road.block(at:p,natural:column(atX:p.x,z:p.z)) { return block }
    if p.y <= h {
      if CaveGenerator(seed: seed).isCarved(
        at: p, surface: h, waterCovered: waterBody(atX: p.x, z: p.z) != nil)
      {
        return .air
      }
      if p.y == h { return surface(atX: p.x, z: p.z) }
      return p.y >= h - 3 && style != .solar ? .dirt : .stone
    }
    if let water = waterBody(atX: p.x, z: p.z), Float(p.y) < water.level {
      return water.kind == .lava ? .lava : .water
    }
    var foliage: Block = .air
    for tx in (p.x - 4)...(p.x + 4) {
      for tz in (p.z - 4)...(p.z + 4) {
        guard let tree = tree(atX: tx, z: tz), let block = tree.block(at: p) else { continue }
        if block == tree.trunk { return block }
        if foliage == .air { foliage = block }
      }
    }
    return foliage
  }

  public func generate(
    _ coordinate: ChunkCoordinate, edits: [BlockPosition: Block] = [:], includeCaves: Bool = true
  )
    -> ChunkData
  {
    var chunk = ChunkData(coordinate: coordinate)
    let ox = coordinate.x * 16
    let oz = coordinate.z * 16
    let caves = CaveGenerator(seed: seed)
    let marinas = MarinaGenerator.sites(x:ox-1,z:oz-1,width:18,terrain:self)
    let sampler = TerrainColumnSampler(x: ox-1, z: oz-1, width: 18,
      terrain: self, marinas: includesMarinas ? marinas : [])
    for x in -1...16 {
      if Task.isCancelled { return chunk }
      for z in -1...16 {
        let column = sampler.column(atX: ox + x, z: oz + z)
        let h = column.height
        let top = column.surface
        let body = column.water
        // A sloping river can have a fractional surface level. Match block(at:)
        // so its partially submerged top cell does not become a dry seam.
        let waterTop = body.map { Int(ceil($0.level)) - 1 } ?? h
        let carved = includeCaves && bulkCaves
          ? caves.column(x: ox + x, z: oz + z, surface: h, waterCovered: body != nil) : nil
        for y in ChunkData.minimumY...max(h, waterTop) {
          if includeCaves && y <= h,
            carved?.isCarved(y: y)
              ?? caves.isCarved(at: .init(ox + x, y, oz + z), surface: h, waterCovered: body != nil)
          {
            continue
          }
          chunk[x, y, z] = y > h ? (body?.kind == .lava ? .lava : .water)
            : (y == h ? top : (y >= h - 3 && style != .solar ? .dirt : .stone))
        }
      }
    }
    // Include roots four blocks beyond the one-cell meshing halo as well as
    // beyond the chunk itself, so broad crowns cull correctly at chunk seams.
    for tree in TerrainTreePlans.trees(x: (ox - 5)..<(ox + 21), z: (oz - 5)..<(oz + 21),
      terrain: self, order: .xThenZ) {
      let tx = tree.x, tz = tree.z
      for x in max(ox - 1, tx - 4)...min(ox + 16, tx + 4) {
        for z in max(oz - 1, tz - 4)...min(oz + 16, tz + 4) {
          for y in (tree.ground + 1)...(tree.top + 2) {
            if let block = tree.block(at: .init(x, y, z)),
              chunk[x - ox, y, z - oz] == .air || block == tree.trunk
            {
              chunk[x - ox, y, z - oz] = block
            }
          }
        }
      }
    }
    for site in SettlementGenerator.sites(overlapping: coordinate, terrain: self) {
      for x in -1...16 {
        for z in -1...16 {
          guard abs(ox + x - site.x) < site.radius && abs(oz + z - site.z) < site.radius else {
            continue
          }
          let sports = site.sportsGround(atX:ox+x,z:oz+z)
          // Evaluate the bowl profile once per column, not once per voxel.
          let stadium = sports?.stadium?.column(x:ox+x,z:oz+z)
          let lowest = min(site.floor + (stadium?.minimumY ?? -4), height(atX: ox + x, z: oz + z) + 1)
          let building = site.building(lotX: floorDivide(ox + x - site.x, by: site.spacing),
            lotZ: floorDivide(oz + z - site.z, by: site.spacing), terrain: self)
          for y in max(ChunkData.minimumY, lowest)..<ChunkData.height {
            if let stadium, let block = stadium.block(y:y-site.floor) {
              chunk[x,y,z] = block
              continue
            }
            if let sports, y >= site.floor-4 {
              chunk[x,y,z] = y < site.floor-1 ? site.foundation : sports.surfaceBlock(x:ox+x,y:y-site.floor,z:oz+z)
              continue
            }
            if let block = site.block(at: .init(ox + x, y, oz + z), terrain: self, building: building) {
              chunk[x, y, z] = block
            }
          }
        }
      }
    }
    for landmark in landmarks where landmark.x + landmark.halfX >= ox-1 && landmark.x-landmark.halfX <= ox+16
      && landmark.z+landmark.halfZ >= oz-1 && landmark.z-landmark.halfZ <= oz+16 {
      for x in -1...16 { for z in -1...16 where landmark.contains(x:ox+x,z:oz+z) {
        let natural = height(atX:ox+x,z:oz+z)
        let level = landmark.surface(x:ox+x,z:oz+z,natural:natural)
        for y in max(ChunkData.minimumY,min(natural+1,level-4))..<ChunkData.height {
          if let material = landmark.block(at:.init(ox+x,y,oz+z),surface:level,natural:natural) { chunk[x,y,z] = material }
        }
      } }
    }
    let roads = WorldRoads.segments(x:ox-1,z:oz-1,width:18,terrain:self)
    if !roads.isEmpty {
      let sites = SettlementGenerator.sites(overlapping:coordinate,terrain:self)
      let landmarks = self.landmarks
      for x in -1...16 { for z in -1...16 {
        let wx=ox+x,wz=oz+z
        guard !sites.contains(where:{$0.contains(.init(wx,0,wz))}),
          !landmarks.contains(where:{$0.contains(x:wx,z:wz)}),
          let road=WorldRoads.sample(x:wx,z:wz,segments:roads) else {continue}
        let column=self.column(atX:wx,z:wz)
        for y in max(ChunkData.minimumY,min(column.height+1,road.floor-4))..<ChunkData.height {
          if let block=road.block(at:.init(wx,y,wz),natural:column) {chunk[x,y,z]=block}
        }
      }}
    }
    for marina in marinas {
      for x in -1...16 { for z in -1...16 where marina.contains(x:ox+x,z:oz+z) {
        let natural=height(atX:ox+x,z:oz+z), boxes=marina.column(x:ox+x,z:oz+z)
        for y in max(ChunkData.minimumY,min(natural,marina.floor-16))..<ChunkData.height {
          if let block=marina.block(at:.init(ox+x,y,oz+z),natural:natural,column:boxes) { chunk[x,y,z]=block }
        }
      } }
    }
    for (p, block) in edits {
      chunk[p.x - ox, p.y, p.z - oz] = waterSafeMaterial(block, at: p)
    }
    // Water placed by the player can melt a neighboring snow face too.
    for (p, block) in edits where block.isLiquid {
      for offset in VoxelMesher.offsets {
        let q = p + offset
        if chunk[q.x-ox, q.y, q.z-oz] == .snow { chunk[q.x-ox, q.y, q.z-oz] = .sand }
      }
    }
    return chunk
  }

  public func spawn() -> SIMD3<Float> {
    for ring in 0...3 {
      for x in -ring...ring {
        for z in -ring...ring where max(abs(x), abs(z)) == ring {
          if let site = SettlementGenerator.site(in: .init(x, z), terrain: self), site.habitat != .aquatic {
            return [Float(site.x) + 0.5, Float(site.floor) + 0.02, Float(site.z) + 0.5]
          }
        }
      }
    }
    for ring in stride(from: 0, through: 768, by: 2) {
      for edge in stride(from: -ring, through: ring, by: 2) {
        for (x, z) in [(edge, -ring), (edge, ring), (-ring, edge), (ring, edge)] {
          let h = height(atX: x, z: z)
          guard h > Self.seaLevel + 1 else { continue }
          let feet = BlockPosition(x, h + 1, z)
          if block(at: feet) == .air && block(at: feet + .init(0, 1, 0)) == .air
            && block(at: feet + .init(0, -1, 0)).isSolid
          {
            return [Float(x) + 0.5, Float(h + 1) + 0.01, Float(z) + 0.5]
          }
        }
      }
    }
    return [0.5, 40, 0.5]
  }
}

public struct TerrainColumn: Sendable {
  public let height: Int
  public let surface: Block
  public let water: WaterBody?
}
