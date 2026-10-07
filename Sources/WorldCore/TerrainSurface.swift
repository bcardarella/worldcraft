import Foundation

/// Heightfields sample the generator directly: no underground cells or cave
/// evaluation. Buildings and tree crowns are separate solid silhouette meshes.
public enum TerrainSurface {
  public static func build(
    _ tile: TerrainTile, terrain: TerrainGenerator,
    edits: [BlockPosition: Block] = [:], measureError: Bool = true
  ) -> (mesh: VoxelMesh, water: WaterGeometry, profile: TerrainSurfaceProfile?) {
    let result = prepare(tile,terrain:terrain,edits:edits,measureError:measureError,captureGrid:false)
    return (result.mesh,result.water,result.profile)
  }

  public static func buildRetained(_ tile: TerrainTile, terrain: TerrainGenerator,
    edits: [BlockPosition: Block] = [:], measureError: Bool = true
  ) -> (mesh: VoxelMesh, water: WaterGeometry, profile: TerrainSurfaceProfile?, grid: TerrainSurfaceGrid?) {
    prepare(tile,terrain:terrain,edits:edits,measureError:measureError,captureGrid:true)
  }

  private static func prepare(_ tile: TerrainTile, terrain: TerrainGenerator,
    edits: [BlockPosition: Block], measureError: Bool, captureGrid: Bool
  ) -> (mesh: VoxelMesh, water: WaterGeometry, profile: TerrainSurfaceProfile?, grid: TerrainSurfaceGrid?) {
    precondition(!tile.fullDetail)
    let step = tile.sampleStride
    let width = tile.blockSize
    let side = width / step + 1
    let ox = tile.x * 16
    let oz = tile.z * 16
    let source = Sampler(tile: tile, terrain: terrain)
    let sites = source.sites, roads = source.roads, marinas = source.marinas, landmarks = source.landmarks
    var columns: [TerrainColumn] = []
    columns.reserveCapacity(side * side)
    var heights: [Float] = []
    var blocks: [Block] = []
    heights.reserveCapacity(side * side)
    blocks.reserveCapacity(side * side)
    for z in 0..<side {
      if Task.isCancelled { return (VoxelMesh(), .init(), nil, nil) }
      for x in 0..<side {
        let sample = source.column(ox + x * step, oz + z * step)
        columns.append(sample.column); heights.append(sample.height); blocks.append(sample.block)
      }
    }
    let measured = measureError ? TerrainSurfaceProfile.measure(tile: tile, heights: heights) {
      source.column(ox + $0, oz + $1).height
    } : nil
    var mesh = VoxelMesh()
    var groundMaterials: [Block] = []
    if captureGrid { groundMaterials.reserveCapacity((side-1)*(side-1)) }
    func point(_ x: Int, _ z: Int) -> SIMD3<Float> {
      [Float(x * step), heights[z * side + x], Float(z * step)]
    }
    for z in 0..<(side - 1) {
      for x in 0..<(side - 1) {
        let a = point(x, z)
        var b = point(x, z + 1)
        var c = point(x + 1, z + 1)
        var d = point(x + 1, z)
        if tile.retainsBlockSurface { b.y = a.y; c.y = a.y; d.y = a.y }
        // Average both triangles; unlike the old LOD these slopes light correctly.
        let normal = normalized(cross(b - a, c - a) + cross(c - a, d - a))
        let neighbors = [z*side+x, (z+1)*side+x, (z+1)*side+x+1, z*side+x+1]
        let wetLine = neighbors.compactMap { columns[$0].water?.snowLine }.max() ?? -.infinity
        let source = blocks[z * side + x]
        // A coarse slope crosses several columns. A snowy upper corner must
        // not paint the lake bed at its lower corners with the same texture.
        let material: Block = source == .snow && min(a.y, b.y, c.y, d.y)-1 < wetLine ? .sand : source
        if captureGrid { groundMaterials.append(material) }
        mesh.appendQuad([a, b, c, d], normal: normal, block: material, face: 2, materialIndex: 0)
      }
    }
    if tile.retainsBlockSurface {
      // Keep half-metre block tops and cliff steps through the middle distance.
      // Only exposed walls are emitted; there is no underground voxel volume.
      for z in 0..<(side - 1) {
        for x in 0..<(side - 1) {
          let h = heights[z * side + x]
          for (dx, dz, positive, negative) in [(1, 0, 0, 1), (0, 1, 4, 5)] {
            let neighbor = (z + dz) * side + x + dx
            let other = heights[neighbor]
            guard h != other else { continue }
            let face = h > other ? positive : negative
            let block = blocks[h > other ? z * side + x : neighbor]
            let minimum = SIMD3<Float>(Float((x + dx) * step), min(h, other), Float((z + dz) * step))
            let size = SIMD3<Float>(dx == 0 ? Float(step) : 0, abs(h - other), dz == 0 ? Float(step) : 0)
            let direction = VoxelMesher.offsets[face]
            let normal = SIMD3<Float>(Float(direction.x), 0, Float(direction.z))
            if block == .snow {
              // Snow is a surface layer, never a full cliff or underwater wall.
              let wetLine = max(columns[z*side+x].water?.snowLine ?? -.infinity,
                columns[neighbor].water?.snowLine ?? -.infinity)
              let capBottom = max(minimum.y, max(h, other)-1, wetLine)
              if capBottom > minimum.y {
                let rockSize = SIMD3<Float>(size.x, min(size.y, capBottom-minimum.y), size.z)
                mesh.appendQuad(VoxelMesher.corners[face].map { minimum+$0*rockSize },
                  normal: normal, block: .stone, face: face, materialIndex: 0)
              }
              if capBottom < max(h, other) {
                let cap = SIMD3<Float>(minimum.x, capBottom, minimum.z)
                let capSize = SIMD3<Float>(size.x, max(h, other)-capBottom, size.z)
                mesh.appendQuad(VoxelMesher.corners[face].map { cap+$0*capSize },
                  normal: normal, block: .snow, face: face, materialIndex: 0)
              }
            } else {
              mesh.appendQuad(VoxelMesher.corners[face].map { minimum + $0 * size },
                normal: normal, block: block, face: face, materialIndex: 0)
            }
          }
        }
      }
    }
    func skirt(_ a: SIMD3<Float>, _ b: SIMD3<Float>, block: Block, face: Int) {
      let bottom = min(a.y, b.y) - Float(max(32, step * 4))
      let d = VoxelMesher.offsets[face]
      mesh.appendQuad(
        [[a.x, bottom, a.z], a, b, [b.x, bottom, b.z]],
        normal: [Float(d.x), 0, Float(d.z)], block: block == .snow ? .stone : block,
        face: face, materialIndex: 0)
    }
    for i in 0..<(side - 1) {
      skirt(point(0, i + 1), point(0, i), block: blocks[i * side], face: 1)
      skirt(point(side - 1, i), point(side - 1, i + 1), block: blocks[i * side + side - 1], face: 0)
      skirt(point(i, 0), point(i + 1, 0), block: blocks[i], face: 5)
      skirt(
        point(i + 1, side - 1), point(i, side - 1), block: blocks[(side - 1) * side + i], face: 4)
    }
    let canopy = appendTrees(to: &mesh, tile: tile, terrain: terrain, sites: sites, landmarks: landmarks,
      roads:roads,marinas:marinas, measureError: measureError)
    mesh.append(MarinaMesher.build(tile,sites:marinas))
    for landmark in landmarks { appendLandmark(to: &mesh, tile: tile, landmark: landmark) }
    for site in sites { appendBuildings(to: &mesh, tile: tile, site: site, terrain: terrain) }
    mesh.append(SportsGroundMesher.build(tile, sites: sites, edits: edits))
    for road in roads {
      // Coarse and detailed road meshes share the same grade and bridge deck.
      // Settlements supply their own broader grid; landmarks reserve their land.
      let center=(road.a+road.b)/2
      guard !sites.contains(where:{$0.contains(.init(center))}),
        !landmarks.contains(where:{$0.contains(x:Int(center.x),z:Int(center.z))}) else {continue}
      let delta=road.b-road.a,length=sqrt(delta.x*delta.x+delta.z*delta.z)
      guard length>0.01 else {continue}
      let side=SIMD3<Float>(-delta.z,0,delta.x)/length*(road.kind.halfWidth+1)
      let origin=SIMD3<Float>(Float(ox),0,Float(oz))
      let a=road.a-origin+[0,0.06,0],b=road.b-origin+[0,0.06,0]
      let normal=normalized(cross(b-a,side))
      var points=[a-side,b-side,b+side,a+side].map {componentMax([0,$0.y,0],componentMin($0,[Float(width),$0.y,Float(width)]))}
      if normal.y<0 {points.reverse()}
      if sqrt(pow(points[1].x-points[0].x,2)+pow(points[1].z-points[0].z,2)) > 0.01,
        sqrt(pow(points[3].x-points[0].x,2)+pow(points[3].z-points[0].z,2)) > 0.01 {
        mesh.appendQuad(points,normal:normal.y<0 ? -normal:normal,block:road.kind == .path ? .dirt:.basalt,face:2)
      }
    }
    // Player-built structures stay visible beyond the voxel radius. Air edits
    // remain exact inside that radius; a heightfield cannot represent tunnels.
    // Dictionary insertion/worker order must not change serialized geometry.
    // Filter before sorting so large batches of excavation edits stay cheap.
    let additions = edits.filter { tile.contains($0.key.chunk) && $0.value.isSolid }.sorted {
      ($0.key.x, $0.key.y, $0.key.z) < ($1.key.x, $1.key.y, $1.key.z)
    }
    for (p, block) in additions {
      let i =
        min(side - 1, max(0, (p.z - oz) / step)) * side + min(side - 1, max(0, (p.x - ox) / step))
      guard Float(p.y + 1) > heights[i] else { continue }
      box(
        &mesh, minimum: [Float(p.x - ox), Float(p.y), Float(p.z - oz)],
        maximum: [Float(p.x - ox + 1), Float(p.y + 1), Float(p.z - oz + 1)],
        block: terrain.waterSafeMaterial(block, at: p),
        includeBottom: true)
    }
    let water = WaterGeometry.surface(tile, columns: columns, terrain: terrain, heights: heights)
    // Bounds include explicit skyline, trees and raised player structures as
    // well as the reference samples. Skirts only make the bound conservative.
    let profile = measured.map {
      TerrainSurfaceProfile(minimumY: min($0.minimumY, canopy.minimumY, mesh.positions.lazy.map(\.y).min() ?? $0.minimumY),
        maximumY: max($0.maximumY, canopy.maximumY, mesh.positions.lazy.map(\.y).max() ?? $0.maximumY),
        sampledHeightError: $0.sampledHeightError, sampleCount: $0.sampleCount, groupedCanopyExtent: canopy.extent)
    }
    return (mesh, water, profile, captureGrid ? .init(tile:tile,heights:heights,materials:groundMaterials) : nil)
  }

  /// Shared elevation rules; tools can independently probe non-grid positions
  /// without constructing geometry. All metadata is local immutable work data.
  struct Sampler {
    let terrain: TerrainGenerator
    let sites: [Settlement]
    let roads: [RoadSegment]
    let marinas: [Marina]
    let landmarks: [WorldLandmark]
    let natural: TerrainColumnSampler
    init(tile: TerrainTile, terrain: TerrainGenerator) {
      self.terrain = terrain
      let ox = tile.x * 16, oz = tile.z * 16, width = tile.blockSize
      sites = TerrainSurface.settlements(tile, terrain: terrain)
      roads = WorldRoads.segments(x: ox, z: oz, width: width, terrain: terrain)
      marinas = MarinaGenerator.sites(x: ox, z: oz, width: width, terrain: terrain)
      natural = TerrainColumnSampler(x: ox, z: oz, width: width, terrain: terrain, marinas: marinas)
      landmarks = terrain.landmarks.filter { $0.x + $0.halfX >= ox && $0.x - $0.halfX <= ox + width
        && $0.z + $0.halfZ >= oz && $0.z - $0.halfZ <= oz + width }
    }
    // Geometry and its error probe share exactly the same road, marina and
    // settlement elevations. The probe must not measure a different world.
    func column(_ wx: Int, _ wz: Int) -> (column: TerrainColumn, height: Float, block: Block) {
      let column = natural.column(atX: wx, z: wz)
      if let marina = marinas.first(where: { $0.contains(x: wx, z: wz) }),
        let block = marina.block(at: .init(wx, marina.floor - 1, wz), natural: column.height),
        block.isSolid, marina.local(x: wx, z: wz).y >= 0 {
        return (.init(height: marina.floor - 1, surface: block, water: nil), Float(marina.floor), block)
      }
      if let landmark = landmarks.first(where: { $0.contains(x: wx, z: wz) }) {
        let level = landmark.surface(x: wx, z: wz, natural: column.height)
        let block = landmark.ground(x: wx, z: wz)
        return (.init(height: level - 1, surface: block, water: nil), Float(level), block)
      }
      if let site = sites.first(where: { $0.contains(.init(wx, 0, wz)) }) {
        return (column, Float(site.floor), site.block(at: .init(wx, site.floor - 1, wz), terrain: terrain) ?? site.ground)
      }
      let road = WorldRoads.sample(x: wx, z: wz, segments: roads)
      return (column, Float(column.water == nil ? road?.floor ?? (column.height + 1) : column.height + 1),
        column.water == nil ? road?.surface ?? column.surface : column.surface)
    }
  }

  private static func settlements(_ tile: TerrainTile, terrain: TerrainGenerator) -> [Settlement] {
    let ox = tile.x * 16
    let oz = tile.z * 16
    let regions = SettlementGenerator.regionSize
    var result: [Settlement] = []
    for z in floorDivide(oz, by: regions)...floorDivide(oz + tile.blockSize, by: regions) {
      for x in floorDivide(ox, by: regions)...floorDivide(ox + tile.blockSize, by: regions) {
        if let site = SettlementGenerator.site(in: .init(x, z), terrain: terrain),
          site.x + site.radius > ox && site.x - site.radius < ox + tile.blockSize,
          site.z + site.radius > oz && site.z - site.radius < oz + tile.blockSize
        {
          result.append(site)
        }
      }
    }
    return result
  }

  private struct CanopyProfile {
    var minimumY: Float = .infinity, maximumY: Float = -.infinity, extent: Float = 0
    mutating func include(low: SIMD3<Float>, high: SIMD3<Float>, width: Float) {
      let a = componentMax(low, [0,Float(ChunkData.minimumY),0])
      let b = componentMin(high, [width,Float(ChunkData.height),width])
      guard b.x > a.x, b.y > a.y, b.z > a.z else { return }
      let delta = b - a
      extent = max(extent, (delta.x*delta.x + delta.y*delta.y + delta.z*delta.z).squareRoot())
      minimumY = min(minimumY,a.y); maximumY = max(maximumY,b.y)
    }
  }

  private static func appendTrees(
    to mesh: inout VoxelMesh, tile: TerrainTile,
    terrain: TerrainGenerator, sites: [Settlement], landmarks: [WorldLandmark], roads:[RoadSegment],marinas:[Marina],
    measureError: Bool
  ) -> CanopyProfile {
    guard terrain.style != .solar && terrain.style != .dune && terrain.style != .ember else {
      return .init()
    }
    let ox = tile.x * 16
    let oz = tile.z * 16
    let width = tile.blockSize
    // The farthest canopy uses bounded groups of real trees. Maxima preserve
    // tall spruce silhouettes instead of sampling between narrow trunks.
    let grouping = tile.size >= 8 ? tile.size : 1
    struct Crown {
      var low: SIMD3<Float>
      var high: SIMD3<Float>
      var tree: TreeDescriptor
      var referenceMinimumY: Float
    }
    var crowns: [Int: Crown] = [:]
    for tree in TerrainTreePlans.trees(x: (ox - 4)..<(ox + width + 4), z: (oz - 4)..<(oz + width + 4),
      terrain: terrain, order: .zThenX) {
      if Task.isCancelled { return .init() }
      let x = tree.x, z = tree.z
      guard !sites.contains(where: { $0.contains(.init(x, 0, z)) }),
        !landmarks.contains(where: { $0.contains(x:x,z:z) }),
        !marinas.contains(where: { $0.contains(x:x,z:z) }),
        WorldRoads.sample(x:x,z:z,segments:roads) == nil
      else { continue }
      let radius: Float = tree.species == .birch ? 2
        : ([TreeSpecies.willow, .palm, .acacia].contains(tree.species) ? 4 : 3)
      let low = SIMD3<Float>(Float(x - ox) - radius, Float(tree.top - 1), Float(z - oz) - radius)
      let high = SIMD3<Float>(
        Float(x - ox) + radius + 1, Float(tree.top + 3), Float(z - oz) + radius + 1)
      if grouping == 1 {
        clippedBox(
          &mesh, tile: tile,
          low: [Float(x - ox), Float(tree.ground + 1), Float(z - oz)],
          high: [Float(x - ox + 1), Float(tree.top), Float(z - oz + 1)], block: tree.trunk)
        if tree.species == .spruce || tree.species == .redwood {
          for tier in 0..<3 {
            let r = Float(3 - tier)
            clippedBox(
              &mesh, tile: tile,
              low: [Float(x - ox) - r, Float(tree.ground + 3 + tier * 4), Float(z - oz) - r],
              high: [
                Float(x - ox) + r + 1, Float(tree.top - 5 + tier * 4), Float(z - oz) + r + 1,
              ], block: tree.leaves, includeBottom: tier == 0)
          }
        } else if tree.species == .palm {
          for axis in 0..<2 {
            let spread: SIMD3<Float> = axis == 0 ? [4, 0, 1] : [1, 0, 4]
            let center = SIMD3<Float>(Float(x - ox), Float(tree.top), Float(z - oz))
            clippedBox(&mesh, tile: tile, low: center - spread, high: center + spread + [1, 2, 1],
              block: tree.leaves, includeBottom: true)
          }
        } else {
          clippedBox(
            &mesh, tile: tile, low: low, high: high - [0, 1, 0], block: tree.leaves,
            includeBottom: true)
          clippedBox(
            &mesh, tile: tile, low: low + [1, 3, 1], high: high + [-1, 0, -1], block: tree.leaves)
        }
      } else {
        let gx = floorDivide(x - ox, by: grouping)
        let gz = floorDivide(z - oz, by: grouping)
        let key = (gz + 1) * (width / grouping + 2) + gx + 1
        let crownLow =
          (tree.species == .spruce || tree.species == .redwood)
          ? SIMD3<Float>(low.x, Float(tree.ground + 7), low.z) : low
        if var crown = crowns[key] {
          crown.low = componentMin(crown.low, crownLow)
          crown.high = componentMax(crown.high, high)
          crown.referenceMinimumY = min(crown.referenceMinimumY, Float(tree.ground + 1))
          if tree.top > crown.tree.top { crown.tree = tree }
          crowns[key] = crown
        } else {
          crowns[key] = .init(low: crownLow, high: high, tree: tree, referenceMinimumY: Float(tree.ground + 1))
        }
      }
    }
    var profile = CanopyProfile()
    for key in crowns.keys.sorted() {
      let crown = crowns[key]!
      if measureError {
        // The common box contains every fine trunk/species crown and both
        // emitted group boxes. Its diameter bounds the spatial support of any
        // silhouette change, not its actual Hausdorff or screen-pixel error.
        profile.include(low: [crown.low.x, min(crown.low.y,crown.referenceMinimumY), crown.low.z],
          high: crown.high, width: Float(width))
      }
      let mid = crown.low.y + (crown.high.y - crown.low.y) * 0.65
      clippedBox(
        &mesh, tile: tile, low: crown.low, high: [crown.high.x, mid, crown.high.z],
        block: crown.tree.leaves, includeBottom: true)
      clippedBox(
        &mesh, tile: tile, low: [crown.low.x + 1, mid, crown.low.z + 1],
        high: crown.high - [1, 0, 1], block: crown.tree.leaves)
    }
    return profile
  }

  private static func appendBuildings(
    to mesh: inout VoxelMesh, tile: TerrainTile,
    site: Settlement, terrain: TerrainGenerator
  ) {
    let ox = tile.x * 16
    let oz = tile.z * 16
    // Visit only parcels overlapping this tile. A far larger city should not
    // make every terrain tile scan every building in the whole settlement.
    let rangeX = floorDivide(ox-site.x,by:site.spacing)...floorDivide(ox+tile.blockSize-1-site.x,by:site.spacing)
    let rangeZ = floorDivide(oz-site.z,by:site.spacing)...floorDivide(oz+tile.blockSize-1-site.z,by:site.spacing)
    for lz in rangeZ {
      for lx in rangeX {
        guard abs(lx * site.spacing + site.spacing / 2) <= site.radius - site.spacing / 2,
          abs(lz * site.spacing + site.spacing / 2) <= site.radius - site.spacing / 2
        else { continue }
        guard let building = site.building(lotX: lx, lotZ: lz, terrain: terrain) else { continue }
        let minimum = building.minimum, maximum = building.maximum
        let hash = building.hash
        let x = site.x + lx * site.spacing
        let z = site.z + lz * site.spacing
        let h = building.height
        let low = SIMD3<Float>(Float(x + minimum - ox), Float(site.floor), Float(z + minimum - oz))
        let high = SIMD3<Float>(
          Float(x + maximum + 1 - ox), Float(site.floor + h + 1), Float(z + maximum + 1 - oz))
        clippedBox(&mesh, tile: tile, low: low, high: high, block: building.wall)
        if building.aquatic {
          for ring in 0...3 {
            clippedBox(&mesh, tile: tile,
              low: [low.x + Float(ring), high.y - 1 + Float(ring), low.z + Float(ring)],
              high: [high.x - Float(ring), high.y + Float(ring), high.z - Float(ring)], block: building.roof)
          }
        } else if building.roofRise > 0 {
          // Stepped pitched roofs preserve the quaint village skyline.
          for ridge in 0...((maximum - minimum) / 2) {
            let rise = building.roofHeight(inset: ridge)
            clippedBox(
              &mesh, tile: tile, low: [low.x + Float(ridge), high.y + Float(rise) - (building.style == .alpine ? 2 : 1), low.z],
              high: [high.x - Float(ridge), high.y + Float(rise), high.z], block: building.roof)
          }
        } else {
          clippedBox(
            &mesh, tile: tile, low: [low.x, high.y - 1, low.z], high: high,
            block: building.roof)
          if building.solar {
            let middle=(low+high)/2
            func roofBox(_ a:SIMD3<Float>,_ b:SIMD3<Float>,_ block:Block = .basalt) {
              clippedBox(&mesh,tile:tile,low:a,high:b,block:block)
            }
            if building.style == .sunSpire {
              for rise in 1...7 {let half=Float(8-rise)*0.7
                roofBox([middle.x-half,high.y+Float(rise-1),middle.z-half],
                  [middle.x+half,high.y+Float(rise),middle.z+half],rise==7 ? .lamp:.basalt)
              }
            } else if building.style == .forge {
              for cx in [low.x+2,high.x-3] {
                roofBox([cx,high.y,high.z-3],[cx+1,high.y+4,high.z-2])
                roofBox([cx,high.y+4,high.z-3],[cx+1,high.y+5,high.z-2],.lamp)
              }
            } else {
              let inset:Float=building.style == .furnace ? 2:building.style == .caldera ? 3:0
              let a=low+[inset,0,inset],b=high-[inset,0,inset]
              let top=high.y+(building.style == .furnace ? 6:3)
              roofBox([a.x,high.y,a.z],[b.x,top,a.z+1])
              roofBox([a.x,high.y,b.z-1],[b.x,top,b.z])
              roofBox([a.x,high.y,a.z+1],[a.x+1,top,b.z-1])
              roofBox([b.x-1,high.y,a.z+1],[b.x,top,b.z-1])
              if building.style == .caldera {roofBox([a.x+1,high.y,a.z+1],[b.x-1,high.y+1,b.z-1],.lamp)}
            }
          }
          if building.style == .artDeco {
            clippedBox(&mesh, tile: tile, low: [low.x + 2, high.y, low.z + 2],
              high: [high.x - 2, high.y + 4, high.z - 2], block: building.frame)
          }
          // Opaque window bands keep tower identity without distant glass overdraw.
          let storey = building.storey
          for y in stride(from: site.floor + 2, to: site.floor + h, by: storey) {
            clippedBox(
              &mesh, tile: tile, low: [low.x - 0.01, Float(y), low.z - 0.01],
              high: [high.x + 0.01, Float(min(y + 3, site.floor + h)), high.z + 0.01],
              block: building.solar ? .brick:(hash + UInt64((y - site.floor) / storey)) % 4 == 0 ? .lamp : .glass)
          }
        }
      }
    }
  }

  private static func appendLandmark(to mesh: inout VoxelMesh, tile: TerrainTile, landmark: WorldLandmark) {
    let origin = landmark.center - SIMD3<Float>(Float(tile.x*16),0,Float(tile.z*16))
    func add(_ low: SIMD3<Float>, _ high: SIMD3<Float>, _ block: Block) {
      clippedBox(&mesh,tile:tile,low:origin+low,high:origin+high,block:block)
    }
    if landmark.kind == .circuit {
      let z=landmark.circuit.pitZ
      add([-38,5,z-5],[39,6,z+7],.brick)
      add([-38,0,z+6],[39,5,z+7],.stone)
      return
    }
    add([-26,0,-26],[27,19,27],.limestone)
    add([-26,18,-26],[27,19,27],.wood)
    for x: Float in [-29,29] { for z: Float in [-29,29] {
      add([x-5,0,z-5],[x+6,22,z+6],.limestone)
      for tier in 0..<5 { let r = Float(5-tier)
        add([x-r,Float(22+tier),z-r],[x+r+1,Float(23+tier),z+r+1],landmark.variant % 2 == 0 ? .coral : .brick)
      }
    } }
    add([-32,0,-32],[33,10,-31],.stone)
    add([-32,0,32],[-21,10,33],.stone)
    add([-14,0,32],[33,10,33],.stone)
    for x: Float in [-32,32] { add([x,0,-32],[x+1,10,33],.stone) }
  }

  private static func clippedBox(
    _ mesh: inout VoxelMesh, tile: TerrainTile,
    low: SIMD3<Float>, high: SIMD3<Float>, block: Block, includeBottom: Bool = false
  ) {
    let a = componentMax(low, [0, Float(ChunkData.minimumY), 0])
    let b = componentMin(
      high, [Float(tile.blockSize), Float(ChunkData.height), Float(tile.blockSize)])
    guard b.x > a.x && b.y > a.y && b.z > a.z else { return }
    box(&mesh, minimum: a, maximum: b, block: block, includeBottom: includeBottom)
  }

  static func box(
    _ mesh: inout VoxelMesh, minimum: SIMD3<Float>, maximum: SIMD3<Float>, block: Block,
    includeBottom: Bool = false
  ) {
    for face in 0..<6 where face != 3 || includeBottom {
      let d = VoxelMesher.offsets[face]
      mesh.appendQuad(
        VoxelMesher.corners[face].map { minimum + $0 * (maximum - minimum) },
        normal: [Float(d.x), Float(d.y), Float(d.z)], block: block, face: face,
        materialIndex: block == .lava ? 5 : (block == .lamp ? 3 : 0))
    }
  }
}

func componentMin(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
  [min(a.x, b.x), min(a.y, b.y), min(a.z, b.z)]
}
func componentMax(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
  [max(a.x, b.x), max(a.y, b.y), max(a.z, b.z)]
}
func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
  [a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x]
}
func normalized(_ a: SIMD3<Float>) -> SIMD3<Float> {
  a / max(0.00001, sqrt(a.x * a.x + a.y * a.y + a.z * a.z))
}
