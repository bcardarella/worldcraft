import XCTest
import simd
@testable import WorldCore

final class TownNavigationTests: XCTestCase {
  func flat(_ p: BlockPosition) -> Block { p.y < 0 ? .stone : .air }
  func testPeoplePassEachOtherAndAnIdlePerson() {
    var a = SIMD3<Float>(-4,0,0), b = SIMD3<Float>(4,0,0)
    for _ in 0..<240 {
      let neighbors: [ResidentCrowd.Neighbor] = [.init(id:1,position:a,velocity:[1.4,0,0]),.init(id:2,position:b,velocity:[-1.4,0,0]),.init(id:3,position:[0,0,1.5])]
      a = ResidentCrowd.step(id:1,position:a,target:[4,0,0],speed:1.4,seconds:1/15,neighbors:neighbors,navigable:{ ResidentNavigation.walkingPosition(at:$0,block:self.flat) }) ?? a
      b = ResidentCrowd.step(id:2,position:b,target:[-4,0,0],speed:1.4,seconds:1/15,neighbors:neighbors,navigable:{ ResidentNavigation.walkingPosition(at:$0,block:self.flat) }) ?? b
      XCTAssertGreaterThan(simd_distance(a,b),0.8)
    }
    XCTAssertGreaterThan(a.x,3); XCTAssertLessThan(b.x,-3)
  }
  func testOldOverlapsSeparateAndSteeringNeverEntersWall() {
    var a = SIMD3<Float>(0.5,0,0.5), b = a
    for _ in 0..<90 {
      let neighbors: [ResidentCrowd.Neighbor] = [.init(id:1,position:a),.init(id:2,position:b)]
      a = ResidentCrowd.step(id:1,position:a,target:a,speed:1.4,seconds:1/15,neighbors:neighbors,navigable:{$0}) ?? a
      b = ResidentCrowd.step(id:2,position:b,target:b,speed:1.4,seconds:1/15,neighbors:neighbors,navigable:{$0}) ?? b
    }
    XCTAssertGreaterThan(simd_distance(a,b),0.90)
    func wall(_ p: BlockPosition) -> Block { p.y < 0 || p.x == 2 ? .stone : .air }
    for _ in 0..<90 {
      a = ResidentCrowd.step(id:1,position:a,target:[5,0,0],speed:1.4,seconds:1/15,neighbors:[],navigable:{ResidentNavigation.walkingPosition(at:$0,block:wall)}) ?? a
      XCTAssertLessThan(a.x+ResidentNavigation.radius,2.001)
    }
  }
  func testTrafficPredictsForwardReverseAndSweptBumpsButIgnoresParkedCars() throws {
    func car(_ from: SIMD3<Float>, _ to: SIMD3<Float>, _ velocity: SIMD3<Float>) -> VehicleTraffic {
      .init(id:1,position:to,previousPosition:from,velocity:velocity,heading:0,playerDriven:true)
    }
    XCTAssertNil(car(.zero,.zero,.zero).reaction(at:[0,0,-1],personID:1,navigable:{$0}))
    XCTAssertFalse(try XCTUnwrap(car(.zero,.zero,[0,0,-8]).reaction(at:[0,0,-7],personID:1,navigable:{$0})).bumped)
    XCTAssertNotNil(car(.zero,.zero,[0,0,8]).reaction(at:[0,0,7],personID:1,navigable:{$0}))
    XCTAssertNil(car(.zero,.zero,[0,0,-8]).reaction(at:[8,0,-7],personID:1,navigable:{$0}))
    let swept = try XCTUnwrap(car([0,0,5],[0,0,-5],.zero).reaction(at:.zero,personID:1,navigable:{$0}))
    XCTAssertTrue(swept.bumped); XCTAssertGreaterThan(abs(swept.target.x),1.8)
    let opposite = try XCTUnwrap(car(.zero,.zero,[0,0,-8]).reaction(at:[0,0,-7],personID:1,navigable:{$0.x < 0 ? nil : $0}))
    XCTAssertGreaterThan(opposite.target.x,0)
    XCTAssertNil(car(.zero,.zero,[0,0,-8]).reaction(at:[0,0,-1],personID:1,navigable:{_ in nil}))
  }
  func testExitSearchFindsDistantFootingAndRejectsTrappedRoof() throws {
    let car = VehiclePhysics(position:[0,0.27,0])
    let exit = try XCTUnwrap(car.exitPosition(block: { p in p.y < 0 ? .stone : (abs(p.x) < 5 && abs(p.z) < 5 ? .water : .air) }))
    XCTAssertEqual(exit.y,0.02,accuracy:0.001)
    XCTAssertTrue(abs(exit.x) >= 5 || abs(exit.z) >= 5)
    XCTAssertNil(car.roofExit(block:{_ in .stone}))
    XCTAssertNotNil(car.roofExit(block:flat))
  }
  func testWiderRoadsHaveCarClearanceAndSidewalks() throws {
    let t = TerrainGenerator(seed:8192)
    let site = try XCTUnwrap(SettlementGenerator.site(in:.init(0,0),terrain:t))
    for n in -20...20 {
      XCTAssertTrue(VehiclePhysics.isClear(at:site.center+[0.5,0,Float(n)+0.5],heading:0,block:t.block))
    }
    XCTAssertGreaterThanOrEqual(site.streetHalfWidth,3)
    XCTAssertEqual(t.block(at:.init(site.x+site.streetHalfWidth+1,site.floor-1,site.z+7)),.limestone)
  }
}
