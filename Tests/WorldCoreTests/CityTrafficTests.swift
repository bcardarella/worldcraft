import XCTest
import simd
@testable import WorldCore

final class CityTrafficTests: XCTestCase {
  private let city=Settlement(id:42,kind:.city,name:"Traffic city",x:0,z:0,floor:30,ground:.grass)
  private func movingIndex() throws -> Int {
    try XCTUnwrap((0..<city.vehicleCount).first { CityTrafficDriver.spawned(in:city,index:$0).isActive })
  }
  private func record(_ physics: VehiclePhysics, index:Int, traffic:CityTrafficDriver?) -> VehicleRecord {
    .init(id:CityTrafficDriver.carID(in:city,index:index),siteID:city.id,
      position:[physics.position.x,physics.position.y,physics.position.z],heading:physics.heading,
      variant:0,solar:false,kind:physics.kind,parkingBrake:physics.parkingBrake,traffic:traffic)
  }
  private func road(_ p:BlockPosition) -> Block { p.y < city.floor ? .basalt:.air }

  func testTrafficResumesAfterArchiveAndPresentationUnload() throws {
    let index=try movingIndex()
    var car=VehiclePhysics(position:city.vehiclePosition(index)),driver=CityTrafficDriver.spawned(in:city,index:index)
    for _ in 0..<300 {driver.update(physics:&car,seconds:1/30,block:road)}
    let archive=WorldSave(seed:42,edits:[],player:[0,30,0],flying:false,heading:0,selectedSlot:0,
      vehicles:[record(car,index:index,traffic:driver)])
    let saved=try JSONDecoder().decode(WorldSave.self,from:JSONEncoder().encode(archive))
    let stored=try XCTUnwrap(saved.vehicles?.first)
    var resumed=try XCTUnwrap(stored.restoredTraffic(in:nil))
    XCTAssertEqual(resumed.route,driver.route);XCTAssertEqual(resumed.waypoint,driver.waypoint)
    var restoredCar=VehiclePhysics(position:car.position,heading:car.heading)
    let start=restoredCar.position
    for _ in 0..<120 {resumed.update(physics:&restoredCar,seconds:1/30,block:road)}
    XCTAssertGreaterThan(simd_distance(restoredCar.position,start),5)
    // Stream out/in again, without a settlement currently in view.
    let streamed=record(restoredCar,index:index,traffic:resumed)
    XCTAssertTrue(try XCTUnwrap(streamed.restoredTraffic(in:nil)).isActive)
  }
  func testLegacyTrafficRecoversButExplicitlyParkedAndBrakedCarsDoNot() throws {
    let index=try movingIndex(),car=VehiclePhysics(position:city.vehiclePosition(index))
    let old=record(car,index:index,traffic:nil)
    let json=try JSONEncoder().encode(old)
    XCTAssertFalse(String(decoding:json,as:UTF8.self).contains("traffic"))
    let decoded=try JSONDecoder().decode(VehicleRecord.self,from:json)
    XCTAssertNil(decoded.restoredTraffic(in:nil))
    XCTAssertTrue(try XCTUnwrap(decoded.restoredTraffic(in:city)).isActive)
    let parked=record(car,index:index,traffic:.parked)
    XCTAssertFalse(try XCTUnwrap(parked.restoredTraffic(in:city)).isActive)
    let braked=VehiclePhysics(position:car.position,parkingBrake:true)
    XCTAssertFalse(try XCTUnwrap(record(braked,index:index,traffic:nil).restoredTraffic(in:city)).isActive)
    let moved=VehiclePhysics(position:car.position+[30,0,30])
    XCTAssertFalse(try XCTUnwrap(record(moved,index:index,traffic:nil).restoredTraffic(in:city)).isActive)
    let track=VehicleRecord(id:RaceGarage.carID(track:9,bay:0),siteID:9,position:[0,30,0],heading:0,variant:0,solar:false,kind:.race)
    XCTAssertFalse(try XCTUnwrap(track.restoredTraffic(in:city)).isActive)
  }
  func testCorruptRoutesAreRejectedWithoutIndexingThem() {
    let p=VehiclePhysics(position:city.center)
    let invalid: [CityTrafficDriver] = [.init(route:[.zero],waypoint:3),
      .init(route:[.zero,[1,0,4],[.infinity,0,0]]),.init(route:[],waypoint:2)]
    for state in invalid {
      XCTAssertFalse(record(p,index:1,traffic:state).isValid)
      var driver=state,car=p
      driver.update(physics:&car,seconds:1/30,block:road)
      XCTAssertEqual(car.position,p.position)
    }
  }
  func testCityRoutesStayOnStreetsAndStillIncludeMovingTraffic() {
    var moving=0,parked=0
    for i in 0..<city.vehicleCount {
      let driver=CityTrafficDriver.spawned(in:city,index:i)
      if driver.isActive {moving+=1} else {parked+=1}
      for point in driver.route {XCTAssertTrue(city.isRoad(atX:Int(point.x),z:Int(point.z)))}
    }
    XCTAssertGreaterThan(moving,4);XCTAssertGreaterThan(parked,0)
  }
}
