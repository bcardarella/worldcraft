import XCTest
@testable import WorldCore

final class AudioAndNestingTests: XCTestCase {
  func testMusicHysteresisHistoryAndEqualPowerTransitions() throws {
    var director=MusicDirector(seed:12)
    XCTAssertFalse(director.observe(.town,at:10))
    XCTAssertFalse(director.observe(.forest,at:14))
    XCTAssertFalse(director.observe(.forest,at:21))
    XCTAssertTrue(director.observe(.forest,at:22))
    director.start(in:.race)
    let tracks=(0..<3).map { MusicTrack(id:"\($0)",title:"\($0)",mood:.race,duration:70,bpm:100,file:"x") }
    var sequence:[String]=[]
    for _ in 0..<6 { sequence.append(try XCTUnwrap(director.next(in:tracks)).id) }
    XCTAssertEqual(Set(sequence.prefix(3)).count,3)
    XCTAssertEqual(Array(sequence.prefix(3)),Array(sequence.suffix(3)))
    for p in stride(from:0.0,through:1,by:0.05) {
      let mix=MusicDirector.crossfade(p)
      XCTAssertEqual(mix.incoming*mix.incoming+mix.outgoing*mix.outgoing,1,accuracy:0.0001)
    }
  }
  func testVoicesStayBoundedAndLongRoarsRetainTheirLifetime() throws {
    var budget=SoundVoiceBudget()
    let roar=try XCTUnwrap(budget.admit(event:"roar",time:0,duration:6,priority:5))
    XCTAssertTrue(budget.expire(at:2).isEmpty)
    for i in 0..<30 { _ = budget.admit(event:"step_\(i)",time:3,duration:1,priority:1) }
    XCTAssertEqual(budget.count,24)
    XCTAssertFalse(budget.expire(at:5).contains(roar.id)); XCTAssertEqual(budget.count,1)
    XCTAssertEqual(budget.expire(at:7),[roar.id])
    XCTAssertNotNil(budget.admit(event:"hit_stone",time:8,duration:1))
    XCTAssertNil(budget.admit(event:"hit_stone",time:8.01,duration:1))
  }
  func testEggsNeedAdultRexAndPersistIncubationWithoutDuplicateClutches() throws {
    let parent=RexState(id:42,color:.pink,baby:false,position:[0,0,0])
    var brood=DinosaurBrood(parentID:42); brood.wait=0
    let baby=RexState(id:43,color:.pink,baby:true,position:[0,0,0])
    XCTAssertFalse(brood.lay(parent:baby,positions:[[2,0,0]]))
    XCTAssertTrue(brood.lay(parent:parent,positions:[[2,0,0],[-2,0,0]]))
    XCTAssertEqual(brood.eggs.count,2); XCTAssertTrue(brood.eggs.allSatisfy { $0.color == RexColor.pink.rawValue })
    XCTAssertFalse(brood.lay(parent:parent,positions:[[5,0,0]]))
    for _ in 0..<100 { brood.advance(seconds:0.1,healthy:true) }
    let saved=try JSONDecoder().decode(DinosaurBrood.self,from:JSONEncoder().encode(brood))
    XCTAssertTrue(saved.isValid); XCTAssertEqual(saved.eggs[0].incubation,10,accuracy:0.001)
    let before=brood.eggs[0].incubation
    brood.advance(seconds:0,healthy:true); XCTAssertEqual(brood.eggs[0].incubation,before)
    for _ in 0..<2000 { brood.advance(seconds:0.1,healthy:true) }
    XCTAssertTrue(brood.eggs.allSatisfy { $0.progress == 1 })
    XCTAssertFalse(brood.lay(parent:parent,positions:[[5,0,0]]))
  }
}
