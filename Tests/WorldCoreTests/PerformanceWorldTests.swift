import XCTest

@testable import WorldCore

final class PerformanceWorldTests: XCTestCase {
  func testKilometreHorizonHasBoundedVoxelStorageAndTileCount() {
    let center = ChunkCoordinate(-17, 25)
    let plan = TerrainStreamingPlan(center: center, radius: 128)
    XCTAssertEqual(plan.tiles.filter(\.fullDetail).count, 317)
    XCTAssertLessThan(plan.tiles.count, 800)
    XCTAssertGreaterThan(plan.tiles.reduce(0) { $0 + $1.size * $1.size }, 50_000)
    XCTAssertEqual(DrawDistance.range.upperBound * 16, Int(WorldScale.blocks(1_024)))
    let tiles = Array(plan.tiles)
    for i in tiles.indices {
      XCTAssertEqual(tiles[i].x % tiles[i].size, 0)
      XCTAssertEqual(tiles[i].z % tiles[i].size, 0)
      for j in (i + 1)..<tiles.count { XCTAssertFalse(tiles[i].overlaps(tiles[j])) }
    }
    for z in -128...128 {
      for x in -128...128 where x * x + z * z <= 128 * 128 {
        let coordinate = ChunkCoordinate(center.x + x, center.z + z)
        XCTAssertTrue(tiles.contains(where: { $0.contains(coordinate) }))
      }
    }
  }

  func testTilesStayStableAcrossMovementAndNegativeCoordinates() {
    let a = TerrainStreamingPlan(center: .init(-1, -1), radius: 128).tiles
    let b = TerrainStreamingPlan(center: .init(-2, -1), radius: 128).tiles
    XCTAssertEqual(a, b)  // No LOD churn while moving inside an anchor cell.
    XCTAssertEqual(a, TerrainStreamingPlan(center: .init(-1, -1), radius: 128).tiles)
    let small = TerrainStreamingPlan(center: .init(0, 0), radius: 4).tiles
    XCTAssertEqual(small.count, 49)
    XCTAssertTrue(small.allSatisfy(\.fullDetail))
  }

  func testStreamingBufferKeepsTheNextFlightChunkAvailable() {
    let oldAnchor = ChunkCoordinate(2, 2)
    for z in 0...4 {
      for x in 0...4 {
        let center = ChunkCoordinate(x, z)
        let anchor = TerrainStreamingPlan.anchor(for: center, radius: 128, previous: oldAnchor)
        XCTAssertEqual(anchor, oldAnchor)
        let plan = TerrainStreamingPlan(center: anchor, radius: 128)
        for dz in -1...1 {
          for dx in -1...1 {
            let ahead = ChunkCoordinate(x + dx, z + dz)
            XCTAssertTrue(plan.tiles.contains(where: { $0.fullDetail && $0.contains(ahead) }))
          }
        }
      }
    }
    let next = TerrainStreamingPlan.anchor(for: .init(5, 2), radius: 128, previous: oldAnchor)
    XCTAssertEqual(next, .init(6, 2))
    XCTAssertEqual(TerrainStreamingPlan.anchor(for: .init(4, 2), radius: 128, previous: next), next)
    XCTAssertEqual(
      TerrainStreamingPlan.anchor(for: .init(3, 2), radius: 128, previous: next), oldAnchor)
  }

  func testCoverageNeverDropsParentBeforeAllChildrenArrive() {
    let parent = TerrainTile(x: -4, z: 0, size: 4)
    let children: Set<TerrainTile> = [
      .init(x: -4, z: 0, size: 2), .init(x: -2, z: 0, size: 2),
      .init(x: -4, z: 2, size: 2), .init(x: -2, z: 2, size: 2),
    ]
    let partial = TerrainCoverage(desired: children, available: [parent, children.first!])
    XCTAssertEqual(partial.visible, [parent])
    XCTAssertTrue(partial.retired.isEmpty)
    let complete = TerrainCoverage(desired: children, available: children.union([parent]))
    XCTAssertEqual(complete.visible, children)
    XCTAssertEqual(complete.retired, [parent])
    let merging = TerrainCoverage(desired: [parent], available: children)
    XCTAssertEqual(merging.visible, children)
    let merged = TerrainCoverage(desired: [parent], available: children.union([parent]))
    XCTAssertEqual(merged.visible, [parent])
    XCTAssertEqual(merged.retired, children)
  }

  func testSurfaceMeshesAgreeOnWorldAlignedBorders() {
    let terrain = TerrainGenerator(seed: 8192)
    let left = TerrainTile(x: -16, z: -8, size: 8)
    let right = TerrainTile(x: -8, z: -8, size: 8)
    let a = TerrainSurface.build(left, terrain: terrain).mesh
    let b = TerrainSurface.build(right, terrain: terrain).mesh
    let side = left.blockSize / left.sampleStride
    // Surface quads precede skirts and silhouettes in each mesh.
    for row in 0..<side {
      let i = (row * side + side - 1) * 4
      let j = row * side * 4
      XCTAssertEqual(a.positions[i + 3] + left.origin, b.positions[j] + right.origin)
      XCTAssertEqual(a.positions[i + 2] + left.origin, b.positions[j + 1] + right.origin)
    }
    XCTAssertTrue(a.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    XCTAssertTrue(a.normals.allSatisfy { abs(dot($0, $0) - 1) < 0.001 })
    XCTAssertTrue(a.indices.allSatisfy { Int($0) < a.positions.count })
  }

  func testDistantSilhouettesKeepTreeTopsRoofsAndPlayerStructures() {
    let terrain = TerrainGenerator(seed: 8192)
    let home = SettlementGenerator.site(in: .init(0, 0), terrain: terrain)!
    let tile = TerrainTile(
      x: floorDivide(home.x, by: 128) * 8, z: floorDivide(home.z, by: 128) * 8, size: 8)
    let normal = TerrainSurface.build(tile, terrain: terrain).mesh
    let side = tile.blockSize / tile.sampleStride
    let groundAndSkirts = side * side + side * 4
    XCTAssertGreaterThan(normal.faceCount, groundAndSkirts)
    // The horizon uses the same regional roof materials as nearby buildings.
    let tiles = Set(
      normal.textureCoordinates.map { uv in Int(uv.x * 16) + min(7, Int((1 - uv.y) * 8)) * 16 }.map
      { $0 % 32 })
    let roofs = (-2...2).flatMap { x in (-2...2).compactMap { z in
      home.building(lotX: x, lotZ: z, terrain: terrain)?.roof.tile(face: 2)
    } }
    XCTAssertFalse(roofs.isEmpty)
    XCTAssertTrue(roofs.contains(where: tiles.contains))
    let built = BlockPosition(tile.x * 16 + 12, 110, tile.z * 16 + 12)
    let edited = TerrainSurface.build(tile, terrain: terrain, edits: [built: .snow]).mesh
    XCTAssertTrue(edited.positions.contains { $0 == SIMD3<Float>(12, 111, 12) })
    XCTAssertTrue(
      zip(edited.positions, edited.normals).contains {
        $0.0 == SIMD3<Float>(12, 110, 12) && $0.1 == SIMD3<Float>(0, -1, 0)
      }, "Distant floating constructions must also be visible from below")
  }

  func testPackedMeshLayoutBoundsAndMaterialsMatchSource() {
    var source = VoxelMesh()
    source.appendBox(size: [2, 3, 4], center: [-3, 9, 2], material: 0)
    source.appendBox(size: [1, 1, 1], center: [5, 6, 7], material: 3)
    let packed = PackedTerrainMesh(source)
    XCTAssertEqual(MemoryLayout<TerrainVertex>.stride, 40)
    XCTAssertEqual(MemoryLayout<TerrainVertex>.offset(of: \.u), 12)
    XCTAssertEqual(MemoryLayout<TerrainVertex>.offset(of: \.normal), 16)
    XCTAssertEqual(MemoryLayout<TerrainVertex>.offset(of: \.tangent), 24)
    XCTAssertEqual(MemoryLayout<TerrainVertex>.offset(of: \.bitangent), 32)
    XCTAssertEqual(packed.parts.map(\.material), [0, 3])
    XCTAssertEqual(packed.indices.count, source.indices.count)
    for part in packed.parts {
      for index in packed.indices[part.offset..<(part.offset + part.count)] {
        let v = packed.vertices[Int(index)]
        let p = SIMD3(v.px, v.py, v.pz)
        XCTAssertTrue(p.x >= part.minimum.x && p.x <= part.maximum.x)
        XCTAssertTrue(p.y >= part.minimum.y && p.y <= part.maximum.y)
        XCTAssertTrue(p.z >= part.minimum.z && p.z <= part.maximum.z)
        let n = unpack(v.normal)
        let t = unpack(v.tangent)
        let b = unpack(v.bitangent)
        XCTAssertEqual(dot(n, t), 0, accuracy: 0.002)
        XCTAssertEqual(dot(n, b), 0, accuracy: 0.002)
        XCTAssertEqual(dot(t, t), 1, accuracy: 0.002)
      }
    }
    for (i, v) in packed.vertices.enumerated() {
      XCTAssertEqual(
        Float(Float16(bitPattern: v.u)), source.textureCoordinates[i].x, accuracy: 0.00025)
      XCTAssertEqual(
        Float(Float16(bitPattern: v.v)), source.textureCoordinates[i].y, accuracy: 0.00025)
    }
  }

  func testPackedSculptureSupportsAllSevenResidentMaterials() {
    // Resident belts, hats and tools use material 6. This is the same packing
    // path SculptureBuilder calls as soon as the first resident appears.
    var source = VoxelMesh()
    for material: UInt32 in 0..<7 {
      source.appendBox(size: [1, 1, 1], center: [Float(material) * 2, 0, 0], material: material)
    }
    let packed = PackedTerrainMesh(source)
    XCTAssertEqual(packed.parts.map(\.material), Array(0..<7))
    XCTAssertEqual(packed.indices.count, source.indices.count)
    for part in packed.parts {
      XCTAssertEqual(part.count, 36)
      XCTAssertEqual(part.minimum.x, Float(part.material) * 2 - 0.5)
      XCTAssertEqual(part.maximum.x, Float(part.material) * 2 + 0.5)
      XCTAssertTrue(packed.indices[part.offset..<(part.offset + part.count)].allSatisfy {
        abs(packed.vertices[Int($0)].px - Float(part.material) * 2) <= 0.5
      })
    }
  }

  func testPackedSculpturePreservesSparseMaterialIndicesAndEmptyMeshes() {
    var source = VoxelMesh()
    source.appendBox(size: [1, 1, 1], center: .zero, material: 12)
    source.appendBox(size: [1, 1, 1], center: [3, 0, 0], material: 2)
    let packed = PackedTerrainMesh(source)
    XCTAssertEqual(packed.parts.map(\.material), [2, 12])
    XCTAssertEqual(packed.parts.map(\.offset), [0, 36])
    XCTAssertEqual(packed.indices.count, 72)
    let empty = PackedTerrainMesh(VoxelMesh())
    XCTAssertTrue(empty.vertices.isEmpty && empty.indices.isEmpty && empty.parts.isEmpty)
  }

  func testSparseWaterRetainsNearSamplesAndFarGeometryIsBounded() {
    let terrain = TerrainGenerator(seed: 8192)
    var selected: ChunkCoordinate?
    for z in -8...8 {
      for x in -8...8 {
        if terrain.waterBody(atX: x * 16, z: z * 16) != nil {
          selected = .init(x, z)
          break
        }
      }
      if selected != nil { break }
    }
    let chunk = terrain.generate(selected!)
    let patch = WaterPatch.build(chunk, terrain: terrain)
    let water = WaterGeometry(patch)
    XCTAssertEqual(water.shallowIndices.count, patch.shallowIndices.count)
    XCTAssertEqual(water.deepIndices.count, patch.deepIndices.count)
    XCTAssertLessThanOrEqual(water.samples.count, patch.vertexSide * patch.vertexSide)
    for sample in water.samples {
      let i = Int(sample.position.y) * patch.vertexSide + Int(sample.position.x)
      XCTAssertEqual(sample.body, patch.bodies[i])
      XCTAssertEqual(sample.depth, patch.depths[i])
    }
    let far = TerrainTile(x: -32, z: -32, size: 32)
    let result = TerrainSurface.build(far, terrain: terrain).water
    XCTAssertLessThanOrEqual(result.shallowIndices.count + result.deepIndices.count, 16 * 16 * 6)
    XCTAssertTrue(
      (result.shallowIndices + result.deepIndices).allSatisfy { Int($0) < result.samples.count })
  }

  func testLivingWorldVoxelChecksums() {
    // Continental scale and connected drainage intentionally move terrain and
    // settlement elevations. Pin borders and underground voxels for this grammar.
    let fixtures: [(Int, ChunkCoordinate, UInt64)] = [
      (0, .init(8, 8), 15055027213135331468),
      (1, .init(8, 8), 8132249231574245374),
      (2, .init(10, 8), 8361848031801192525),
      (3, .init(8, 8), 12187353128875932582),
      (4, .init(8, 8), 17891208380228048247),
      (5, .init(0, 0), 12067099946231895147),
    ]
    for (style, coordinate, expected) in fixtures {
      let chunk = TerrainGenerator(seed: 8192, style: PlanetStyle(rawValue: style)!).generate(
        coordinate)
      var checksum: UInt64 = 14_695_981_039_346_656_037
      for y in ChunkData.minimumY..<ChunkData.height {
        for z in -1...16 {
          for x in -1...16 {
            checksum = (checksum ^ UInt64(chunk[x, y, z].rawValue)) &* 1_099_511_628_211
          }
        }
      }
      XCTAssertEqual(checksum, expected, "Planet style \(style)")
    }
  }

  func testRiverGeographyIsStableAndWaterBedsRemainSediment() {
    // River valleys intentionally carve the previous terrain. These fixtures
    // pin the revised drainage grammar, while checking underwater sediments.
    let expected: [UInt64] = [11_312_129_360_656_014_130, 13_406_885_429_627_656_092,
      6_861_771_566_547_639_600, 11_443_222_764_554_491_009,
      10_206_054_265_737_709_311, 13_467_491_034_741_455_338]
    for style in PlanetStyle.allCases {
      let terrain = TerrainGenerator(seed: 8192, style: style)
      var checksum: UInt64 = 14_695_981_039_346_656_037
      for z in stride(from: -1_200, through: 1_200, by: 71) {
        for x in stride(from: -1_200, through: 1_200, by: 71) {
          let column = terrain.column(atX: x, z: z)
          let oldSurface: Block = style == .dune ? .sand : style == .frost ? .snow
            : style == .ember || style == .solar ? .stone : column.height <= TerrainGenerator.seaLevel + 1 ? .sand
            : column.height >= 58 ? .snow : column.height >= 49 ? .stone : .grass
          if let water = column.water, Float(column.height) < water.snowLine {
            XCTAssertNotEqual(column.surface, .snow)
          } else { XCTAssertEqual(column.surface, oldSurface) }
          for value in [column.height, Int(oldSurface.rawValue), Int(column.water?.level ?? -99)] {
            checksum = (checksum ^ UInt64(bitPattern: Int64(value))) &* 1_099_511_628_211
          }
        }
      }
      XCTAssertEqual(checksum, expected[style.rawValue], "Planet style \(style)")
    }
  }

  func testFrameTimingUsesUnclampedIntervalsAndFixedWindow() {
    var timing = FrameTiming(capacity: 100)
    for _ in 0..<94 { timing.record(interval: 1.0 / 90, cpuTime: 0.002) }
    for _ in 0..<6 { timing.record(interval: 0.050, cpuTime: 0.020) }
    XCTAssertEqual(timing.snapshot.intervalP95Milliseconds, 50, accuracy: 0.001)
    XCTAssertEqual(timing.snapshot.cpuP95Milliseconds, 20, accuracy: 0.001)
    XCTAssertEqual(timing.snapshot.over60BudgetPercent, 6, accuracy: 0.001)
    for _ in 0..<100 { timing.record(interval: 1.0 / 90, cpuTime: 0.001) }
    XCTAssertEqual(timing.count, 100)
    XCTAssertEqual(timing.snapshot.updateHz, 90, accuracy: 0.001)
    XCTAssertEqual(timing.snapshot.over60BudgetPercent, 0)
    timing.record(interval: .nan, cpuTime: 0)
    XCTAssertEqual(timing.count, 100)
  }

  func testTimingKeepsRareHitchesAndResetsBetweenConsoleWindows() {
    var timing = FrameTiming(capacity: 100)
    for _ in 0..<98 { timing.record(interval: 0.010, cpuTime: 0.001) }
    timing.record(interval: 0.040, cpuTime: 0.005)
    timing.record(interval: 0.080, cpuTime: 0.060)
    let snapshot = timing.snapshot
    XCTAssertEqual(snapshot.seconds, 1.1, accuracy: 0.000_001)
    XCTAssertEqual(snapshot.intervalP95Milliseconds, 10, accuracy: 0.000_001)
    XCTAssertEqual(snapshot.intervalP99Milliseconds, 40, accuracy: 0.000_001)
    XCTAssertEqual(snapshot.intervalMaxMilliseconds, 80, accuracy: 0.000_001)
    XCTAssertEqual(snapshot.cpuMeanMilliseconds, 1.63, accuracy: 0.000_001)
    XCTAssertEqual(snapshot.cpuP99Milliseconds, 5, accuracy: 0.000_001)
    XCTAssertEqual(snapshot.cpuMaxMilliseconds, 60, accuracy: 0.000_001)
    XCTAssertEqual(snapshot.intervalsOver50Milliseconds, 1)
    XCTAssertEqual(snapshot.over60BudgetPercent, 2, accuracy: 0.000_001)
    timing.reset()
    XCTAssertEqual(timing.snapshot.count, 0)
    timing.record(interval: 1.0 / 90, cpuTime: 0.002)
    XCTAssertEqual(timing.snapshot.count, 1)
    XCTAssertEqual(timing.snapshot.updateHz, 90, accuracy: 0.000_001)
    XCTAssertEqual(timing.snapshot.cpuMaxMilliseconds, 2, accuracy: 0.000_001)
    XCTAssertEqual(timing.snapshot.intervalsOver50Milliseconds, 0)
  }

  func testGPUTimeWindowDistinguishesUnmeasuredAndBoundsStorage() {
    var timing = DurationTiming(capacity: 3)
    XCTAssertEqual(timing.snapshot.count, 0)
    XCTAssertNil(timing.snapshot.meanMilliseconds)
    for milliseconds in 1...4 { timing.record(seconds: Double(milliseconds) / 1_000) }
    XCTAssertEqual(timing.snapshot.count, 3)
    XCTAssertEqual(timing.snapshot.meanMilliseconds!, 3, accuracy: 0.000_001)
    XCTAssertEqual(timing.snapshot.p95Milliseconds!, 4, accuracy: 0.000_001)
    XCTAssertEqual(timing.snapshot.maxMilliseconds!, 4, accuracy: 0.000_001)
    timing.record(seconds: .nan)
    timing.record(seconds: .infinity)
    timing.record(seconds: -1)
    XCTAssertEqual(timing.snapshot.meanMilliseconds!, 3, accuracy: 0.000_001)
    timing.reset()
    XCTAssertEqual(timing.snapshot.count, 0)
    XCTAssertNil(timing.snapshot.maxMilliseconds)
    timing.record(seconds: 0.0005)
    XCTAssertEqual(timing.snapshot.meanMilliseconds!, 0.5, accuracy: 0.000_001)
  }

  func testStreamingServicesEveryHealthyFrameAtDifferentRefreshRates() {
    for hz in [72.0, 90, 96, 100, 120] {
      var budget = StreamingBudget()
      for frame in 0..<300 {
        let now = Double(frame) / hz
        XCTAssertTrue(budget.beginFrame(interval: 1 / hz, time: now, urgent: false), "Rate \(hz)")
        budget.published(cpuTime: 0.001, time: now)
      }
    }
  }

  func testUploadBudgetRecoversFromHitchesWithoutStarvingTerrain() {
    var budget = StreamingBudget()
    budget.published(cpuTime: 0.006, time: 0)
    XCTAssertFalse(budget.beginFrame(interval: 1.0 / 90, time: 0.012, urgent: false))
    XCTAssertTrue(budget.beginFrame(interval: 1.0 / 90, time: 0.024, urgent: false))
    budget.published(cpuTime: 0.003, time: 0.024)
    XCTAssertTrue(budget.beginFrame(interval: 0.050, time: 0.050, urgent: true))
    XCTAssertTrue(budget.beginFrame(interval: 0.050, time: 0.075, urgent: false))
    XCTAssertTrue(budget.beginFrame(interval: 0.050, time: 0.150, urgent: false))
    XCTAssertTrue(StreamingBudget.allowsSecondTile(elapsed: 0.0003, bytes: 100_000))
    XCTAssertFalse(StreamingBudget.allowsSecondTile(elapsed: 0.001, bytes: 100_000))
    XCTAssertFalse(StreamingBudget.allowsSecondTile(elapsed: 0.0003, bytes: 800_000))
  }

  func testMoreReadyTilesDoNotRaiseThePublicationTimeOrByteBudgets() {
    for cost in [0.00015, 0.00075, 0.0012] {
      for urgent in [false, true] {
        var counts: [Int] = []
        for limit in [4, 8] {
          var budget = StreamingBudget(maximumTiles: limit)
          for _ in 0..<100 { budget.recordTile(seconds: cost) }
          var tiles = 0, elapsed = 0.0
          while budget.allowsNextTile(elapsed: elapsed, published: tiles, bytes: tiles * 100_000, urgent: urgent) {
            tiles += 1; elapsed += cost; budget.recordTile(seconds: cost)
          }
          XCTAssertLessThanOrEqual(elapsed, urgent ? 0.0025 : 0.0022)
          XCTAssertLessThanOrEqual(tiles, limit)
          XCTAssertFalse(budget.allowsNextTile(elapsed: 0, published: 1,
            bytes: StreamingBudget.maximumFrameBytes, urgent: urgent))
          counts.append(tiles)
        }
        if cost == 0.00015 { XCTAssertEqual(counts, [4, 8]) }
        else { XCTAssertEqual(counts[0], counts[1], "Costly work retains the existing time limit") }
      }
    }
    var budget = StreamingBudget()
    budget.recordTile(seconds: 0.008)
    XCTAssertTrue(budget.allowsNextTile(elapsed: 1, published: 0, bytes: 0, urgent: false),
      "The first oversized/expensive result still makes progress")
    XCTAssertFalse(budget.allowsNextTile(elapsed: 0.008, published: 1, bytes: 1, urgent: true))
  }

  func testPublicationAccountingAndResetPreserveConfiguredLimit() {
    var budget = StreamingBudget(maximumTiles: 4)
    budget.recordFrame(published: 4, bytes: 800_000, remainingReady: 3)
    budget.recordFrame(published: 4, bytes: 900_000, remainingReady: 0)
    budget.recordFrame(published: 0, bytes: 0, remainingReady: 0)
    budget.recordFrame(published: -1, bytes: 0, remainingReady: 0)
    XCTAssertEqual(budget.metrics.frames, 3)
    XCTAssertEqual(budget.metrics.processedTiles, 8)
    XCTAssertEqual(budget.metrics.peakFrameTiles, 4)
    XCTAssertEqual(budget.metrics.peakFrameBytes, 900_000)
    XCTAssertEqual(budget.metrics.countLimitFrames, 2)
    XCTAssertEqual(budget.metrics.countLimitWithReadyFrames, 1)
    XCTAssertEqual(budget.metrics.maximumBytes, 2 * 1_024 * 1_024)
    XCTAssertEqual(budget.metrics.normalMilliseconds, 2.2, accuracy: 0.00001)
    XCTAssertEqual(budget.metrics.urgentMilliseconds, 2.5)
    budget.recordTile(seconds: 0.008); budget.published(cpuTime: 0.008, time: 1)
    budget.reset()
    XCTAssertEqual(budget.maximumTiles, 4)
    XCTAssertEqual(budget.metrics.frames, 0); XCTAssertEqual(budget.metrics.processedTiles, 0)
    XCTAssertEqual(budget.metrics.peakFrameTiles, 0); XCTAssertEqual(budget.metrics.peakFrameBytes, 0)
    XCTAssertEqual(budget.metrics.countLimitFrames, 0); XCTAssertEqual(budget.metrics.countLimitWithReadyFrames, 0)
    XCTAssertEqual(budget.metrics.estimatedTileMilliseconds, 0.7, accuracy: 0.00001)
    XCTAssertTrue(budget.metrics.reservesCoverage)
    XCTAssertEqual(budget.metrics.estimatedCoverageMilliseconds, 0.4, accuracy: 0.00001)
    XCTAssertTrue(budget.beginFrame(interval: 0.01, time: 1.01, urgent: false))
    XCTAssertEqual(StreamingBudget(maximumTiles: Int.min).maximumTiles, 1)
    XCTAssertEqual(StreamingBudget(maximumTiles: Int.max).maximumTiles, 8)
    var control = StreamingBudget(maximumTiles: 4, reservesCoverage: false)
    control.recordCoverage(seconds: 1); control.reset()
    XCTAssertEqual(control.maximumTiles, 4); XCTAssertFalse(control.metrics.reservesCoverage)
    XCTAssertEqual(control.metrics.estimatedCoverageMilliseconds, 0)
  }

  func testCoverageHeadroomLimitsCheapTilesBeforeAnExpensiveGroupSwap() {
    let tileCost = 0.00015
    for coverageCost in [0.0004, 0.0011, 0.004] {
      var budget = StreamingBudget()
      for _ in 0..<100 { budget.recordTile(seconds: tileCost) }
      budget.recordCoverage(seconds: coverageCost)
      var count = 0
      while budget.allowsNextTile(elapsed: Double(count) * tileCost,
        published: count, bytes: count * 100, urgent: false) { count += 1 }
      if coverageCost == 0.0004 { XCTAssertEqual(count, 8) }
      if coverageCost == 0.0011 { XCTAssertEqual(count, 7) }
      if coverageCost == 0.004 { XCTAssertEqual(count, 4, "Coverage headroom may limit extra work, not the original opportunity") }
      else { XCTAssertLessThanOrEqual(Double(count) * tileCost + coverageCost, 0.0022) }
      budget.published(cpuTime: Double(count) * tileCost + coverageCost, time: 0)
      XCTAssertEqual(budget.beginFrame(interval: 0.01, time: 0.01, urgent: false), coverageCost < 0.004)
    }
  }

  func testCoverageCostRisesImmediatelyDecaysAndRejectsInvalidTiming() {
    var budget = StreamingBudget()
    budget.recordCoverage(seconds: 0.002)
    XCTAssertEqual(budget.metrics.estimatedCoverageMilliseconds, 2, accuracy: 0.00001)
    for invalid in [Double.nan, .infinity, -1] { budget.recordCoverage(seconds: invalid) }
    XCTAssertEqual(budget.metrics.estimatedCoverageMilliseconds, 2, accuracy: 0.00001)
    budget.recordCoverage(seconds: 0)
    XCTAssertEqual(budget.metrics.estimatedCoverageMilliseconds, 1.7, accuracy: 0.00001)
    budget.recordCoverage(seconds: 0.005)
    XCTAssertEqual(budget.metrics.estimatedCoverageMilliseconds, 5, accuracy: 0.00001)
    budget.reset()
    XCTAssertEqual(budget.metrics.estimatedCoverageMilliseconds, 0.4, accuracy: 0.00001)
  }

  func testExtraCoverageReservationNeverRemovesAnOriginalPublicationOpportunity() {
    for coverage in [0.0, 0.001, 0.010, 1] {
      var budget = StreamingBudget()
      var legacy = StreamingBudget(maximumTiles: 4, reservesCoverage: false)
      budget.recordCoverage(seconds: coverage)
      for cost in [0.0001, 0.0008, 0.020] {
        budget.recordTile(seconds: cost); legacy.recordTile(seconds: cost)
        for count in 0..<4 {
          for elapsed in [0.0, 0.0005, 0.002, 0.009] {
            for bytes in [0, 500_000, StreamingBudget.maximumFrameBytes] {
              for urgent in [false, true] {
                XCTAssertEqual(budget.allowsNextTile(elapsed: elapsed, published: count, bytes: bytes, urgent: urgent),
                  legacy.allowsNextTile(elapsed: elapsed, published: count, bytes: bytes, urgent: urgent))
              }
            }
          }
        }
      }
    }
  }

  func testFarHazeRetainsUsefulContrast() {
    XCTAssertLessThan(AtmosphericPerspective.strength(distance: 2_048, altitude: 35), 0.8)
    XCTAssertGreaterThan(AtmosphericPerspective.strength(distance: 2_048, altitude: 35), 0.5)
  }
  private func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    a.x * b.x + a.y * b.y + a.z * b.z
  }
  private func unpack(_ a: SIMD4<UInt16>) -> SIMD3<Float> {
    [
      Float(Float16(bitPattern: a.x)), Float(Float16(bitPattern: a.y)),
      Float(Float16(bitPattern: a.z)),
    ]
  }
}
