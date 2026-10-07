import XCTest
import simd
@testable import WorldCore
@testable import WorldLife

@SimulationActor final class NestingLifecycleTests: XCTestCase {
  func testColossalParentLaysOutsideItsFeetAndHatchesThroughSharedLifecycle() async throws {
    let site=ColossalRexSite(id:17,region:.init(0,0),position:[0,30,0],heightMetres:120,color:.yellow)
    let giant=ColossalRexState(site:site)
    var parent=FaunaRecord(id:17,species:"colossal_trex",home:site.position)
    parent.hunger=0; parent.thirst=0; parent.fatigue=0
    parent.brood = .init(parentID:17); parent.brood?.wait=0
    parent.social = .init(groupID:17,juvenile:false)
    let life=FaunaSimulation(); life.restore([parent])
    let loaded=Set((-4...4).flatMap { x in (-4...4).map { ChunkCoordinate(x,$0) } })
    life.updateNests(parents:[],giant:giant,seconds:0.1,player:site.position,loaded:loaded,
      block:{ $0.y<30 ? .stone:.air })
    let eggs=try XCTUnwrap(life.records.first { $0.id == 17 }?.brood?.eggs)
    XCTAssertEqual(eggs.count,2)
    XCTAssertTrue(eggs.allSatisfy { simd_distance($0.position,site.position)>giant.footprint })
    for _ in 0..<2_000 {
      life.updateNests(parents:[],giant:giant,seconds:0.1,player:site.position,loaded:loaded,
        block:{ $0.y<30 ? .stone:.air })
    }
    let babies=life.hatchReadyEggs(capacity:10,player:site.position,loaded:loaded,block:{ $0.y<30 ? .stone:.air })
    XCTAssertEqual(babies.count,2)
    XCTAssertTrue(babies.allSatisfy { $0.baby && $0.kind == .trex && $0.color == .yellow && $0.groupID == site.id })
    let restored=FaunaSimulation()
    restored.restore(try JSONDecoder().decode([FaunaRecord].self,from:JSONEncoder().encode(life.records)))
    XCTAssertTrue(restored.hatchReadyEggs(capacity:10,player:site.position,loaded:loaded,block:{ $0.y<30 ? .stone:.air }).isEmpty)
  }
  func testBlockedHatchWaitsThenHatchesOnceAcrossRestore() async throws {
    let parent=RexState(id:17,color:.purple,baby:false,position:[4,30,4],groupID:21)
    var brood=DinosaurBrood(parentID:17); brood.wait=0
    XCTAssertTrue(brood.lay(parent:parent,positions:[[4,30,7],[7,30,7]]))
    for _ in 0..<2100 { brood.advance(seconds:0.1,healthy:true) }
    var record=FaunaRecord(id:17,species:"trex",home:parent.home)
    record.brood=brood; record.social = .init(groupID:21,juvenile:false)
    let life=FaunaSimulation(); life.restore([record])
    let loaded:Set<ChunkCoordinate>=[.init(0,0)]
    XCTAssertTrue(life.hatchReadyEggs(capacity:10,player:[4,30,4],loaded:loaded,block:{ _ in .stone }).isEmpty)
    XCTAssertTrue(life.hatchReadyEggs(capacity:0,player:[4,30,4],loaded:loaded,block:{ $0.y<30 ? .stone:.air }).isEmpty)
    let babies=life.hatchReadyEggs(capacity:10,player:[4,30,4],loaded:loaded,block:{ $0.y<30 ? .stone:.air })
    XCTAssertEqual(babies.count,2)
    XCTAssertTrue(babies.allSatisfy { $0.baby && $0.color == .purple && $0.groupID == 21 })
    XCTAssertTrue(life.hatchReadyEggs(capacity:10,player:[4,30,4],loaded:loaded,block:{ $0.y<30 ? .stone:.air }).isEmpty)
    let save=try JSONDecoder().decode([FaunaRecord].self,from:JSONEncoder().encode(life.records))
    let restored=FaunaSimulation(); restored.restore(save)
    XCTAssertTrue(restored.hatchReadyEggs(capacity:10,player:[4,30,4],loaded:loaded,block:{ $0.y<30 ? .stone:.air }).isEmpty)
    let returned=restored.restoredHatchlings(time:10,player:[4,30,4],loaded:loaded,block:{ $0.y<30 ? .stone:.air })
    XCTAssertEqual(Set(returned.map(\.id)),Set(babies.map(\.id)))
  }
}
