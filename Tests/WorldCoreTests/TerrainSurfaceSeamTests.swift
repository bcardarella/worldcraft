import XCTest
@testable import WorldCore

final class TerrainSurfaceSeamTests: XCTestCase {
  private let directions = [0, 1, 4, 5]
  private func patch(_ face: Int) -> (VoxelColumnMask, VoxelColumnBoundary) {
    var mask = VoxelColumnMask(); mask.include(x: 7..<8, z: 7..<8)
    let d = VoxelMesher.offsets[face]
    let boundary = VoxelColumnBoundary(columns: mask) { x,z in x != 7 + d.x || z != 7 + d.z }
    return (mask, boundary)
  }
  private func slab(inner: Int, outer: Int, face: Int, coordinate: ChunkCoordinate = .init(-2,3)) -> ChunkData {
    var chunk = ChunkData(coordinate: coordinate)
    for z in -1...16 { for x in -1...16 { for y in ChunkData.minimumY..<outer { chunk[x,y,z] = .stone } } }
    for y in ChunkData.minimumY..<ChunkData.height { chunk[7,y,7] = y < inner ? .stone : .air }
    return chunk
  }
  private func join(_ chunk: ChunkData, _ face: Int, _ h0: Float, _ h1: Float) -> TerrainSurfaceSeam.Result {
    TerrainSurfaceSeam.build(chunk, boundary: patch(face).1) { _ in
      [.init(firstHeight: h0, lastHeight: h1, material: .stone, referenceHeight: min(h0,h1))]
    }!
  }
  private func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x*b.x+a.y*b.y+a.z*b.z }
  private func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    [a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x]
  }
  private func hit(_ mesh: VoxelMesh, _ origin: SIMD3<Float>, _ direction: SIMD3<Float>) -> (Float, SIMD3<Float>, SIMD2<Float>, UInt16)? {
    var best: (Float,SIMD3<Float>,SIMD2<Float>,UInt16)?
    for i in stride(from:0,to:mesh.indices.count,by:3) {
      let ai=Int(mesh.indices[i]),bi=Int(mesh.indices[i+1]),ci=Int(mesh.indices[i+2])
      let a=mesh.positions[ai],b=mesh.positions[bi],c=mesh.positions[ci]
      let e1=b-a,e2=c-a,p=cross(direction,e2),det=dot(e1,p)
      guard abs(det)>1e-7 else {continue}
      let s=origin-a,u=dot(s,p)/det
      guard u>=0 && u<=1 else {continue}
      let q=cross(s,e1),v=dot(direction,q)/det
      guard v>=0 && u+v<=1 else {continue}
      let t=dot(e2,q)/det
      if t>=0 && t<(best?.0 ?? .infinity) {
        let normal=mesh.normals[ai],uv=mesh.textureCoordinates[ai]*(1-u-v)+mesh.textureCoordinates[bi]*u+mesh.textureCoordinates[ci]*v
        best=(t,normal,uv,mesh.repeatingAtlasTiles.isEmpty ? 0:mesh.repeatingAtlasTiles[ai/4])
      }
    }
    return best
  }
  private func probePoint(face: Int, u: Float, y: Float) -> (SIMD3<Float>, SIMD3<Float>) {
    let d=VoxelMesher.offsets[face],normal=SIMD3<Float>(Float(d.x),0,Float(d.z))
    let point:SIMD3<Float> = face<2 ? [face==0 ? 8:7,y,7+u] : [7+u,y,face==4 ? 8:7]
    return (point-normal*0.25,normal)
  }

  func testBoundaryOwnershipIncludesHaloAndOmitsOnlyRequestedFaces() {
    let chunk=slab(inner:4,outer:8,face:0)
    let mask=VoxelColumnMask.full
    let internalBoundary=VoxelColumnBoundary(columns:mask) {_,_ in true}
    XCTAssertTrue(internalBoundary.edges.isEmpty)
    let full=VoxelMesher.build(chunk,columns:mask,repeatAtlas:true)
    let held=VoxelMesher.build(chunk,columns:mask,repeatAtlas:true,boundary:internalBoundary)
    XCTAssertEqual(full.positions,held.positions);XCTAssertEqual(full.indices,held.indices)
    let perimeter=VoxelColumnBoundary(columns:mask) {mask.contains(x:$0,z:$1)}
    XCTAssertEqual(perimeter.edges.count,64)
    for face in directions {
      let (selected,boundary)=patch(face)
      XCTAssertEqual(boundary.edges.count,1);XCTAssertEqual(boundary.edges.first?.face,face)
      let mesh=VoxelMesher.build(slab(inner:8,outer:4,face:face),columns:selected,repeatAtlas:true,boundary:boundary)
      let (p,d)=probePoint(face:face,u:0.43,y:6.37)
      XCTAssertNil(hit(mesh,p,d))
    }
  }

  func testRaisedAndLoweredCoarseGroundMatchIndependentOccupancyInEveryDirection() {
    var probes=0
    for face in directions { for inner in [0,4,8] { for h:Float in [-2,0,3.25,6,9.75] {
      let chunk=slab(inner:inner,outer:Int(ceil(h)),face:face),result=join(chunk,face,h,h)
      XCTAssertFalse(result.requiresExpandedDetail)
      for iy in -12..<48 {for iu in 0..<11 {
        let y=Float(iy)*0.25+0.071,u=(Float(iu)+0.319)/11
        let a=y<Float(inner),b=y<h,expected=a != b
        let (p,d)=probePoint(face:face,u:u,y:y),sample=hit(result.mesh,p,d)
        XCTAssertEqual(sample != nil,expected)
        if let sample {
          XCTAssertEqual(sample.0,0.25,accuracy:0.00001)
          XCTAssertEqual(dot(sample.1,d),a ? 1:-1)
          let tile=TerrainAtlas.tile(block:.stone,face:a ? face:face^1)
          XCTAssertEqual(sample.3,UInt16(tile))
          XCTAssertGreaterThanOrEqual(sample.2.x,-0.0001);XCTAssertLessThanOrEqual(sample.2.x,1.0001)
          XCTAssertGreaterThanOrEqual(sample.2.y,-0.0001);XCTAssertLessThanOrEqual(sample.2.y,1.0001)
        }
        probes+=1
      }}
    } } }
    XCTAssertEqual(probes,39600)
  }

  func testSlopesAndSplitCoarseTrianglesHaveNoHolesDuplicatesOrChangedUVs() {
    for face in directions {
      let chunk=slab(inner:5,outer:8,face:face),boundary=patch(face).1
      let single=join(chunk,face,2,8)
      let split=TerrainSurfaceSeam.build(chunk,boundary:boundary) {_ in [
        .init(lower:0,upper:0.375,firstHeight:2,lastHeight:4.25,material:.stone,referenceHeight:2),
        .init(lower:0.375,upper:1,firstHeight:4.25,lastHeight:8,material:.stone,referenceHeight:2)]}!
      for iy in 0..<48 {for iu in 0..<39 {
        let u=(Float(iu)+0.217)/39,y=Float(iy)*0.25+0.063
        let expected=(y<5) != (y<2+6*u)
        let (p,d)=probePoint(face:face,u:u,y:y)
        let a=hit(single.mesh,p,d),b=hit(split.mesh,p,d)
        XCTAssertEqual(a != nil,expected);XCTAssertEqual(b != nil,expected)
        if let a,let b {XCTAssertEqual(a.0,b.0,accuracy:1e-5);XCTAssertEqual(a.1,b.1)
          XCTAssertEqual(a.2.x,b.2.x,accuracy:1e-5);XCTAssertEqual(a.2.y,b.2.y,accuracy:1e-5)}
      }}
      let packed=PackedTerrainMesh(split.mesh)
      XCTAssertTrue(packed.vertices.allSatisfy {$0.px.isFinite && $0.py.isFinite && $0.pz.isFinite})
      for i in stride(from:0,to:split.mesh.indices.count,by:3) {
        let a=split.mesh.positions[Int(split.mesh.indices[i])],b=split.mesh.positions[Int(split.mesh.indices[i+1])],c=split.mesh.positions[Int(split.mesh.indices[i+2])]
        let n=cross(b-a,c-a)
        if dot(n,n)>1e-10 {XCTAssertGreaterThan(dot(n,split.mesh.normals[Int(split.mesh.indices[i])]),0)}
      }
    }
  }

  func testIntegerGroundSeamKeepsOriginalAtlasFaceOrientationAndShading() {
    for face in directions { for (inside,outside) in [(4,8),(9,3)] {
      let chunk=slab(inner:inside,outer:outside,face:face)
      let full=VoxelMesher.build(chunk,includeWater:false,repeatAtlas:true)
      let transition=join(chunk,face,Float(outside),Float(outside)).mesh
      for y in min(inside,outside)..<max(inside,outside) {for u:Float in [0.173,0.619,0.893] {
        let (p,d)=probePoint(face:face,u:u,y:Float(y)+0.317)
        guard let a=hit(full,p,d),let b=hit(transition,p,d) else {XCTFail("Missing original or transition face");continue}
        XCTAssertEqual(a.0,b.0,accuracy:1e-5);XCTAssertEqual(a.1,b.1);XCTAssertEqual(a.3,b.3)
        XCTAssertEqual(a.2.x-floor(a.2.x),b.2.x-floor(b.2.x),accuracy:1e-5)
        XCTAssertEqual(a.2.y-floor(a.2.y),b.2.y-floor(b.2.y),accuracy:1e-5)
      }}
    } }
  }

  func testKnownMissedStepIsClosedWithoutMovingInteriorGeometry() {
    let chunk=slab(inner:4,outer:8,face:0), (mask,boundary)=patch(0)
    var mesh=VoxelMesher.build(chunk,columns:mask,repeatAtlas:true,boundary:boundary)
    let before=mesh.positions,transition=join(chunk,0,6,6)
    XCTAssertFalse(transition.requiresExpandedDetail)
    mesh.append(transition.mesh)
    XCTAssertEqual(Array(mesh.positions.prefix(before.count)),before)
    let sample=hit(mesh,[7.37,5.37,7.43],[1,0,0])
    XCTAssertNotNil(sample);XCTAssertEqual(sample!.0,0.63,accuracy:1e-5)
    XCTAssertEqual(sample!.1,[-1,0,0])
  }

  func testCavesOverhangsAndUnsupportedWaterAreReportedInsteadOfSilentlyApproved() {
    for face in directions {
      var chunk=slab(inner:10,outer:10,face:face)
      let n=patch(face).1.edges[0].neighbor
      for y in 2..<6 {chunk[7,y,7] = .air;chunk[n.x,y,n.z] = .air}
      let result=join(chunk,face,10,10)
      XCTAssertTrue(result.requiresExpandedDetail)
      XCTAssertEqual(Set(result.cavityCells),Set((2..<6).map {BlockPosition(-32+n.x,$0,48+n.z)}))
      let (p,d)=probePoint(face:face,u:0.31,y:3.17)
      // The represented coarse volume would cap this hole. Flagging it is
      // mandatory; publishing a watertight but false cave wall is not allowed.
      XCTAssertNotNil(hit(result.mesh,p,d))
      chunk[7,3,7] = .water;chunk[7,8,7] = .stoneStairsEast
      let rejected=join(chunk,face,10,10)
      XCTAssertTrue(rejected.requiresExpandedDetail)
      XCTAssertEqual(Set(rejected.unsupportedCells),[.init(-25,3,55),.init(-25,8,55)])
    }
  }

  func testCavityBoundsEncloseClippedFacesWithoutWholeCellOrWorldFloatRounding() {
    for face in directions { for rising in [false, true] { for largeOrigin in [false, true] {
      var chunk = slab(inner: 12, outer: 12, face: face,
        coordinate: largeOrigin ? .init(-4_000_001, 4_000_003) : .init(-2,3))
      let boundary = patch(face).1, n = boundary.edges[0].neighbor
      chunk[7, 3, 7] = .air; chunk[n.x, 3, n.z] = .air
      let heights: (Float, Float) = rising ? (2.5, 3.5) : (3.5, 2.5)
      let result = TerrainSurfaceSeam.build(chunk, boundary: boundary) { _ in [
        .init(lower: 0, upper: 0.25, firstHeight: heights.0,
          lastHeight: heights.0 + (heights.1 - heights.0) * 0.25, material: .stone, referenceHeight: 12),
        .init(lower: 0.25, upper: 1, firstHeight: heights.0 + (heights.1 - heights.0) * 0.25,
          lastHeight: heights.1, material: .stone, referenceHeight: 12)] }!
      XCTAssertEqual(result.cavityFaces.count, 1)
      guard let cap = result.cavityFaces.first else { continue }
      let cell = BlockPosition(chunk.coordinate.x * 16 + n.x, 3, chunk.coordinate.z * 16 + n.z)
      XCTAssertEqual(cap.outsideCell, cell)
      XCTAssertEqual(result.cavityCells, [cell])
      XCTAssertEqual(cap.face, face ^ 1)
      let axis = face < 2 ? 0 : 2, along = face < 2 ? 2 : 0
      let normalOffset: Float = face % 2 == 0 ? 0 : 1
      XCTAssertEqual(cap.minimum[axis], normalOffset)
      XCTAssertEqual(cap.maximum[axis], normalOffset)
      XCTAssertEqual(cap.minimum[along], rising ? 0.5 : 0)
      XCTAssertEqual(cap.maximum[along], rising ? 1 : 0.5)
      XCTAssertEqual(cap.minimum.y, 0)
      XCTAssertEqual(cap.maximum.y, 0.5)
      let offset = SIMD3<Float>(Float(n.x), 3, Float(n.z))
      let d = VoxelMesher.offsets[cap.face], normal = SIMD3<Float>(Float(d.x), 0, Float(d.z))
      var checked = 0
      for i in result.mesh.positions.indices where result.mesh.normals[i] == normal {
        let vertex = result.mesh.positions[i] - offset
        for component in 0..<3 {
          XCTAssertGreaterThanOrEqual(vertex[component], cap.minimum[component])
          XCTAssertLessThanOrEqual(vertex[component], cap.maximum[component])
        }
        checked += 1
      }
      XCTAssertGreaterThan(checked, 0)
      // World positions remain precise when the caller adds local bounds in
      // Double. A global Float would erase this fractional face extent.
      let low = SIMD3<Double>(Double(cell.x), Double(cell.y), Double(cell.z))
        + SIMD3<Double>(cap.minimum)
      let high = SIMD3<Double>(Double(cell.x), Double(cell.y), Double(cell.z))
        + SIMD3<Double>(cap.maximum)
      XCTAssertEqual(high[along] - low[along], 0.5)
      XCTAssertEqual(high[axis] - low[axis], 0)
    } } }
  }

  func testSharedOutsideCellKeepsEveryOrientedCapAndMergesSegmentBounds() {
    var chunk = slab(inner: 12, outer: 12, face: 0)
    var columns = VoxelColumnMask()
    columns.include(x: 6..<7, z: 7..<8); columns.include(x: 7..<8, z: 6..<7)
    let boundary = VoxelColumnBoundary(columns: columns) { $0 != 7 || $1 != 7 }
    chunk[6, 3, 7] = .air; chunk[7, 3, 6] = .air; chunk[7, 3, 7] = .air
    let result = TerrainSurfaceSeam.build(chunk, boundary: boundary) { _ in [
      .init(lower: 0, upper: 0.25, firstHeight: 3.25, lastHeight: 3.5, material: .stone, referenceHeight: 12),
      .init(lower: 0.25, upper: 1, firstHeight: 3.5, lastHeight: 3.75, material: .stone, referenceHeight: 12)] }!
    XCTAssertEqual(result.cavityCells, [.init(-25, 3, 55)])
    XCTAssertEqual(result.cavityFaces.map(\.face), [1, 5])
    for cap in result.cavityFaces {
      XCTAssertEqual(cap.outsideCell, result.cavityCells[0])
      let axis = cap.face < 2 ? 0 : 2, along = cap.face < 2 ? 2 : 0
      XCTAssertEqual(cap.minimum, .zero)
      XCTAssertEqual(cap.maximum[axis], 0)
      XCTAssertEqual(cap.maximum[along], 1)
      XCTAssertEqual(cap.maximum.y, 0.75)
    }
  }

  func testInspectionMatchesMeshDiagnosticsAcrossMaterialsEdgesAndSlopes() {
    for face in directions { for inner in Block.allCases { for outer in [Block.air, .stone, .water, .woodStairsEast] {
      var chunk = slab(inner: 12, outer: 12, face: face)
      let boundary = patch(face).1, n = boundary.edges[0].neighbor
      chunk[7, 3, 7] = inner; chunk[n.x, 3, n.z] = outer
      func segments(_: VoxelColumnBoundary.Edge) -> [TerrainSurfaceSeam.Segment] { [
        .init(lower: 0, upper: 0.375, firstHeight: 2.5, lastHeight: 3.25, material: .stone, referenceHeight: 12),
        .init(lower: 0.375, upper: 1, firstHeight: 3.25, lastHeight: 4.5, material: .stone, referenceHeight: 12)] }
      let built = TerrainSurfaceSeam.build(chunk, boundary: boundary, surface: segments)!
      let inspected = TerrainSurfaceSeam.inspect(chunk, boundary: boundary, surface: segments)!
      XCTAssertEqual(inspected, built.inspection)
      let shapedOrLiquid = { (b: Block) in b.isLiquid || b.isStair || b == .torch || b == .lantern }
      if shapedOrLiquid(inner) || shapedOrLiquid(outer) {
        XCTAssertEqual(inspected.unsupportedCells, [.init(-25, 3, 55)])
        XCTAssertTrue(inspected.cavityFaces.isEmpty)
      } else if !inner.isOpaque && outer == .air {
        XCTAssertEqual(inspected.cavityCells, [.init(-32 + n.x, 3, 48 + n.z)])
        XCTAssertEqual(inspected.cavityFaces.count, 1)
      } else {
        XCTAssertTrue(inspected.cavityCells.isEmpty)
        XCTAssertTrue(inspected.unsupportedCells.isEmpty)
      }
    } } }
  }

  func testInspectionHonoursCancellationBeforeReadingSurface() async {
    let chunk = slab(inner: 12, outer: 12, face: 0), boundary = patch(0).1
    let result = await Task.detached {
      withUnsafeCurrentTask { $0?.cancel() }
      return TerrainSurfaceSeam.inspect(chunk, boundary: boundary) { _ in
        XCTFail("Cancelled inspection read surface")
        return [.init(firstHeight: 12, lastHeight: 12, material: .stone, referenceHeight: 12)]
      }
    }.value
    XCTAssertNil(result)
  }

  func testIndependentFluidsKeepOpaqueGroundGeometryAndRequireTheirOwnSurface() {
    for face in directions { for fluid in [Block.water, .lava] { for h: Float in [2, 3.25, 6, 9.75] {
      let dry = slab(inner: 4, outer: Int(ceil(h)), face: face), boundary = patch(face).1
      var wet = dry
      for z in -1...16 { for x in -1...16 { for y in 0..<16 where wet[x,y,z] == .air {
        wet[x,y,z] = fluid
      } } }
      func surface(_: VoxelColumnBoundary.Edge) -> [TerrainSurfaceSeam.Segment] {
        [.init(firstHeight: h, lastHeight: h, material: .stone, referenceHeight: h)]
      }
      let reference = TerrainSurfaceSeam.build(dry, boundary: boundary, surface: surface)!
      let retained = TerrainSurfaceSeam.build(wet, boundary: boundary,
        fluids: .retainedSeparately, surface: surface)!
      let inspected = TerrainSurfaceSeam.inspect(wet, boundary: boundary,
        fluids: .retainedSeparately, surface: surface)!
      XCTAssertEqual(retained.inspection, inspected)
      XCTAssertEqual(reference.mesh.positions, retained.mesh.positions)
      XCTAssertEqual(reference.mesh.normals, retained.mesh.normals)
      XCTAssertEqual(reference.mesh.textureCoordinates, retained.mesh.textureCoordinates)
      XCTAssertEqual(reference.mesh.indices, retained.mesh.indices)
      XCTAssertEqual(reference.mesh.materials, retained.mesh.materials)
      XCTAssertEqual(reference.cavityFaces, retained.cavityFaces)
      XCTAssertTrue(inspected.unsupportedCells.isEmpty)
      XCTAssertTrue(inspected.requiresRetainedFluidSurface)
      let n = boundary.edges[0].neighbor
      var expected = Set<BlockPosition>()
      for y in 0..<16 { for (x,z) in [(7,7),(n.x,n.z)] where wet[x,y,z] == fluid {
        expected.insert(.init(-32+x,y,48+z))
      } }
      XCTAssertEqual(Set(retained.fluidBoundaryCells), expected)
      let strict = TerrainSurfaceSeam.inspect(wet, boundary: boundary, surface: surface)!
      XCTAssertTrue(strict.requiresExpandedDetail)
      XCTAssertFalse(strict.unsupportedCells.isEmpty)
      XCTAssertTrue(strict.fluidBoundaryCells.isEmpty)
    } } }
  }

  func testWaterAboveGroundDoesNotForceTerrainExpansion() {
    for face in directions { for fluid in [Block.water, .lava] {
      var chunk = slab(inner: 4, outer: 4, face: face)
      let boundary = patch(face).1, n = boundary.edges[0].neighbor
      for y in 4..<9 { chunk[7,y,7] = fluid; chunk[n.x,y,n.z] = fluid }
      let result = TerrainSurfaceSeam.build(chunk, boundary: boundary, fluids: .retainedSeparately) { _ in
        [.init(firstHeight: 4, lastHeight: 4, material: .stone, referenceHeight: 4)]
      }!
      XCTAssertTrue(result.mesh.positions.isEmpty)
      XCTAssertFalse(result.requiresExpandedDetail)
      XCTAssertTrue(result.inspection.requiresRetainedFluidSurface)
      XCTAssertEqual(result.fluidBoundaryCells.count, 10)
    } }
  }

  func testUnderwaterAirAndFluidCavitiesStillPreventFalseOpaqueWalls() {
    for face in directions { for inner in [Block.air, .water, .lava] { for outer in [Block.air, .water, .lava] {
      var chunk = slab(inner: 12, outer: 12, face: face)
      let boundary = patch(face).1, n = boundary.edges[0].neighbor
      for y in 2..<6 { chunk[7,y,7] = inner; chunk[n.x,y,n.z] = outer }
      let result = TerrainSurfaceSeam.build(chunk, boundary: boundary, fluids: .retainedSeparately) { _ in
        [.init(firstHeight: 12, lastHeight: 12, material: .stone, referenceHeight: 12)]
      }!
      XCTAssertEqual(Set(result.cavityCells), Set((2..<6).map { BlockPosition(-32+n.x,$0,48+n.z) }))
      XCTAssertEqual(result.cavityFaces.count, 4)
      XCTAssertTrue(result.requiresExpandedDetail)
      XCTAssertTrue(result.unsupportedCells.isEmpty)
      XCTAssertTrue(result.mesh.materials.allSatisfy { $0 == 6 })
      let (p,d) = probePoint(face: face, u: 0.31, y: 3.17)
      XCTAssertNotNil(hit(result.mesh, p, d), "This introduced terrain wall must be reported")
    } } }
  }

  func testTransparentAndCutoutCellsCannotHideIntroducedOpaqueCap() {
    for face in directions { for inner in [Block.air, .glass] {
      for outer in [Block.air, .glass] + Block.allCases.filter(\.isFoliage) {
        var chunk = slab(inner: 12, outer: 12, face: face)
        let boundary = patch(face).1, n = boundary.edges[0].neighbor
        chunk[7,3,7] = inner; chunk[n.x,3,n.z] = outer
        let result = join(chunk, face, 12, 12)
        let (p,d) = probePoint(face: face, u: 0.31, y: 3.17)
        XCTAssertNotNil(hit(result.mesh, p, d))
        XCTAssertTrue(result.requiresExpandedDetail)
        XCTAssertEqual(result.cavityCells, [.init(-32+n.x,3,48+n.z)])
      }
    } }
  }

  func testCachedInspectionUsesImmutableSourceAndExactSurfaceProfiles() {
    var chunk = slab(inner: 12, outer: 12, face: 0)
    chunk[7,3,7] = .air; chunk[8,3,7] = .air
    let source = TerrainSurfaceSeam.Source(chunk), copied = source, boundary = patch(0).1
    var cache = TerrainSurfaceSeam.InspectionCache()
    func surface(_ height: Float = 12, _ material: Block = .stone, _ reference: Float = 12)
      -> [TerrainSurfaceSeam.Segment] {
      [.init(firstHeight: height, lastHeight: height, material: material, referenceHeight: reference)]
    }
    let first = cache.inspect(source, boundary: boundary) { _ in surface() }!
    XCTAssertEqual(first.cavityCells.count, 1)
    chunk[8,3,7] = .stone // Must not mutate the old source through shared storage.
    XCTAssertEqual(cache.inspect(copied, boundary: boundary) { _ in surface() }, first)
    XCTAssertEqual(cache.metrics.hits, 1)
    let changed = TerrainSurfaceSeam.Source(chunk)
    XCTAssertTrue(cache.inspect(changed, boundary: boundary) { _ in surface() }!.cavityCells.isEmpty)
    XCTAssertEqual(cache.metrics.misses, 2)
    _ = cache.inspect(source, boundary: boundary) { _ in surface() }
    let clipped = cache.inspect(source, boundary: boundary) { _ in surface(3.5) }!
    XCTAssertEqual(clipped.cavityFaces.first?.maximum.y, 0.5)
    XCTAssertEqual(cache.metrics.misses, 4)
    XCTAssertEqual(cache.inspect(source, boundary: boundary) { _ in surface(3.5, .brick) }, clipped)
    XCTAssertEqual(cache.metrics.misses, 5)
    let noCavity = cache.inspect(source, boundary: boundary) { _ in surface(3.5, .brick, 3) }!
    XCTAssertTrue(noCavity.cavityFaces.isEmpty)
    XCTAssertEqual(cache.metrics.misses, 6)
    let split = cache.inspect(source, boundary: boundary) { _ in [
      .init(lower: 0, upper: 0.5, firstHeight: 3.5, lastHeight: 3.5, material: .brick, referenceHeight: 3),
      .init(lower: 0.5, upper: 1, firstHeight: 3.5, lastHeight: 3.5, material: .brick, referenceHeight: 3)] }!
    XCTAssertEqual(split, noCavity)
    XCTAssertEqual(cache.metrics.misses, 7)
  }

  func testInspectionCacheInvalidatesBoundaryOwnershipAndFluidContract() {
    var chunk = slab(inner: 12, outer: 12, face: 0)
    chunk[7,3,7] = .air; chunk[8,3,7] = .water
    let source = TerrainSurfaceSeam.Source(chunk), (columns, boundary) = patch(0)
    let closed = VoxelColumnBoundary(columns: columns) { _,_ in true }
    var cache = TerrainSurfaceSeam.InspectionCache()
    func surface(_: VoxelColumnBoundary.Edge) -> [TerrainSurfaceSeam.Segment] {
      [.init(firstHeight: 12, lastHeight: 12, material: .stone, referenceHeight: 12)]
    }
    XCTAssertFalse(cache.inspect(source, boundary: boundary, surface: surface)!.unsupportedCells.isEmpty)
    let fluid = cache.inspect(source, boundary: boundary, fluids: .retainedSeparately, surface: surface)!
    XCTAssertTrue(fluid.unsupportedCells.isEmpty)
    XCTAssertEqual(fluid.fluidBoundaryCells, [.init(-24,3,55)])
    XCTAssertEqual(fluid.cavityFaces.count, 1)
    XCTAssertEqual(cache.metrics.misses, 2)
    XCTAssertEqual(cache.inspect(source, boundary: boundary, fluids: .retainedSeparately, surface: surface), fluid)
    XCTAssertEqual(cache.metrics.hits, 1)
    let noEdge = cache.inspect(source, boundary: closed, fluids: .retainedSeparately, surface: surface)!
    XCTAssertFalse(noEdge.requiresExpandedDetail)
    XCTAssertFalse(noEdge.requiresRetainedFluidSurface)
    XCTAssertEqual(cache.metrics.misses, 3)
    cache.removeAll()
    XCTAssertEqual(cache.metrics.entries, 0); XCTAssertEqual(cache.metrics.bytes, 0)
    _ = cache.inspect(source, boundary: closed, fluids: .retainedSeparately, surface: surface)
    XCTAssertEqual(cache.metrics.misses, 4)
  }

  func testInspectionCacheHasBoundedLRUAndDoesNotDropOversizedResults() {
    let boundary = patch(0).1
    let sources = (0..<3).map { i -> TerrainSurfaceSeam.Source in
      var chunk = slab(inner: 12, outer: 12, face: 0, coordinate: .init(-2-i,3+i))
      chunk[7,3,7] = .air; chunk[8,3,7] = .air
      return .init(chunk)
    }
    func surface(_: VoxelColumnBoundary.Edge) -> [TerrainSurfaceSeam.Segment] {
      [.init(firstHeight: 12, lastHeight: 12, material: .stone, referenceHeight: 12)]
    }
    var cache = TerrainSurfaceSeam.InspectionCache(maximumBytes: 4_096, maximumEntries: 2)
    for i in [0,1,0,2,0] {
      XCTAssertEqual(cache.inspect(sources[i], boundary: boundary, surface: surface)!.cavityCells.count, 1)
      XCTAssertLessThanOrEqual(cache.metrics.entries, 2)
      XCTAssertLessThanOrEqual(cache.metrics.bytes, 4_096)
    }
    XCTAssertEqual(cache.metrics.hits, 2); XCTAssertEqual(cache.metrics.misses, 3)
    XCTAssertEqual(cache.metrics.evictions, 1)
    _ = cache.inspect(sources[1], boundary: boundary, surface: surface)
    XCTAssertEqual(cache.metrics.misses, 4); XCTAssertEqual(cache.metrics.evictions, 2)
    for (bytes, entries) in [(1,2),(4_096,0)] {
      var limited = TerrainSurfaceSeam.InspectionCache(maximumBytes: bytes, maximumEntries: entries)
      XCTAssertEqual(limited.inspect(sources[0], boundary: boundary, surface: surface)!.cavityFaces.count, 1)
      XCTAssertEqual(limited.metrics.bytes, 0); XCTAssertEqual(limited.metrics.entries, 0)
      XCTAssertEqual(limited.metrics.bypasses, 1)
    }
  }

  func testCancelledCacheLookupCannotReturnOrAlterStoredInspection() async {
    let source = TerrainSurfaceSeam.Source(slab(inner: 4, outer: 8, face: 0)), boundary = patch(0).1
    var initial = TerrainSurfaceSeam.InspectionCache()
    _ = initial.inspect(source, boundary: boundary) { _ in
      [.init(firstHeight: 8, lastHeight: 8, material: .stone, referenceHeight: 8)]
    }
    let snapshot = initial
    let (result, metrics) = await Task.detached {
      var cache = snapshot
      withUnsafeCurrentTask { $0?.cancel() }
      let value = cache.inspect(source, boundary: boundary) { _ in
        XCTFail("Cancelled cache lookup read surface")
        return []
      }
      return (value, cache.metrics)
    }.value
    XCTAssertNil(result)
    XCTAssertEqual(metrics.entries, 1); XCTAssertEqual(metrics.hits, 0)
    XCTAssertEqual(metrics.misses, 1); XCTAssertEqual(metrics.bytes, initial.metrics.bytes)
  }
}
