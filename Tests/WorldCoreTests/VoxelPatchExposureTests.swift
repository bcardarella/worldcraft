import XCTest
@testable import WorldCore

final class VoxelPatchExposureTests: XCTestCase {
  private func reference(_ inputs: [ChunkCoordinate: VoxelPatchExposure.Input],
    openings: (Int,Int,Range<Int>) -> Bool = {_,_,_ in false}) -> Set<BlockPosition> {
    var air=Set<BlockPosition>(),seeds=[BlockPosition]()
    for (key,input) in inputs {
      for z in 0..<16 {for x in 0..<16 where input.columns.contains(x:x,z:z) {
        var y=ChunkData.minimumY
        while y<ChunkData.height {
          let block=input.chunk[x,y,z]
          if block.isOpaque && !block.isFoliage {y+=1;continue}
          let low=y
          repeat {y+=1} while y<ChunkData.height && (!input.chunk[x,y,z].isOpaque || input.chunk[x,y,z].isFoliage)
          for h in low..<y {air.insert(.init(key.x*16+x,h,key.z*16+z))}
          if y==ChunkData.height || openings(key.x*16+x,key.z*16+z,low..<y) {
            seeds.append(.init(key.x*16+x,low,key.z*16+z))
          }
        }
      }}
    }
    var seen=Set(seeds),index=0
    while index<seeds.count {
      let p=seeds[index];index+=1
      for d in VoxelMesher.offsets {
        let q=p+d
        if air.contains(q) && seen.insert(q).inserted {seeds.append(q)}
      }
    }
    return seen
  }
  func testSpanConnectivityMatchesVoxelFloodAcrossNegativeChunkBordersAndMasks() {
    for pattern in 0..<4 {
      var inputs:[ChunkCoordinate:VoxelPatchExposure.Input]=[:]
      for key in [ChunkCoordinate(-1,-1),.init(0,-1)] {
        var chunk=ChunkData(coordinate:key),mask=VoxelColumnMask()
        for z in 0..<6 {for x in 0..<16 {
          if pattern==3 && (x+z)%5==0 {continue}
          mask.include(x:x..<(x+1),z:z..<(z+1))
          for y in ChunkData.minimumY..<8 {chunk[x,y,z] = .stone}
          for y in -6..<8 where (x*17+z*7+y*31+pattern*3+key.x*5)%11>3 {chunk[x,y,z] = .air}
        }}
        inputs[key] = .init(chunk:chunk,columns:mask)
      }
      let expected=reference(inputs)
      guard case let .ready(result)=VoxelPatchExposure.build(inputs) else {return XCTFail("Unexpected incomplete flood")}
      for (key,input) in inputs {for z in 0..<16 {for x in 0..<16 {for y in -8..<10 {
        let p=BlockPosition(key.x*16+x,y,key.z*16+z)
        XCTAssertEqual(result.contains(p),expected.contains(p))
        if !input.columns.contains(x:x,z:z) {XCTAssertFalse(result.contains(p))}
      }}}}
    }
  }
  func testOnlySkyOrExplicitExteriorOpeningsExposeEnclosedCavities() {
    let key=ChunkCoordinate(0,0)
    var chunk=ChunkData(coordinate:key),mask=VoxelColumnMask()
    mask.include(x:0..<4,z:0..<4)
    for z in 0..<4 {for x in 0..<4 {for y in ChunkData.minimumY..<9 {chunk[x,y,z] = .stone}}}
    for x in 0..<4 {chunk[x,3,1] = .air;chunk[x,5,2] = .air}
    let inputs:[ChunkCoordinate:VoxelPatchExposure.Input]=[key:.init(chunk:chunk,columns:mask)]
    guard case let .ready(closed)=VoxelPatchExposure.build(inputs) else {return XCTFail()}
    XCTAssertFalse(closed.contains(.init(1,3,1)));XCTAssertFalse(closed.contains(.init(1,5,2)))
    XCTAssertTrue(closed.contains(.init(1,10,1)))
    let boundary=VoxelColumnBoundary(columns:mask) {mask.contains(x:$0,z:$1)}
    // Supply the outside continuation in the halo, so the seam can identify
    // real candidate caps while the independent flood treats unknown sides as
    // closed unless the caller provides an exterior opening.
    chunk[-1,3,1] = .air;chunk[-1,5,2] = .air
    let seam=TerrainSurfaceSeam.build(chunk,boundary:boundary) {_ in
      [.init(firstHeight:9,lastHeight:9,material:.stone,referenceHeight:9)]}!
    XCTAssertTrue(seam.requiresExpandedDetail)
    XCTAssertFalse(seam.requiresExpandedDetail(using:closed))
    let opening:(Int,Int,Range<Int>)->Bool={x,z,range in x==0 && z==1 && range.contains(3)}
    guard case let .ready(open)=VoxelPatchExposure.build(inputs,exteriorOpening:opening) else {return XCTFail()}
    XCTAssertTrue(seam.requiresExpandedDetail(using:open))
    XCTAssertTrue(open.contains(.init(3,3,1)));XCTAssertFalse(open.contains(.init(1,5,2)))
    XCTAssertEqual(open.exposedFrontier([.init(-1,3,1),.init(-1,5,2)]),[.init(-1,3,1)])
    let expected=reference(inputs,openings:opening)
    for y in -1..<11 {for z in 0..<4 {for x in 0..<4 {XCTAssertEqual(open.contains(.init(x,y,z)),expected.contains(.init(x,y,z)))}}}
  }
  func testBudgetsDoNotPublishPartialExposureAndEmptyDomainsAreValid() {
    let chunk=ChunkData(coordinate:.init(0,0)),input=VoxelPatchExposure.Input(chunk:chunk,columns:.full)
    if case .limitExceeded=VoxelPatchExposure.build([chunk.coordinate:input],maximumColumns:255) {} else {XCTFail()}
    if case .limitExceeded=VoxelPatchExposure.build([chunk.coordinate:input],maximumSpans:255) {} else {XCTFail()}
    guard case let .ready(result)=VoxelPatchExposure.build([chunk.coordinate:input],maximumColumns:256,maximumSpans:256) else {return XCTFail()}
    XCTAssertEqual(result.columnCount,256);XCTAssertEqual(result.spanCount,256)
    guard case let .ready(empty)=VoxelPatchExposure.build([:]) else {return XCTFail()}
    XCTAssertEqual(empty.columnCount,0);XCTAssertFalse(empty.contains(.init(0,0,0)))
  }
  func testCutoutLeavesAndTransparentOrPartialBlocksCannotSealASkyOpening() {
    let transmitters: [Block] = [.leaves, .cherryLeaves, .mapleLeaves, .spruceLeaves,
      .willowLeaves, .glass, .water, .lava, .torch, .lantern, .woodStairsEast]
    let key=ChunkCoordinate(-1,0)
    var mask=VoxelColumnMask();mask.include(x:0..<3,z:0..<3)
    for roof in transmitters + [.stone] {
      var chunk=ChunkData(coordinate:key)
      for z in 0..<3 {for x in 0..<3 {for y in ChunkData.minimumY..<10 {chunk[x,y,z] = .stone}}}
      chunk[1,8,1] = .air;chunk[1,9,1] = roof
      let input=VoxelPatchExposure.Input(chunk:chunk,columns:mask)
      guard case let .ready(result)=VoxelPatchExposure.build([key:input]) else {return XCTFail()}
      XCTAssertEqual(result.contains(.init(-15,8,1)),roof != .stone,"\(roof)")
    }
  }
  func testCancelledExposureAndSeamReturnNoPartialResult() async {
    let chunk=ChunkData(coordinate:.init(0,0)),mask=VoxelColumnMask.full
    let boundary=VoxelColumnBoundary(columns:mask) {mask.contains(x:$0,z:$1)}
    let result=await Task.detached { () -> Bool in
      withUnsafeCurrentTask {$0?.cancel()}
      guard case .cancelled=VoxelPatchExposure.build([:]) else {return false}
      let emptyBoundary=VoxelColumnBoundary(columns:.init()) {_,_ in false}
      guard TerrainSurfaceSeam.build(chunk,boundary:emptyBoundary,surface:{_ in []}) == nil else {return false}
      guard case .cancelled=VoxelPatchExposure.build([chunk.coordinate:.init(chunk:chunk,columns:mask)]) else {return false}
      return TerrainSurfaceSeam.build(chunk,boundary:boundary) {_ in [.init(firstHeight:0,lastHeight:0,material:.stone,referenceHeight:0)]} == nil
    }.value
    XCTAssertTrue(result)
  }
}

extension VoxelPatchExposureTests {
  private func verify(_ incremental: VoxelPatchExposure.Incremental,
    inputs: [ChunkCoordinate: VoxelPatchExposure.IncrementalInput],
    opening: (Int,Int,Range<Int>) -> Bool = {_,_,_ in false}, file: StaticString = #filePath, line: UInt = #line) {
    let full=inputs.mapValues {VoxelPatchExposure.Input(chunk:$0.source.chunk,columns:$0.columns)}
    let expected=reference(full,openings:opening)
    guard case let .ready(rebuilt)=VoxelPatchExposure.build(full,exteriorOpening:opening) else {
      return XCTFail("Reference did not complete",file:file,line:line)
    }
    XCTAssertEqual(incremental.columnCount,rebuilt.columnCount,file:file,line:line)
    XCTAssertEqual(incremental.spanCount,rebuilt.spanCount,file:file,line:line)
    for key in inputs.keys {for z in -1...6 {for x in -1...16 {
      for y in (ChunkData.minimumY-1)...ChunkData.height {
        let p=BlockPosition(key.x*16+x,y,key.z*16+z),want=expected.contains(p)
        if incremental.contains(p) != want || rebuilt.contains(p) != want {
          return XCTFail("Exposure mismatch at \(p)",file:file,line:line)
        }
      }
    }}}
    let probes=inputs.keys.flatMap {key in (-5..<11).map {BlockPosition(key.x*16-1,$0,key.z*16+1)}}
    XCTAssertEqual(incremental.exposedFrontier(probes),rebuilt.exposedFrontier(probes),file:file,line:line)
  }
  private func enclosedChunk(_ coordinate: ChunkCoordinate = .init(0,0)) -> ChunkData {
    var chunk=ChunkData(coordinate:coordinate)
    for z in -1...16 {for x in -1...16 {for y in ChunkData.minimumY..<10 {chunk[x,y,z] = .stone}}}
    for x in 0..<5 {chunk[x,3,1] = .air}
    return chunk
  }
  func testIncrementalGrowthMatchesIndependentFloodAndFullBuildAcrossChunkBorders() {
    for pattern in 0..<3 {
      var sources:[ChunkCoordinate:VoxelPatchExposure.Source]=[:]
      for key in [ChunkCoordinate(-1,-1),.init(0,-1)] {
        var chunk=enclosedChunk(key)
        for z in 0..<6 {for x in 0..<16 {for y in -5..<11 {
          let value=abs(x*7+z*13+y*11+key.x*3+pattern*17)%9
          if value>2 {chunk[x,y,z] = value==4 ? .glass : value==5 ? .leaves : .air}
        }}}
        sources[key] = .init(chunk)
      }
      var graph=VoxelPatchExposure.Incremental(),inputs:[ChunkCoordinate:VoxelPatchExposure.IncrementalInput]=[:]
      var added=0
      for stage in 0..<4 {
        for (key,source) in sources {
          var mask=inputs[key]?.columns ?? .init()
          // Gaps and reverse-order growth exercise all four neighbour links.
          for z in 0..<6 {for x in 0..<16 where (x+z*3)%4<=stage {mask.include(x:x..<(x+1),z:z..<(z+1))}}
          inputs[key] = .init(source:source,columns:mask)
        }
        let opening:(Int,Int,Range<Int>)->Bool={x,z,span in (x+z+stage)%7==0 && span.contains(3)}
        guard case let .ready(change)=graph.update(inputs,exteriorOpening:opening) else {return XCTFail()}
        added+=change.addedColumns
        XCTAssertEqual(added,graph.columnCount)
        verify(graph,inputs:inputs,opening:opening)
      }
    }
  }
  func testIncrementalMergesComponentsAndRemovesIndividualExteriorSeeds() {
    let key=ChunkCoordinate(0,0)
    var chunk=enclosedChunk()
    for y in 3..<ChunkData.height {chunk[4,y,1] = .air}
    let source=VoxelPatchExposure.Source(chunk)
    var mask=VoxelColumnMask();mask.include(x:0..<1,z:1..<2);mask.include(x:2..<3,z:1..<2)
    var graph=VoxelPatchExposure.Incremental()
    for stage in 0..<5 {
      if stage==1 {mask.include(x:1..<2,z:1..<2)}
      if stage==4 {mask.include(x:3..<5,z:1..<2)}
      let opening:(Int,Int,Range<Int>)->Bool={x,_,span in
        span.contains(3) && (stage==0 || (stage==1 && x==2) || (stage==3 && x==1))
      }
      let inputs=[key:VoxelPatchExposure.IncrementalInput(source:source,columns:mask)]
      guard case .ready=graph.update(inputs,exteriorOpening:opening) else {return XCTFail()}
      verify(graph,inputs:inputs,opening:opening)
      XCTAssertEqual(graph.contains(.init(0,3,1)),stage != 2)
      XCTAssertEqual(graph.contains(.init(2,3,1)),stage != 2)
    }
  }
  func testIncrementalKeepsImmutableSnapshotsAndNeverRescansUnchangedColumns() {
    let key=ChunkCoordinate(0,0)
    var chunk=enclosedChunk(),mask=VoxelColumnMask();mask.include(x:0..<3,z:1..<2)
    let source=VoxelPatchExposure.Source(chunk)
    var graph=VoxelPatchExposure.Incremental()
    let inputs=[key:VoxelPatchExposure.IncrementalInput(source:source,columns:mask)]
    let opening:(Int,Int,Range<Int>)->Bool={x,_,span in x==0 && span.contains(3)}
    guard case let .ready(first)=graph.update(inputs,exteriorOpening:opening) else {return XCTFail()}
    XCTAssertEqual(first.addedColumns,3);XCTAssertGreaterThan(first.addedSpans,0)
    let snapshot=graph
    chunk[1,3,1] = .stone
    guard case let .ready(second)=graph.update(inputs) else {return XCTFail()}
    XCTAssertEqual(second.addedColumns,0);XCTAssertEqual(second.addedSpans,0)
    XCTAssertGreaterThan(second.refreshedOpenings,0)
    XCTAssertTrue(snapshot.contains(.init(1,3,1)));XCTAssertFalse(graph.contains(.init(1,3,1)))
    verify(snapshot,inputs:inputs,opening:opening);verify(graph,inputs:inputs)
  }
  func testIncrementalRejectsChangedVoxelOrHaloSourcesAndRemovedOwnershipWithoutMutation() {
    let key=ChunkCoordinate(0,0)
    let chunk=enclosedChunk(),source=VoxelPatchExposure.Source(chunk)
    var mask=VoxelColumnMask();mask.include(x:0..<3,z:1..<2)
    let input=VoxelPatchExposure.IncrementalInput(source:source,columns:mask)
    var graph=VoxelPatchExposure.Incremental()
    guard case .ready=graph.update([key:input],exteriorOpening:{_,_,r in r.contains(3)}) else {return XCTFail()}
    let count=graph.columnCount,spans=graph.spanCount
    for haloOnly in [false,true] {
      var changed=chunk;changed[haloOnly ? -1:1,3,1] = .glass
      let replacement=VoxelPatchExposure.IncrementalInput(source:.init(changed),columns:mask)
      if case .requiresRebuild=graph.update([key:replacement]) {} else {XCTFail()}
    }
    if case .requiresRebuild=graph.update([:]) {} else {XCTFail()}
    var smaller=VoxelColumnMask();smaller.include(x:0..<2,z:1..<2)
    if case .requiresRebuild=graph.update([key:.init(source:source,columns:smaller)]) {} else {XCTFail()}
    XCTAssertEqual(graph.columnCount,count);XCTAssertEqual(graph.spanCount,spans)
    XCTAssertTrue(graph.contains(.init(1,3,1)))
    guard case .ready=graph.update([key:input]) else {return XCTFail()}
    XCTAssertFalse(graph.contains(.init(1,3,1)))
  }
  func testIncrementalBudgetFailuresAreTransactionalAndAllowLaterSmallerUpdates() {
    let key=ChunkCoordinate(0,0),source=VoxelPatchExposure.Source(enclosedChunk())
    for spanLimited in [false,true] {
      var graph=VoxelPatchExposure.Incremental(maximumColumns:spanLimited ? 8:2,maximumSpans:spanLimited ? 4:100)
      var one=VoxelColumnMask();one.include(x:0..<1,z:1..<2)
      guard case .ready=graph.update([key:.init(source:source,columns:one)],exteriorOpening:{_,_,r in r.contains(3)}) else {return XCTFail()}
      var three=VoxelColumnMask();three.include(x:0..<3,z:1..<2)
      if case .limitExceeded=graph.update([key:.init(source:source,columns:three)]) {} else {XCTFail()}
      XCTAssertEqual(graph.columnCount,1);XCTAssertEqual(graph.spanCount,2)
      XCTAssertTrue(graph.contains(.init(0,3,1)));XCTAssertFalse(graph.contains(.init(1,3,1)))
      var two=VoxelColumnMask();two.include(x:0..<2,z:1..<2)
      let inputs=[key:VoxelPatchExposure.IncrementalInput(source:source,columns:two)]
      guard case .ready=graph.update(inputs) else {return XCTFail()}
      verify(graph,inputs:inputs)
    }
    var empty=VoxelPatchExposure.Incremental(maximumColumns:0,maximumSpans:0)
    guard case let .ready(change)=empty.update([:]) else {return XCTFail()}
    XCTAssertEqual(change.addedColumns,0);XCTAssertEqual(empty.spanCount,0)
    var mask=VoxelColumnMask();mask.include(x:0..<1,z:0..<1)
    if case .limitExceeded=empty.update([key:.init(source:source,columns:mask)]) {} else {XCTFail()}
  }
  func testIncrementalSkyTransmissionMatchesAllPartialAndTransparentBlocks() {
    let key=ChunkCoordinate(0,0)
    var mask=VoxelColumnMask();mask.include(x:0..<3,z:0..<3)
    for roof in [Block.leaves,.cherryLeaves,.mapleLeaves,.spruceLeaves,.willowLeaves,.glass,.water,.lava,.torch,.lantern,.woodStairsEast,.stone] {
      var chunk=enclosedChunk();chunk[1,8,1] = .air;chunk[1,9,1] = roof
      let inputs=[key:VoxelPatchExposure.IncrementalInput(source:.init(chunk),columns:mask)]
      var graph=VoxelPatchExposure.Incremental()
      guard case .ready=graph.update(inputs) else {return XCTFail()}
      XCTAssertEqual(graph.contains(.init(1,8,1)),roof != .stone)
      verify(graph,inputs:inputs)
    }
  }
  func testIncrementalCancellationAfterGraphWorkRollsBackTheUpdate() async {
    let key=ChunkCoordinate(0,0),source=VoxelPatchExposure.Source(enclosedChunk())
    var first=VoxelColumnMask();first.include(x:0..<1,z:1..<2)
    var later=VoxelColumnMask();later.include(x:0..<4,z:1..<2)
    let inputs=[key:VoxelPatchExposure.IncrementalInput(source:source,columns:later)]
    var initial=VoxelPatchExposure.Incremental()
    guard case .ready=initial.update([key:.init(source:source,columns:first)],exteriorOpening:{_,_,r in r.contains(3)}) else {return XCTFail()}
    let frozen=initial
    let result=await Task.detached { () -> Bool in
      var graph=frozen,called=false
      let outcome=graph.update(inputs,exteriorOpening:{_,_,_ in
        called=true;withUnsafeCurrentTask {$0?.cancel()};return false
      })
      guard case .cancelled=outcome,called,graph.columnCount==1,graph.spanCount==2,
        graph.contains(.init(0,3,1)),!graph.contains(.init(1,3,1)) else {return false}
      guard case .cancelled=graph.update([:]) else {return false}
      return graph.columnCount==1
    }.value
    XCTAssertTrue(result)
    XCTAssertTrue(frozen.contains(.init(0,3,1)))
  }
  func testIncrementalSolidColumnsNeedNoSpansAndSkySkipsExteriorCallbacks() {
    let key=ChunkCoordinate(-1,0)
    var solid=ChunkData(coordinate:key),mask=VoxelColumnMask()
    mask.include(x:0..<3,z:0..<2)
    for z in 0..<2 {for x in 0..<3 {for y in ChunkData.minimumY..<ChunkData.height {solid[x,y,z] = .stone}}}
    var sealed=VoxelPatchExposure.Incremental(maximumColumns:6,maximumSpans:0)
    let solidInput=[key:VoxelPatchExposure.IncrementalInput(source:.init(solid),columns:mask)]
    guard case let .ready(change)=sealed.update(solidInput) else {return XCTFail()}
    XCTAssertEqual(change.addedColumns,6);XCTAssertEqual(change.addedSpans,0)
    verify(sealed,inputs:solidInput)
    var sky=VoxelPatchExposure.Incremental(maximumColumns:6,maximumSpans:6),calls=0
    let skyInput=[key:VoxelPatchExposure.IncrementalInput(source:.init(.init(coordinate:key)),columns:mask)]
    guard case let .ready(air)=sky.update(skyInput,exteriorOpening:{_,_,_ in calls+=1;return false}) else {return XCTFail()}
    XCTAssertEqual(air.addedSpans,6);XCTAssertEqual(calls,0)
    XCTAssertTrue(sky.contains(.init(-16,ChunkData.minimumY,0)))
    verify(sky,inputs:skyInput)
  }
}
