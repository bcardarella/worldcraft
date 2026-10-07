import XCTest
@testable import WorldCore

final class VoxelColumnMaskTests: XCTestCase {
  func testClippedRectanglesUnionAndValueCopiesMatchIndependentCellSet() {
    var mask = VoxelColumnMask(), cells = Set<Int>()
    XCTAssertEqual(MemoryLayout<VoxelColumnMask>.stride, 32)
    XCTAssertTrue(mask.isEmpty)
    for (x,z) in [(-8..<2,-3..<2),(14..<19,9..<17),(4..<9,3..<8),(30..<40,0..<16),(-20 ..< -1,0..<16)] {
      mask.include(x:x,z:z)
      for rz in 0..<16 { for rx in 0..<16 where x.contains(rx) && z.contains(rz) { cells.insert(rz*16+rx) } }
      for rz in 0..<16 { for rx in 0..<16 { XCTAssertEqual(mask.contains(x:rx,z:rz),cells.contains(rz*16+rx)) } }
      XCTAssertEqual(mask.count,cells.count)
    }
    let held=mask
    mask.formUnion(.full)
    XCTAssertEqual(mask,.full);XCTAssertEqual(mask.count,256)
    XCTAssertEqual(held.count,cells.count)
    XCTAssertFalse(held.contains(x:-1,z:0));XCTAssertFalse(held.contains(x:16,z:0))
  }

  // Canonical unit-face multiset, including ordered positions, normal, material
  // and all atlas UV corners. The full, ordinary mesher provides the reference;
  // masks are applied to its emitted owner cells rather than to its input data.
  private func faces(_ mesh: VoxelMesh, selected: VoxelColumnMask? = nil,
    excludingAir: Set<BlockPosition> = [], preservingCells: Set<BlockPosition> = []) -> [[Int]:Int] {
    var result:[[Int]:Int]=[:]
    for start in stride(from:0,to:mesh.positions.count,by:4) {
      let repeated=mesh.materials[start/2]==6
      let w=repeated ? Int(mesh.textureCoordinates[start+3].x):1
      let h=repeated ? Int(mesh.textureCoordinates[start+1].y):1
      let du=(mesh.positions[start+3]-mesh.positions[start])/Float(w)
      let dv=(mesh.positions[start+1]-mesh.positions[start])/Float(h)
      for v in 0..<h { for u in 0..<w {
        let p=mesh.positions[start]+Float(u)*du+Float(v)*dv
        let points=repeated ? [p,p+dv,p+du+dv,p+du]:Array(mesh.positions[start..<(start+4)])
        let n=mesh.normals[start]
        let center=points.reduce(SIMD3<Float>.zero,+)/4-n*0.001
        if let selected, !selected.contains(x:Int(floor(center.x)),z:Int(floor(center.z))) {continue}
        let neighbor = center + n * 0.002
        if !preservingCells.contains(.init(Int(floor(center.x)),Int(floor(center.y)),Int(floor(center.z)))),
          ![UInt32(1), 5].contains(mesh.materials[start/2]),
          excludingAir.contains(.init(Int(floor(neighbor.x)), Int(floor(neighbor.y)), Int(floor(neighbor.z)))) { continue }
        let uv:[SIMD2<Float>]
        if repeated {
          let origin=TerrainAtlas.origin(tile:Int(mesh.repeatingAtlasTiles[start/4])),span=TerrainAtlas.repeatSpan
          uv=[origin,origin+[0,span.y],origin+span,origin+[span.x,0]]
        } else {uv=Array(mesh.textureCoordinates[start..<(start+4)])}
        var signature=[Int(repeated ? 0:mesh.materials[start/2])]
        for i in 0..<4 {
          for f in [points[i].x,points[i].y,points[i].z,n.x,n.y,n.z,uv[i].x,uv[i].y] {
            signature.append(Int((f*100_000).rounded()))
          }
        }
        result[signature,default:0]+=1
      } }
    }
    return result
  }

  func testSparseAndCollarColumnsKeepAllFacesAttributesAndFixturesOnEveryWorldStyle() {
    for style in PlanetStyle.allCases {
      let terrain=TerrainGenerator(seed:1667327165707871140,style:style)
      for coordinate in [ChunkCoordinate(19,51),.init(-2,-3)] {
        let origin=BlockPosition(coordinate.x*16,24,coordinate.z*16)
        let edits:[BlockPosition:Block]=[origin:.air,origin + .init(1,0,1):.brick,
          origin + .init(15,9,0):.torch,origin + .init(0,10,15):.lantern,
          origin + .init(16,8,2):.glass,origin + .init(-1,10,3):.stone]
        let chunk=terrain.generate(coordinate,edits:edits)
        var mask=VoxelColumnMask()
        mask.include(x:0..<1,z:0..<16);mask.include(x:0..<16,z:0..<1)
        mask.include(x:15..<16,z:0..<16);mask.include(x:0..<16,z:15..<16)
        mask.include(x:4..<9,z:5..<8)
        for wet in [false,true] {
          let full=VoxelMesher.build(chunk,includeWater:wet)
          let expected=faces(full,selected:mask)
          for repeated in [false,true] {
            let subset=VoxelMesher.build(chunk,columns:mask,includeWater:wet,repeatAtlas:repeated)
            XCTAssertEqual(faces(subset),expected)
            XCTAssertEqual(subset.firePositions,full.firePositions.filter {mask.contains(x:Int(floor($0.x)),z:Int(floor($0.z)))})
            XCTAssertEqual(subset.lampPositions,full.lampPositions.filter {mask.contains(x:Int(floor($0.x)),z:Int(floor($0.z)))})
          }
        }
      }
    }
  }

  func testOwnershipDoesNotReplaceUnselectedNeighboursWithAirOrEmitArtificialCaps() {
    var chunk=ChunkData(coordinate:.init(0,0))
    for y in 0...3 {for z in -1...16 {for x in -1...16 {chunk[x,y,z] = .stone}}}
    var mask=VoxelColumnMask();mask.include(x:7..<8,z:0..<16)
    let mesh=VoxelMesher.build(chunk,columns:mask,repeatAtlas:true)
    XCTAssertEqual(mesh.faceCount,2)
    XCTAssertTrue(mesh.normals.allSatisfy {abs($0.y)==1})
    XCTAssertEqual(faces(mesh),faces(VoxelMesher.build(chunk),selected:mask))
  }

  func testDisjointMasksPartitionOriginalSurfaceWithoutDuplicatesOrDroppedShapes() {
    var chunk=ChunkData(coordinate:.init(0,0)),even=VoxelColumnMask(),odd=VoxelColumnMask()
    for z in 0..<16 {for x in 0..<16 {
      if (x+z)%2==0 {even.include(x:x..<(x+1),z:z..<(z+1))}
      else {odd.include(x:x..<(x+1),z:z..<(z+1))}
    }}
    for (i,block) in Block.allCases.enumerated() {chunk[(i%5)*3,2+i/25*5,((i/5)%5)*3]=block}
    let a=VoxelMesher.build(chunk,columns:even,repeatAtlas:true),b=VoxelMesher.build(chunk,columns:odd,repeatAtlas:true)
    var combined=faces(a)
    for (key,count) in faces(b) {combined[key,default:0]+=count}
    XCTAssertEqual(combined,faces(VoxelMesher.build(chunk)))
    XCTAssertEqual(a.firePositions.count+b.firePositions.count,VoxelMesher.build(chunk).firePositions.count)
  }

  func testFullMaskHasIdenticalPackedBytesAndEmptyMaskDoesNoGeometryWork() {
    let chunk=TerrainGenerator(seed:967252643).generate(.init(19,51))
    for wet in [false,true] {for repeated in [false,true] {
      let a=VoxelMesher.build(chunk,includeWater:wet,repeatAtlas:repeated)
      let b=VoxelMesher.build(chunk,columns:.full,includeWater:wet,repeatAtlas:repeated)
      let p=PackedTerrainMesh(a,repeatOpaqueAtlas:repeated),q=PackedTerrainMesh(b,repeatOpaqueAtlas:repeated)
      XCTAssertEqual(p.vertices.withUnsafeBytes {Data($0)},q.vertices.withUnsafeBytes {Data($0)})
      XCTAssertEqual(p.indices,q.indices);XCTAssertEqual(a.firePositions,b.firePositions)
      XCTAssertEqual(a.lampPositions,b.lampPositions)
      let empty=VoxelMesher.build(chunk,columns:.init(),includeWater:wet,repeatAtlas:repeated)
      XCTAssertTrue(empty.positions.isEmpty);XCTAssertTrue(empty.indices.isEmpty)
      XCTAssertTrue(empty.firePositions.isEmpty);XCTAssertTrue(empty.lampPositions.isEmpty)
    }}
  }

  private func chamber(_ coordinate: ChunkCoordinate = .init(0,0)) -> ChunkData {
    var chunk = ChunkData(coordinate: coordinate)
    for z in -1...16 { for x in -1...16 { for y in ChunkData.minimumY...10 { chunk[x,y,z] = .stone } } }
    for z in 4...10 { for x in 4...10 { for y in 3...9 { chunk[x,y,z] = .air } } }
    // A second, open chamber must retain all of its walls.
    for z in 12...14 { for x in 12...14 { for y in 5...7 { chunk[x,y,z] = .air } } }
    for y in 8...10 { chunk[14,y,14] = .air }
    return chunk
  }
  // Independent per-voxel BFS through the fixture's finite air volume. All
  // cells below zero are solid. Unknown side columns are conservatively open.
  private func enclosedReference(_ chunk: ChunkData, columns: VoxelColumnMask = .full,
    camera: BlockPosition? = nil) -> Set<BlockPosition> {
    var transmitting = Set<BlockPosition>(), reached = Set<BlockPosition>(), pending: [BlockPosition] = []
    for z in 0..<16 { for x in 0..<16 where columns.contains(x:x,z:z) { for y in 0...11 {
      let b=chunk[x,y,z],p=BlockPosition(x,y,z)
      if !b.isOpaque || b.isFoliage { transmitting.insert(p) }
    } } }
    for p in transmitting {
      let sideUnknown = [BlockPosition(1,0,0),.init(-1,0,0),.init(0,0,1),.init(0,0,-1)].contains {
        !columns.contains(x:p.x+$0.x,z:p.z+$0.z)
      }
      if p.y==11 || sideUnknown || p==camera {reached.insert(p);pending.append(p)}
    }
    var cursor=0
    while cursor<pending.count {
      let p=pending[cursor];cursor+=1
      for d in VoxelMesher.offsets {
        let q=p+d
        if transmitting.contains(q),reached.insert(q).inserted {pending.append(q)}
      }
    }
    return Set(transmitting.filter {!reached.contains($0) && chunk[$0.x,$0.y,$0.z] == .air})
  }
  func testEnclosedAirMeshingMatchesIndependentFloodAndEveryRetainedUnitFace() throws {
    for key in [ChunkCoordinate(0,0),.init(-7,3)] {
      var chunk=chamber(key)
      // Internal transparent, liquid, cutout and shaped blocks stay on their
      // ordinary rendering paths; their presence cannot seal a component.
      for (i,b) in [Block.glass,.leaves,.water,.lava,.torch,.lantern,.woodStairsEast].enumerated() {
        chunk[4+i,5,6] = b
      }
      let source=VoxelPatchExposure.Source(chunk)
      var graph=VoxelPatchExposure.Incremental()
      guard case .ready=graph.update([key:.init(source:source,columns:.full)]) else {return XCTFail()}
      let mask=try XCTUnwrap(graph.enclosedAir(in:source)),closed=enclosedReference(chunk)
      XCTAssertFalse(closed.isEmpty)
      for y in ChunkData.minimumY..<ChunkData.height {for z in 0..<16 {for x in 0..<16 {
        XCTAssertEqual(mask.contains(x:x,y:y,z:z),closed.contains(.init(x,y,z)))
      }}}
      for repeatAtlas in [false,true] {for water in [false,true] {
        let ordinary=VoxelMesher.build(chunk,includeWater:water,repeatAtlas:repeatAtlas)
        let selected=VoxelMesher.build(source,columns:.full,enclosedAir:mask,includeWater:water,repeatAtlas:repeatAtlas)
        let actual=faces(selected),expected=faces(ordinary,excludingAir:closed,
          preservingCells:[.init(8,5,6),.init(9,5,6),.init(10,5,6)])
        XCTAssertTrue(actual==expected,
          "Unexpected faces: \(Array(actual.keys.filter {expected[$0] != actual[$0]}.prefix(2))); missing: \(Array(expected.keys.filter {expected[$0] != actual[$0]}.prefix(2)))")
        XCTAssertLessThan(selected.positions.count,ordinary.positions.count)
        XCTAssertEqual(selected.firePositions,ordinary.firePositions)
        XCTAssertEqual(selected.lampPositions,ordinary.lampPositions)
        XCTAssertEqual(selected.stadiumSeats,ordinary.stadiumSeats)
        let packed=PackedTerrainMesh(selected)
        XCTAssertTrue(packed.indices.allSatisfy {Int($0)<packed.vertices.count})
      }}
    }
  }
  func testEnclosedAirUnknownColumnsAndHaloFacesAreNeverOmitted() throws {
    let key=ChunkCoordinate(-1,-1),chunk=chamber(key),source=VoxelPatchExposure.Source(chunk)
    var columns=VoxelColumnMask();columns.include(x:0..<8,z:0..<16)
    var graph=VoxelPatchExposure.Incremental()
    guard case .ready=graph.update([key:.init(source:source,columns:columns)],exteriorOpening:{x,z,_ in
      let x=x-key.x*16,z=z-key.z*16
      return [BlockPosition(1,0,0),.init(-1,0,0),.init(0,0,1),.init(0,0,-1)].contains {
        !columns.contains(x:x+$0.x,z:z+$0.z)
      }
    }) else {return XCTFail()}
    let mask=try XCTUnwrap(graph.enclosedAir(in:source))
    XCTAssertTrue(enclosedReference(chunk,columns:columns).isEmpty)
    for x in [-1,8,16] {XCTAssertFalse(mask.contains(x:x,y:4,z:6))}
    for z in [-1,16] {XCTAssertFalse(mask.contains(x:4,y:4,z:z))}
    for y in [ChunkData.minimumY-1,ChunkData.height] {XCTAssertFalse(mask.contains(x:4,y:y,z:6))}
    let a=VoxelMesher.build(chunk,columns:columns,includeWater:false,repeatAtlas:true)
    let b=VoxelMesher.build(source,columns:columns,enclosedAir:mask,includeWater:false,repeatAtlas:true)
    XCTAssertEqual(faces(a),faces(b))
  }
  func testCameraSeedAndChangedOpeningRestoreFacesWithoutChangingFrozenMask() throws {
    let chunk=chamber(),source=VoxelPatchExposure.Source(chunk),key=chunk.coordinate
    var graph=VoxelPatchExposure.Incremental()
    let input=[key:VoxelPatchExposure.IncrementalInput(source:source,columns:.full)]
    guard case .ready=graph.update(input) else {return XCTFail()}
    let original=try XCTUnwrap(graph.enclosedAir(in:source))
    XCTAssertTrue(original.contains(x:7,y:5,z:7))
    guard case .ready=graph.update(input,exteriorOpening:{x,z,r in x==7 && z==7 && r.contains(5)}) else {return XCTFail()}
    let camera=try XCTUnwrap(graph.enclosedAir(in:source))
    XCTAssertFalse(camera.contains(x:7,y:5,z:7))
    XCTAssertTrue(enclosedReference(chunk,camera:.init(7,5,7)).isEmpty)
    XCTAssertEqual(faces(VoxelMesher.build(source,columns:.full,enclosedAir:camera,repeatAtlas:true)),
      faces(VoxelMesher.build(chunk,repeatAtlas:true)))
    guard case .ready=graph.update(input) else {return XCTFail()}
    XCTAssertTrue(try XCTUnwrap(graph.enclosedAir(in:source)).contains(x:7,y:5,z:7))
    XCTAssertFalse(camera.contains(x:7,y:5,z:7));XCTAssertTrue(original.contains(x:7,y:5,z:7))
  }
  func testEnclosedAirRejectsReplacedSourceAndMesherFallsBackWithoutLosingFaces() throws {
    let chunk=chamber(),source=VoxelPatchExposure.Source(chunk)
    var graph=VoxelPatchExposure.Incremental()
    guard case .ready=graph.update([chunk.coordinate:.init(source:source,columns:.full)]) else {return XCTFail()}
    let mask=try XCTUnwrap(graph.enclosedAir(in:source)),copy=source
    XCTAssertNotNil(graph.enclosedAir(in:copy))
    var edited=chunk;edited[7,10,7] = .air
    for replacement in [VoxelPatchExposure.Source(chunk),.init(edited)] {
      XCTAssertNil(graph.enclosedAir(in:replacement))
      let a=PackedTerrainMesh(VoxelMesher.build(replacement.chunk,repeatAtlas:true))
      let b=PackedTerrainMesh(VoxelMesher.build(replacement,columns:.full,enclosedAir:mask,repeatAtlas:true))
      XCTAssertEqual(a.vertices.withUnsafeBytes {Data($0)},b.vertices.withUnsafeBytes {Data($0)})
      XCTAssertEqual(a.indices,b.indices);XCTAssertEqual(a.parts.count,b.parts.count)
      for (a,b) in zip(a.parts,b.parts) {
        XCTAssertEqual(a.offset,b.offset);XCTAssertEqual(a.count,b.count)
        XCTAssertEqual(a.material,b.material)
        XCTAssertEqual(a.minimum,b.minimum);XCTAssertEqual(a.maximum,b.maximum)
      }
    }
  }
  func testTransmittingRoofsCannotHideCaveWallsAndBoundarySuppressionStillMatches() throws {
    for roof in [Block.glass,.leaves,.cherryLeaves,.mapleLeaves,.spruceLeaves,.willowLeaves,.water,.lava,.torch,.lantern,.woodStairsEast] {
      var chunk=chamber();chunk[7,10,7] = roof
      let source=VoxelPatchExposure.Source(chunk);var graph=VoxelPatchExposure.Incremental()
      guard case .ready=graph.update([chunk.coordinate:.init(source:source,columns:.full)]) else {return XCTFail()}
      let mask=try XCTUnwrap(graph.enclosedAir(in:source))
      XCTAssertFalse(mask.contains(x:7,y:5,z:7));XCTAssertTrue(enclosedReference(chunk).isEmpty)
      let boundary=VoxelColumnBoundary(columns:.full) {_,_ in false}
      let a=VoxelMesher.build(chunk,columns:.full,repeatAtlas:true,boundary:boundary)
      let b=VoxelMesher.build(source,columns:.full,enclosedAir:mask,repeatAtlas:true,boundary:boundary)
      XCTAssertEqual(faces(a),faces(b));XCTAssertEqual(a.firePositions,b.firePositions)
      XCTAssertEqual(a.lampPositions,b.lampPositions)
    }
  }
  func testEnclosedAirProjectionHonorsCancellation() async {
    let source=VoxelPatchExposure.Source(chamber());var graph=VoxelPatchExposure.Incremental()
    guard case .ready=graph.update([source.chunk.coordinate:.init(source:source,columns:.full)]) else {return XCTFail()}
    let frozen=graph
    let cancelled=await Task.detached {
      withUnsafeCurrentTask {$0?.cancel()}
      return frozen.enclosedAir(in:source)==nil
    }.value
    XCTAssertTrue(cancelled);XCTAssertNotNil(graph.enclosedAir(in:source))
  }
}
