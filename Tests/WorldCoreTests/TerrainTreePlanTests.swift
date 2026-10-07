import Foundation
import XCTest
@testable import WorldCore

final class TerrainTreePlanTests: XCTestCase, @unchecked Sendable {
  private func scalar(x: Range<Int>, z: Range<Int>, terrain: TerrainGenerator,
    order: TerrainTreePlans.Order) -> [TreeDescriptor] {
    var result: [TreeDescriptor] = []
    for tx in x { for tz in z { if let tree = terrain.tree(atX:tx,z:tz) { result.append(tree) } } }
    if order == .zThenX { result.sort { ($0.z,$0.x) < ($1.z,$1.x) } }
    return result
  }

  func testRegionQueriesMatchEveryScalarPlacementAndBothOrdersAcrossBoundaries() {
    let cache = TreePlanCache()
    for seed: UInt64 in [967252643,1667327165707871140] { for style in PlanetStyle.allCases {
      let terrain = TerrainGenerator(seed:seed,style:style)
      for (x,z) in [(-69,-5),(19*16-5,51*16-5),(503,1015)] {
        for order in [TerrainTreePlans.Order.xThenZ,.zThenX] {
          let xr = x..<(x+74), zr = z..<(z+69)
          XCTAssertEqual(TerrainTreePlans.trees(x:xr,z:zr,terrain:terrain,order:order,cache:cache),
            scalar(x:xr,z:zr,terrain:terrain,order:order))
        }
      }
    } }
    XCTAssertLessThanOrEqual(cache.metrics.bytes,cache.metrics.limitBytes)
    XCTAssertGreaterThan(cache.metrics.hits,0)
  }

  func testMarinaShoreAndSurveyVariantMatchScalarAndHaveSeparateKeys() throws {
    let terrain = TerrainGenerator(seed:967252643)
    let site = try XCTUnwrap(MarinaGenerator.site(in:.init(-2,0),terrain:terrain))
    let x=(site.x-72)..<(site.x+73),z=(site.z-72)..<(site.z+73),cache=TreePlanCache()
    for source in [terrain,terrain.marinaSurveyTerrain] {
      XCTAssertEqual(TerrainTreePlans.trees(x:x,z:z,terrain:source,order:.zThenX,cache:cache),
        scalar(x:x,z:z,terrain:source,order:.zThenX))
    }
    let coordinate=ChunkCoordinate(1,-2)
    XCTAssertNotEqual(TreePlanCache.Key(terrain:terrain,coordinate:coordinate),TreePlanCache.Key(terrain:terrain.marinaSurveyTerrain,coordinate:coordinate))
    XCTAssertNotEqual(TreePlanCache.Key(terrain:terrain,coordinate:coordinate),TreePlanCache.Key(terrain:.init(seed:968252643),coordinate:coordinate))
    XCTAssertNotEqual(TreePlanCache.Key(terrain:terrain,coordinate:coordinate),TreePlanCache.Key(terrain:.init(seed:terrain.seed,style:.frost),coordinate:coordinate))
  }

  func testVoxelHaloAndCompleteArchivesPreserveTreeOverlapAndEdits() throws {
    for style in PlanetStyle.allCases { for coordinate in [ChunkCoordinate(19,51),.init(-2,-3)] {
      let indexed=TerrainGenerator(seed:967252643,style:style),scalar=TerrainGenerator(seed:967252643,style:style,indexedTrees:false)
      let edits:[BlockPosition:Block]=[.init(coordinate.x*16,40,coordinate.z*16):.air,
        .init(coordinate.x*16+16,44,coordinate.z*16):.glass]
      XCTAssertEqual(indexed.generate(coordinate,edits:edits).archiveCells,scalar.generate(coordinate,edits:edits).archiveCells)
      let id=TerrainWorkID(world:UUID(),tile:.init(x:coordinate.x,z:coordinate.z,fullDetail:true),revision:0,lush:true,repeatAtlas:true)
      let a=TerrainPreparationRequest(id:id,terrain:indexed,edits:edits,service:.detail,priority:0)
      let b=TerrainPreparationRequest(id:id,terrain:scalar,edits:edits,service:.detail,priority:0)
      XCTAssertEqual(TerrainPayloadKey(a),TerrainPayloadKey(b))
      let ma=try XCTUnwrap(TerrainPreparation.build(a,cache:TerrainPayloadCache(),cullHidden:true,collision:{_ in}))
      let mb=try XCTUnwrap(TerrainPreparation.build(b,cache:TerrainPayloadCache(),cullHidden:true,collision:{_ in}))
      XCTAssertEqual(try XCTUnwrap(TerrainPayloadCodec.encode(ma,key:.init(a))),try XCTUnwrap(TerrainPayloadCodec.encode(mb,key:.init(b))))
    } }
  }

  func testDistantCanopyGeometryMatchesScalarAtAllGroupingScales() {
    for style in [PlanetStyle.verdant,.frost,.aurora] {
      for size in [2,8,16,32] {
        let tile=TerrainTile(x:-32,z:32,size:size)
        let indexed=TerrainGenerator(seed:967252643,style:style),scalar=TerrainGenerator(seed:967252643,style:style,indexedTrees:false)
        let a=TerrainSurface.build(tile,terrain:indexed,measureError:false),b=TerrainSurface.build(tile,terrain:scalar,measureError:false)
        XCTAssertEqual(a.mesh.positions,b.mesh.positions)
        XCTAssertEqual(a.mesh.normals,b.mesh.normals)
        XCTAssertEqual(a.mesh.textureCoordinates,b.mesh.textureCoordinates)
        XCTAssertEqual(a.mesh.materials,b.mesh.materials)
        XCTAssertEqual(a.mesh.indices,b.mesh.indices)
        XCTAssertEqual(a.water,b.water)
      }
    }
  }

  func testByteBudgetAccountsForReservedCapacityNegativePlansAndIncrementalEviction() {
    let terrain=TerrainGenerator(seed:1)
    func key(_ i:Int)->TreePlanCache.Key {.init(terrain:terrain,coordinate:.init(i,0))}
    let tree=TreeDescriptor(species:.oak,x:0,z:0,ground:30,height:15)
    var reserved:[TreeDescriptor]=[];reserved.reserveCapacity(1_000);reserved.append(tree)
    XCTAssertGreaterThan(TreePlanCache.charge(reserved),TreePlanCache.charge([tree])*10)
    let cache=TreePlanCache(limitBytes:1_024,limitEntries:3)
    XCTAssertEqual(cache.value(for:key(1)){[tree]},[tree])
    XCTAssertEqual(cache.value(for:key(2)){[]},[])
    let held=cache.value(for:key(3)){[tree]}
    XCTAssertEqual(cache.value(for:key(1)){XCTFail("hot miss");return []},[tree])
    _=cache.value(for:key(4)){[tree]}
    XCTAssertEqual(cache.metrics.evictions,1)
    XCTAssertEqual(cache.value(for:key(3)){XCTFail("flushed hot plan");return []},held)
    XCTAssertEqual(cache.value(for:key(5)){reserved},reserved)
    XCTAssertEqual(cache.metrics.oversized,1)
    XCTAssertEqual(cache.metrics.entries,3)
    for i in 6..<606 {_=cache.value(for:key(i)){i%2==0 ? []:[tree]};XCTAssertLessThanOrEqual(cache.metrics.bytes,1_024)}
    XCTAssertEqual(held,[tree],"Eviction cannot invalidate a worker's immutable snapshot")
    XCTAssertEqual(cache.metrics.entries,3)
  }

  func testConcurrentMissIsBuiltOnceAndCancelledOwnerCannotPoisonCache() async {
    let cache=TreePlanCache(),key=TreePlanCache.Key(terrain:.init(seed:7),coordinate:.init(0,0))
    let tree=TreeDescriptor(species:.oak,x:0,z:0,ground:30,height:15)
    let outputs=await withTaskGroup(of:[TreeDescriptor].self,returning:[[TreeDescriptor]].self) {group in
      for _ in 0..<8 {group.addTask {cache.value(for:key){Thread.sleep(forTimeInterval:0.04);return [tree]}}}
      var outputs:[[TreeDescriptor]]=[];for await value in group {outputs.append(value)};return outputs
    }
    XCTAssertEqual(outputs,Array(repeating:[tree],count:8));XCTAssertEqual(cache.metrics.misses,1)
    XCTAssertEqual(cache.metrics.hits,7);XCTAssertGreaterThan(cache.metrics.sharedWaits,0)
    let other=TreePlanCache.Key(terrain:.init(seed:8),coordinate:.init(0,0))
    let started=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
    let task=Task.detached {cache.value(for:other){started.signal();release.wait();return []}}
    await Task.detached {Self.wait(started)}.value
    task.cancel();release.signal();_=await task.value
    XCTAssertEqual(cache.metrics.entries,1);XCTAssertEqual(cache.metrics.inFlight,0)
    XCTAssertEqual(cache.value(for:other){[tree]},[tree])
    XCTAssertEqual(cache.metrics.entries,2)
  }
  @MainActor func testMainActorUsesProceduralFallbackWithoutWaitingForWorker() async {
    let cache=TreePlanCache(),key=TreePlanCache.Key(terrain:.init(seed:41),coordinate:.init(0,0))
    let started=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
    let task=Task.detached {cache.value(for:key){started.signal();release.wait();return []}}
    await Task.detached {Self.wait(started)}.value
    var fallback=false
    _=cache.value(for:key){fallback=true;return []}
    XCTAssertTrue(fallback);XCTAssertEqual(cache.metrics.inFlight,1)
    release.signal();_=await task.value
    XCTAssertEqual(cache.metrics.misses,1)
    XCTAssertEqual(cache.metrics.entries,1)
  }
  private static func wait(_ semaphore: DispatchSemaphore) { semaphore.wait() }
}
