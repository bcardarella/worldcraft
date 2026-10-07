import XCTest
import simd
@testable import WorldCore

final class VehicleVarietyTests: XCTestCase {
  private func ground(_ p:BlockPosition) -> Block { p.y < 0 ? .stone:.air }
  func testDistinctProfilesAndSharedFineVoxelGeometry() async {
    let preparer=VehicleMeshPreparation()
    XCTAssertEqual(Set((0..<100).map { VehicleKind.spawned(id:UInt64($0),in:.city) }).count,6)
    for kind in VehicleKind.allCases {
      let model=await preparer.prepare(kind)
      XCTAssertEqual(model.parts.count,7)
      XCTAssertGreaterThan(model.parts.flatMap(\.boxes).filter { $0.size.min() < 0.05 }.count,100)
      for part in model.parts { for box in part.boxes {
        let extent=abs(part.pivot+box.center)+box.size/2
        XCTAssertLessThanOrEqual(extent.x,WorldScale.metres(kind.halfWidth)+0.035,"\(kind): \(part.name)")
        XCTAssertLessThanOrEqual(extent.z,WorldScale.metres(kind.halfLength)+0.06,"\(kind): \(part.name)")
        XCTAssertLessThanOrEqual(extent.y,WorldScale.metres(kind.height)+0.06,"\(kind): \(part.name)")
        XCTAssertTrue((0..<9).contains(box.color))
      } }
    }
    var slow=VehiclePhysics(position:.zero,kind:.deliveryVan), fast=VehiclePhysics(position:[20,0,0],kind:.sports)
    for _ in 0..<140 {
      slow.update(deltaTime:0.05,throttle:1,turn:0,brake:0,block:ground)
      fast.update(deltaTime:0.05,throttle:1,turn:0,brake:0,block:ground)
    }
    XCTAssertGreaterThan(fast.speed,slow.speed*1.7)
  }
  func testHandbrakeDriftsAndGripRecovers() {
    var rolling=VehiclePhysics(position:.zero,kind:.sports)
    for _ in 0..<80 { rolling.update(deltaTime:0.05,throttle:1,turn:0,brake:0,block:ground) }
    var drift=rolling, grip=rolling
    for _ in 0..<10 {
      drift.update(deltaTime:0.05,throttle:0.5,turn:0.8,brake:1,block:ground)
      grip.update(deltaTime:0.05,throttle:0,turn:0.8,brake:0,block:ground)
    }
    XCTAssertGreaterThan(drift.slipSpeed,grip.slipSpeed*1.2)
    XCTAssertGreaterThan(simd_length(drift.velocity),3)
    XCTAssertFalse(drift.parkingBrake)
    let slipping=drift.slipSpeed
    for _ in 0..<80 { drift.update(deltaTime:0.05,throttle:0,turn:0,brake:0,block:ground) }
    XCTAssertLessThan(drift.slipSpeed,slipping*0.1)
  }
  func testParkingBrakeLatchesAtRestAndSurvivesSave() throws {
    var car=VehiclePhysics(position:.zero,kind:.luxury)
    car.update(deltaTime:0.05,throttle:0,turn:0,brake:1,block:ground)
    XCTAssertTrue(car.parkingBrake)
    for _ in 0..<30 { car.update(deltaTime:0.05,throttle:1,turn:1,brake:0,block:ground) }
    XCTAssertEqual(car.position,.zero); XCTAssertEqual(car.speed,0)
    let record=VehicleRecord(id:1,siteID:2,position:[0,0,0],heading:0,variant:0,solar:false,kind:car.kind,parkingBrake:car.parkingBrake)
    let saved=try JSONDecoder().decode(VehicleRecord.self,from:JSONEncoder().encode(record))
    XCTAssertEqual(saved.parkingBrake,true); XCTAssertEqual(saved.kind,.luxury)
    car.update(deltaTime:0.05,throttle:0,turn:0,brake:1,block:ground)
    XCTAssertFalse(car.parkingBrake)
    for _ in 0..<30 { car.update(deltaTime:0.05,throttle:1,turn:0,brake:0,block:ground) }
    XCTAssertGreaterThan(car.speed,5)
  }
  func testEveryVehicleClimbsSingleBlockAndRespectsItsSize() {
    let terrain: (BlockPosition)->Block = { $0.y<0 || ($0.z < -8 && $0.y < 1) ? .stone:.air }
    for kind in VehicleKind.allCases {
      var car=VehiclePhysics(position:.zero,kind:kind)
      for _ in 0..<120 { car.update(deltaTime:0.05,throttle:0.4,turn:0,brake:0,block:terrain) }
      XCTAssertLessThan(car.position.z,-12,"\(kind)")
      XCTAssertEqual(car.position.y,1,accuracy:0.05,"\(kind)")
      XCTAssertTrue(VehiclePhysics.isClear(at:car.position,heading:car.heading,kind:kind,block:terrain))
    }
    XCTAssertTrue(VehiclePhysics.overlaps(position:.zero,heading:0,kind:.pickup,
      otherPosition:[0,0,5],otherHeading:0,otherKind:.luxury))
    XCTAssertFalse(VehiclePhysics.overlaps(position:.zero,heading:0,kind:.compact,
      otherPosition:[0,0,5],otherHeading:0,otherKind:.compact))
  }
}
