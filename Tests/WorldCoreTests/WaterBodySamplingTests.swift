import XCTest
@testable import WorldCore

final class WaterBodySamplingTests: XCTestCase {
  func testBoundedProbesUseDistanceAndStableWorldTies() {
    let origin = SIMD2<Int>(-17,31)
    let points:[SIMD2<Int>:WaterBody] = [
      origin &+ [4,0]:.init(id:1,kind:.lake,level:40),
      origin &+ [-4,0]:.init(id:2,kind:.river,level:42,current:[0.7,0,-0.4]),
      origin &+ [0,-4]:.init(id:3,kind:.river,level:43,current:[0.8,0,0.1]),
      origin &+ [0,4]:.lava,
      origin &+ [2,2]:.init(id:5,kind:.lake,level:39),
    ]
    // Independent selection over known bodies at supported quad offsets.
    for z in -8...8 { for x in -8...8 {
      let p = origin &+ SIMD2(x,z)
      let candidates = points.keys.filter { q in
        let dx=abs(q.x-p.x),dz=abs(q.y-p.y),extent=max(dx,dz)
        return extent==0 || (q.x<=p.x && q.y<=p.y && extent<=32 && extent.nonzeroBitCount==1 && (dx==0 || dz==0 || dx==dz))
      }
      let expected = candidates.min { a,b in
        let da=a &- p,db=b &- p
        return (da.x*da.x+da.y*da.y,a.y,a.x) < (db.x*db.x+db.y*db.y,b.y,b.x)
      }
      var sampler = WaterBodySampling()
      XCTAssertEqual(sampler.nearest(atX:p.x,z:p.y,lookup:{points[[$0,$1]]}),expected.flatMap {points[$0]})
    } }
    var sampler = WaterBodySampling()
    let ties = points.filter {$0.key != origin &+ [2,2]}
    XCTAssertEqual(sampler.nearest(atX:origin.x,z:origin.y,lookup:{ties[[$0,$1]]})?.id,3)
  }

  func testEveryCurrentQuadSizeHasEvidenceInsideFixedRadius() {
    for size in [1,2,4,8,16,32] {
      let origin=SIMD2<Int>(-size*3,-size*2)
      for corner in [SIMD2(0,0),[size,0],[0,size],[size,size]] {
        var sampler = WaterBodySampling()
        let p=origin &+ corner
        let body = sampler.nearest(atX:p.x,z:p.y) {x,z in
          SIMD2(x,z)==origin ? .init(id:123,kind:.lake,level:73):nil
        }
        XCTAssertEqual(body?.level,73,"No invented sea-level vertex for a sparse wet source")
      }
    }
  }

  func testUnknownRemainsUnknownAndDryLookupsAreMemoized() {
    var sampler = WaterBodySampling(),queries=0
    XCTAssertNil(sampler.nearest(atX:-16,z:16) {_,_ in queries+=1;return nil})
    let first=queries
    XCTAssertGreaterThan(first,1);XCTAssertEqual(first,19)
    XCTAssertNil(sampler.nearest(atX:-16,z:16) {_,_ in queries+=1;return .ocean})
    XCTAssertEqual(queries,first,"Both known wet and known dry values belong to one immutable snapshot")
    XCTAssertNil(sampler.nearest(atX:Int.max,z:0) {_,_ in XCTFail("Overflow query");return .ocean})
  }

  func testOwnColumnWinsWithoutSearchingAndFreshSamplerDoesNotReuseOldWorld() {
    var first = WaterBodySampling(),calls=0
    XCTAssertEqual(first.nearest(atX:19,z:-7) {_,_ in calls+=1;return .lava},.lava)
    XCTAssertEqual(calls,1)
    var next = WaterBodySampling()
    XCTAssertEqual(next.nearest(atX:19,z:-7) {_,_ in .ocean},.ocean)
  }

  func testCancelledLookupDoesNotQueryOrInventFallback() async {
    let value = await Task.detached {
      withUnsafeCurrentTask {$0?.cancel()}
      var sampler = WaterBodySampling()
      return sampler.nearest(atX:0,z:0) {_,_ in XCTFail("Cancelled callback");return .ocean}
    }.value
    XCTAssertNil(value)
  }

  func testGeneratedRiverDryRimRetainsRiverElevationInsteadOfOcean() throws {
    let terrain = TerrainGenerator(seed:1667327165707871140,style:.verdant)
    for z in 909...912 {
      let x=928
      XCTAssertNil(terrain.waterBody(atX:x,z:z))
      var sampler=WaterBodySampling()
      let chosen=try XCTUnwrap(sampler.nearest(atX:x,z:z,lookup:{terrain.waterBody(atX:$0,z:$1)}))
      XCTAssertEqual(chosen.kind,.river)
      XCTAssertGreaterThan(chosen.level,40)
      // Independently filter a square to supported offsets; confirm the
      // selected river and tie, including the formerly missed grid vertex.
      var possible:[(Int,Int,Int,WaterBody)]=[]
      for dz in -12...0 { for dx in -12...0 {
        let extent=max(abs(dx),abs(dz))
        guard extent==0 || (extent.nonzeroBitCount==1 && (dx==0 || dz==0 || abs(dx)==abs(dz))) else {continue}
        if let b=terrain.waterBody(atX:x+dx,z:z+dz) {possible.append((dx*dx+dz*dz,z+dz,x+dx,b))}
      } }
      let expected=try XCTUnwrap(possible.min {($0.0,$0.1,$0.2)<($1.0,$1.1,$1.2)})
      XCTAssertLessThan(expected.0,12*12);XCTAssertEqual(chosen,expected.3)
    }
  }

  func testLiveBuildersUseTheCanonicalRiverRimAcrossDetailLevels() throws {
    let terrain=TerrainGenerator(seed:1667327165707871140,style:.verdant)
    let point=SIMD2<Int>(928,912)
    var sampler=WaterBodySampling()
    let expected=try XCTUnwrap(sampler.nearest(atX:point.x,z:point.y,
      lookup:{terrain.waterBody(atX:$0,z:$1)}))
    var checked=0
    // Include every incident chunk and coarse tile: the dry endpoint may be
    // on an outer edge rather than inside the tile containing its NW column.
    for size in [1,2,4,8,16] { for dz in [-1,0] { for dx in [-1,0] {
      let x=floorDivide(point.x+dx,by:16*size)*size
      let z=floorDivide(point.y+dz,by:16*size)*size
      let tile=TerrainTile(x:x,z:z,size:size)
      let water:WaterGeometry
      if size==1 {water = .init(WaterPatch.build(terrain.generate(tile.coordinate),terrain:terrain))}
      else {water=TerrainSurface.build(tile,terrain:terrain,measureError:false).water}
      for sample in water.samples where sample.position == SIMD2(Float(point.x-x*16),Float(point.y-z*16)) {
        XCTAssertEqual(sample.body,expected);checked+=1
      }
    } } }
    XCTAssertGreaterThan(checked,1)
  }

  func testDryRimBodiesAgreeAtActuallySharedFineAndCoarseVertices() {
    let terrain=TerrainGenerator(seed:1667327165707871140,style:.verdant)
    var checked=0
    for origin in [ChunkCoordinate(56,54),.init(36,68)] {
      var fine:[SIMD2<Int>:WaterBody]=[:]
      for z in origin.z..<origin.z+4 {for x in origin.x..<origin.x+4 {
        let chunk=terrain.generate(.init(x,z)),mesh=WaterGeometry(WaterPatch.build(chunk,terrain:terrain))
        for v in mesh.samples {
          let p=SIMD2(x*16+Int(v.position.x),z*16+Int(v.position.y))
          if let old=fine[p] {XCTAssertEqual(v.body,old)}
          fine[p]=v.body
        }
      } }
      for size in [2,4,8] {
        let tile=TerrainTile(x:floorDivide(origin.x,by:size)*size,z:floorDivide(origin.z,by:size)*size,size:size)
        let mesh=TerrainSurface.build(tile,terrain:terrain,measureError:false).water
        for v in mesh.samples {
          let p=SIMD2(tile.x*16+Int(v.position.x),tile.z*16+Int(v.position.y))
          if let body=fine[p],terrain.waterBody(atX:p.x,z:p.y)==nil {
            XCTAssertEqual(body,v.body);checked+=1
          }
        }
      }
    }
    XCTAssertGreaterThan(checked,0,"Exercise emitted dry rim vertices in both live builders")
  }

  func testLazyPatchPreservesWetFootprintAndReferencedVoxelDepths() {
    for (seed,style) in [(UInt64(1667327165707871140),PlanetStyle.verdant),(967252643,.solar)] {
      let terrain=TerrainGenerator(seed:seed,style:style)
      for coordinate in [ChunkCoordinate(58,56),.init(37,70),.init(-2,-2)] {
        var chunk=terrain.generate(coordinate)
        chunk[3,25,4] = .wood
        for step in [1,2,4,8,16] {
          let patch=WaterPatch.build(chunk,terrain:terrain,sampleStride:step),side=patch.vertexSide
          let indices=patch.shallowIndices+patch.deepIndices
          let actual=Set(stride(from:0,to:indices.count,by:6).map {Int(indices[$0])})
          var expected=Set<Int>()
          for z in 0..<16/step {for x in 0..<16/step {
            guard let body=terrain.waterBody(atX:coordinate.x*16+x*step,z:coordinate.z*16+z*step) else {continue}
            // Independent reference: enumerate all solid cells under the
            // procedural search ceiling, rather than reusing lazy floor data.
            let ceiling=min(ChunkData.height-1,Int(body.level)+1)
            let solids=(ChunkData.minimumY...ceiling).filter {chunk[x*step,$0,z*step].isSolid}
            let floor=solids.max().map {$0+1} ?? ChunkData.minimumY
            if floor <= Int(body.level)+1 {expected.insert(z*side+x)}
          } }
          XCTAssertEqual(actual,expected)
          for i in Set(indices.map(Int.init)) {
            let body=patch.bodies[i],x=i%side*step,z=i/side*step
            let ceiling=min(ChunkData.height-1,Int(body.level)+1)
            let bottom=(ChunkData.minimumY...ceiling).filter {chunk[x,$0,z].isSolid}.max().map {$0+1} ?? ChunkData.minimumY
            XCTAssertEqual(patch.depths[i],max(0,body.level-Float(bottom)))
          }
        }
      }
    }
  }

  func testUniformWorldOptimizationAgreesWithActualGeneratorBodies() {
    for style in [PlanetStyle.solar,.ember] {
      let terrain=TerrainGenerator(seed:967252643,style:style)
      var seen=0
      survey: for z in stride(from:-8192,through:8192,by:256) {for x in stride(from:-8192,through:8192,by:256) {
        guard terrain.rawHeight(atX:x,z:z)<=TerrainGenerator.seaLevel+1 else {continue}
        if let body=terrain.waterBody(atX:x,z:z) {
          XCTAssertEqual(body,WaterBodySampling.uniformBody(style:style));seen+=1
          if seen>=8 {break survey}
        }
      } }
      XCTAssertGreaterThan(seen,0)
    }
    for style in [PlanetStyle.verdant,.dune,.frost] {XCTAssertNil(WaterBodySampling.uniformBody(style:style))}
  }
}
