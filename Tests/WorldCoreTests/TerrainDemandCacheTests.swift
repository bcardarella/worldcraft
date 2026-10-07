import Foundation
import XCTest
@testable import WorldCore

final class TerrainDemandCacheTests: XCTestCase {
  func testCheapInputBypassReleasesPreviouslyHeldStorageAndUsesCurrentInput() {
    var cache=TerrainDemandCache(),created=0
    let id=id()
    _=cache.request(id:id,service:.detail,priority:1) {created+=1;return input(id)}
    XCTAssertEqual(cache.metrics.entries,1)
    for priority in 2...4 {
      let request=cache.request(id:id,service:.collision,priority:priority,cacheInputs:false) {
        created+=1;return input(id,block:.glass)
      }
      XCTAssertEqual(request.edits,[BlockPosition(0,30,0):.glass])
      XCTAssertEqual(request.priority,priority);XCTAssertEqual(request.service,.collision)
      XCTAssertEqual(cache.metrics.entries,0);XCTAssertEqual(cache.metrics.logicalInputBytes,0)
    }
    XCTAssertEqual(created,4);XCTAssertEqual(cache.metrics.bypassed,3)
    XCTAssertEqual(cache.metrics.reused,0);XCTAssertEqual(cache.metrics.released,1)
  }
  private let world = UUID()
  private func id(x:Int=0, revision:Int=0, incarnation:UInt64=0)->TerrainWorkID {
    .init(world:world,tile:.init(x:x,z:0,fullDetail:true),revision:revision,lush:false,incarnation:incarnation)
  }
  private func input(_ id:TerrainWorkID,block:Block = .stone)->TerrainPreparationRequest {
    .init(id:id,terrain:.init(seed:91),edits:[.init(id.tile.x*16,30,id.tile.z*16):block],service:.detail,priority:999)
  }
  func testReprioritizationReusesFrozenEditsPlantsAndUnpublishedVoxels() {
    let id=id(),p=BlockPosition(1,30,2)
    var edits=[p:Block.brick],plants=[p:PlantEdit(position:p,kind:nil)]
    var chunk=ChunkData(coordinate:id.tile.coordinate);chunk[1,30,2] = .glass
    var cache=TerrainDemandCache(),created=0
    let first=cache.request(id:id,service:.detail,priority:9) {
      created+=1
      return .init(id:id,terrain:.init(seed:4),edits:edits,plantEdits:plants,cachedChunk:chunk,service:.detail,priority:9)
    }
    edits[p] = .sand;plants.removeAll();chunk[1,30,2] = .air
    let second=cache.request(id:id,service:.collision,priority:-3) {
      created+=1;return .init(id:id,terrain:.init(seed:4),edits:edits,plantEdits:plants,cachedChunk:chunk,service:.detail,priority:9)
    }
    XCTAssertEqual(created,1);XCTAssertEqual(second.edits,[p:.brick])
    XCTAssertEqual(second.plantEdits,first.plantEdits);XCTAssertEqual(second.cachedChunk?[1,30,2],.glass)
    XCTAssertEqual(second.service,.collision);XCTAssertEqual(second.priority,-3)
    XCTAssertEqual(cache.metrics.reused,1);XCTAssertEqual(cache.metrics.rebuilt,1)
    XCTAssertEqual(cache.metrics.logicalInputBytes,TerrainDemandCache.logicalInputBytes(first))
  }
  func testEveryWorkIdentityChangeRequiresFreshInput() {
    let tile=TerrainTile(x:0,z:0,fullDetail:true)
    let initial=id()
    let variants:[TerrainWorkID]=[
      .init(world:UUID(),tile:tile,revision:0,lush:false),id(revision:1),
      .init(world:world,tile:tile,revision:0,lush:true),id(incarnation:1),
      .init(world:world,tile:tile,revision:0,lush:false,repeatAtlas:true),
      .init(world:world,tile:tile,revision:0,lush:false,instanceSeats:true),
      .init(world:world,tile:.init(x:0,z:0,size:2),revision:0,lush:false,profileSurface:true)]
    for replacement in variants {
      var cache=TerrainDemandCache(),created=0
      _=cache.request(id:initial,service:.detail,priority:1) {created+=1;return input(initial)}
      let value=cache.request(id:replacement,service:.coverage,priority:2) {created+=1;return input(replacement,block:.glass)}
      XCTAssertEqual(created,2);XCTAssertEqual(value.id,replacement)
      XCTAssertTrue(value.edits.values.allSatisfy {$0 == .glass})
      XCTAssertEqual(value.service,.coverage);XCTAssertEqual(value.priority,2)
    }
    // A profile flag matters even when tile, world and revision stay the same.
    var cache=TerrainDemandCache()
    let coarse=TerrainWorkID(world:world,tile:.init(x:0,z:0,size:2),revision:0,lush:false)
    let profiled=variants.last!
    _=cache.request(id:coarse,service:.refinement,priority:0) {input(coarse)}
    _=cache.request(id:profiled,service:.refinement,priority:0) {input(profiled)}
    XCTAssertEqual(cache.metrics.rebuilt,2);XCTAssertEqual(cache.metrics.entries,1)
  }
  func testCancellationReentryPruningAndPlanetResetReleaseHeldInputs() {
    var cache=TerrainDemandCache()
    let a=id(),b=id(x:1)
    for id in [a,b] {_=cache.request(id:id,service:.detail,priority:1) {input(id)}}
    cache.invalidate(a.tile)
    XCTAssertEqual(cache.metrics.entries,1)
    let newA=id(incarnation:2)
    _=cache.request(id:newA,service:.detail,priority:0) {input(newA,block:.glass)}
    cache.retain([a.tile:newA])
    XCTAssertEqual(cache.metrics.entries,1);XCTAssertEqual(cache.metrics.released,2)
    cache.retain([a.tile:id(revision:3)])
    XCTAssertEqual(cache.metrics.entries,0);XCTAssertEqual(cache.metrics.logicalInputBytes,0)
    cache.reset()
    XCTAssertTrue(cache.metrics.enabled);XCTAssertEqual(cache.metrics.rebuilt,0)
    XCTAssertEqual(cache.metrics.reused,0);XCTAssertEqual(cache.metrics.released,0)
  }
  func testCapacityRefusalReturnsCurrentWorkWithoutDroppingOrReusingOldInput() {
    let a=id(),b=id(x:1),charge=TerrainDemandCache.logicalInputBytes(input(id()))
    var cache=TerrainDemandCache(limitEntries:1,limitBytes:charge)
    _=cache.request(id:a,service:.detail,priority:0) {input(a)}
    for _ in 0..<2 {
      let value=cache.request(id:b,service:.collision,priority:2) {input(b,block:.glass)}
      XCTAssertEqual(value.id,b);XCTAssertEqual(value.edits.values.first,.glass)
    }
    XCTAssertEqual(cache.metrics.entries,1);XCTAssertEqual(cache.metrics.refusedAdmissions,2)
    let changed=id(revision:1)
    let value=cache.request(id:changed,service:.detail,priority:1) {
      .init(id:changed,terrain:.init(seed:91),cachedChunk:.init(coordinate:changed.tile.coordinate),service:.detail,priority:1)
    }
    XCTAssertNotNil(value.cachedChunk);XCTAssertEqual(value.id,changed)
    XCTAssertEqual(cache.metrics.entries,0);XCTAssertEqual(cache.metrics.logicalInputBytes,0)
    XCTAssertEqual(cache.metrics.refusedAdmissions,3)
  }
  func testDisabledModeRebuildsIdenticalBaselineDemandAndKeepsNoStorage() {
    var cache=TerrainDemandCache(enabled:false),created=0
    let a=id()
    for priority in 0..<8 {
      let value=cache.request(id:a,service:.coverage,priority:priority) {created+=1;return input(a)}
      XCTAssertEqual(value.priority,priority);XCTAssertEqual(value.service,.coverage)
    }
    XCTAssertEqual(created,8);XCTAssertEqual(cache.metrics.entries,0)
    XCTAssertEqual(cache.metrics.logicalInputBytes,0);XCTAssertFalse(cache.metrics.enabled)
  }
  func testCachedInputProducesByteIdenticalCompletePreparedPayloads() throws {
    for style in [PlanetStyle.verdant,.dune,.solar] {for coarse in [false,true] {for atlas in [false,true] {
      let tile=TerrainTile(x:10,z:-8,size:coarse ? 2:1,fullDetail:!coarse)
      let work=TerrainWorkID(world:world,tile:tile,revision:2,lush:!coarse,repeatAtlas:atlas)
      let terrain=TerrainGenerator(seed:1667327165707871140,style:style)
      let p=BlockPosition(tile.x*16+3,40,tile.z*16+2)
      var supplied=terrain.generate(tile.coordinate);supplied[3,40,2] = .glass
      let source=TerrainPreparationRequest(id:work,terrain:terrain,edits:[p:.glass,p + .init(-4,0,0):.air],
        plantEdits:[p:.init(position:p,kind:nil)],cachedChunk:coarse ? nil:supplied,service:.detail,priority:99)
      var cache=TerrainDemandCache()
      _=cache.request(id:work,service:.detail,priority:99) {source}
      let reused=cache.request(id:work,service:.collision,priority:0) {XCTFail("Input must be reused");return source}
      let first=try XCTUnwrap(TerrainPreparation.build(source,cache:.init(limitBytes:1),cullHidden:true,collision:{_ in}))
      let second=try XCTUnwrap(TerrainPreparation.build(reused,cache:.init(limitBytes:1),cullHidden:true,collision:{_ in}))
      let a=try XCTUnwrap(TerrainPayloadCodec.encode(first,key:.init(source)))
      let b=try XCTUnwrap(TerrainPayloadCodec.encode(second,key:.init(reused)))
      XCTAssertEqual(a,b,"\(style) coarse=\(coarse) atlas=\(atlas)")
    }}}
  }
  func testReusedRequestsKeepCurrentServiceSelectionAndLongRouteStaysBounded() {
    var cache=TerrainDemandCache(limitEntries:8,limitBytes:8_192)
    let a=id(),b=id(x:1)
    for work in [a,b] {_=cache.request(id:work,service:.detail,priority:0) {input(work)}}
    let first=cache.request(id:a,service:.coverage,priority:9) {input(a)}
    let second=cache.request(id:b,service:.coverage,priority:-9) {input(b)}
    var turn=0
    XCTAssertEqual(TerrainServiceOrder.next([first,second],turn:&turn)?.id,b)
    for i in 0..<3_000 {
      let work=id(x:i%16,incarnation:UInt64(i+1))
      cache.retain([work.tile:work])
      let result=cache.request(id:work,service:.detail,priority:i) {input(work)}
      XCTAssertEqual(result.id,work)
      XCTAssertEqual(cache.metrics.entries,1)
      XCTAssertLessThanOrEqual(cache.metrics.logicalInputBytes,cache.metrics.limitBytes)
    }
    cache.retain([:]);XCTAssertEqual(cache.metrics.logicalInputBytes,0)
  }
}
