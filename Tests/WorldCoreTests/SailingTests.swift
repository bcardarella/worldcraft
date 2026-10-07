import XCTest
import simd
@testable import WorldCore

final class SailingTests: XCTestCase {
  let water=WaterSample(height:24,normal:[0,1,0])
  func sailing(_ kind:BoatKind = .sloop, heading:Float) -> SailingPhysics {
    var p=SailingPhysics(kind:kind,position:[0,24,0],heading:heading)
    p.anchored=false;p.sailRaised=true;return p
  }
  func advance(_ p:inout SailingPhysics,seconds:Int=30,wind:SIMD3<Float>=[0,0,5],
    current:SIMD3<Float> = .zero,controls:SailingControls = .init()) {
    for _ in 0..<(seconds*60) {p.update(deltaTime:1/60,controls:controls,wind:wind,current:current,water:water)}
  }
  func testWindPowersAllThreeHullsAndNoGoZoneCannotMakeUpwindProgress() {
    for kind in BoatKind.allCases where !kind.isMotorized {
      var head=sailing(kind,heading:0);advance(&head)
      XCTAssertGreaterThanOrEqual(head.position.z,0)
      XCTAssertTrue(head.luffing)
      var reach=sailing(kind,heading:.pi/2);advance(&reach)
      XCTAssertGreaterThan(reach.speed,0.8)
      XCTAssertLessThan(reach.position.x,-25)
      XCTAssertFalse(reach.luffing)
      var calm=sailing(kind,heading:.pi/2);advance(&calm,wind:.zero)
      XCTAssertEqual(calm.speed,0,accuracy:0.0001)
    }
  }
  func testMirroredTacksGainGroundToWindwardWithOppositeLeeway() {
    var port=sailing(heading:.pi/3),starboard=sailing(heading:-.pi/3)
    advance(&port);advance(&starboard)
    XCTAssertLessThan(port.position.z,-20);XCTAssertLessThan(starboard.position.z,-20)
    XCTAssertEqual(port.position.x,-starboard.position.x,accuracy:0.01)
    XCTAssertEqual(port.position.z,starboard.position.z,accuracy:0.01)
    XCTAssertEqual(port.heel,-starboard.heel,accuracy:0.01)
    XCTAssertGreaterThan(port.boomAngle*starboard.boomAngle * -1,0)
  }
  func testManualSheetingCanLuffAndAutomaticTrimRecovers() {
    var p=sailing(heading:.pi/2);advance(&p)
    let speed=p.speed
    advance(&p,controls:.init(sheet:-1))
    XCTAssertFalse(p.automaticTrim);XCTAssertTrue(p.luffing)
    XCTAssertLessThan(p.speed,speed*0.6)
    p.automaticTrim=true;advance(&p)
    XCTAssertFalse(p.luffing);XCTAssertGreaterThan(p.speed,speed*0.8)
  }
  func testCurrentCarriesLoweredSailsButAnchorHoldsAndResumeHasNoCatchUp() {
    var p=sailing(heading:.pi/2);p.sailRaised=false
    advance(&p,wind:.zero,current:[0,0,1.5])
    XCTAssertGreaterThan(p.position.z,60)
    p.moor();let anchored=p.position
    advance(&p,wind:[10,0,10],current:[1,0,3])
    XCTAssertEqual(p.position,anchored)
    var short=sailing(heading:.pi/2),long=short
    short.update(deltaTime:0.05,controls:.init(),wind:[5,0,5],current:.zero,water:water)
    long.update(deltaTime:12,controls:.init(),wind:[5,0,5],current:.zero,water:water)
    XCTAssertEqual(short.position,long.position)
    XCTAssertEqual(short.velocity,long.velocity)
  }
  func testRudderNeedsWaterFlowAndAuxiliaryIsDistinctFromSailing() {
    var p=sailing(heading:0);p.sailRaised=false
    advance(&p,wind:.zero,controls:.init(rudder:1))
    XCTAssertEqual(p.heading,0)
    advance(&p,wind:.zero,controls:.init(rudder:0,auxiliary:1))
    XCTAssertLessThan(p.position.z,-20)
    let before=p.heading
    advance(&p,seconds:5,wind:.zero,controls:.init(rudder:1,auxiliary:1))
    XCTAssertLessThan(p.heading,before-0.1)
  }
  func testKeelRejectsShallowsLavaAndPontoonEvenBeforeTerrainIsRendered() {
    let p=SIMD3<Float>(0,24,0)
    let deep:(Int,Int)->TerrainColumn={_,_ in .init(height:8,surface:.sand,water:.ocean)}
    let shallow:(Int,Int)->TerrainColumn={_,_ in .init(height:22,surface:.sand,water:.ocean)}
    for kind in BoatKind.allCases {
      XCTAssertTrue(SailingPhysics.isNavigable(position:p,heading:0,kind:kind,column:deep,block:{_ in .water}))
      XCTAssertEqual(SailingPhysics.isNavigable(position:p,heading:0,kind:kind,column:shallow,block:{_ in .water}),kind.draft<0.5)
      XCTAssertFalse(SailingPhysics.isNavigable(position:p,heading:0,kind:kind,column:{_,_ in .init(height:8,surface:.basalt,water:.lava)},block:{_ in .lava}))
      XCTAssertFalse(SailingPhysics.isNavigable(position:p,heading:0,kind:kind,column:deep,block:{$0.y == 26 ? .wood:.water}))
    }
    var boat=sailing(heading:.pi/2)
    for _ in 0..<1800 {boat.update(deltaTime:1/60,controls:.init(),wind:[0,0,8],current:.zero,water:water,
      navigable:{$0.x > -20 && abs($0.z)<100 && $1.isFinite && $2 == .sloop})}
    XCTAssertGreaterThan(boat.position.x,-20)
    XCTAssertTrue(boat.isValid)
  }
  func testExitPrefersDryDockAndAllowsSwimmingInOpenWater() throws {
    let p=SailingPhysics(kind:.sloop,position:[0,24,0],heading:0)
    let open:(BlockPosition)->Block={$0.y<24 ? .water:.air}
    let swim=try XCTUnwrap(p.exitPosition(block:open,water:{_,_ in .ocean}))
    XCTAssertLessThan(swim.y,24)
    XCTAssertGreaterThan(abs(swim.x),WorldScale.blocks(p.kind.beam/2))
    let dock:(BlockPosition)->Block={ q in q.x < -3 && q.y == 26 ? .wood:open(q) }
    let dry=try XCTUnwrap(p.exitPosition(block:dock,water:{_,_ in .ocean}))
    XCTAssertEqual(dry.y,27.01,accuracy:0.01)
    XCTAssertNil(p.exitPosition(block:{_ in .stone},water:{_,_ in .ocean}))
  }
  func testSaveCompatibilityBoatRoundTripAndValidation() throws {
    let old=Data(#"{"version":1,"seed":42,"edits":[],"player":[0,30,0],"flying":false,"heading":0,"selectedSlot":0}"#.utf8)
    let previous=try JSONDecoder().decode(WorldSave.self,from:old)
    XCTAssertNil(previous.boats);XCTAssertNil(previous.boatDriver);XCTAssertTrue(previous.isValid)
    var save=previous
    save.boats=[.init(id:1,marina:2,physics:sailing(heading:1))];save.boatDriver=1
    let decoded=try JSONDecoder().decode(WorldSave.self,from:JSONEncoder().encode(save))
    XCTAssertEqual(decoded.boats?.first?.physics.kind,.sloop);XCTAssertEqual(decoded.boatDriver,1)
    XCTAssertTrue(decoded.isValid)
    save.boatDriver=9;XCTAssertFalse(save.isValid)
    save.boatDriver=nil;let duplicate=save.boats![0];save.boats?.append(duplicate);XCTAssertFalse(save.isValid)
    var invalid=sailing(heading:0);invalid.position.x = .nan
    XCTAssertFalse(invalid.isValid)
  }
  func testBoatModelsAreFiniteAndCarWheelLeavesRoadViewClear() {
    for kind in BoatKind.allCases {
      let parts=BoatModel.parts(for:kind)
      XCTAssertEqual(parts.count,kind.isMotorized ? 1:5)
      XCTAssertLessThan(parts.reduce(0){$0+$1.boxes.count},1_200)
      for part in parts {for box in part.boxes {
        XCTAssertTrue((0..<3).allSatisfy{box.size[$0]>0 && box.size[$0].isFinite && box.center[$0].isFinite})
      }}
    }
    for kind in VehicleKind.allCases {
      let parts=VehicleModel.parts(for:kind),eye=VehiclePhysics(position:.zero,heading:0,kind:kind).eye*WorldScale.metresPerBlock
      let wheel=parts.first{$0.name=="Steering wheel"}!
      let highest=wheel.boxes.map{$0.center.y+$0.size.y/2+wheel.pivot.y}.max()!
      // Every wheel lies at least 25° below the driver's forward sightline.
      XCTAssertLessThan(atan2(highest-eye.y,eye.z-wheel.pivot.z),-25 * .pi/180)
      XCTAssertLessThan(wheel.boxes.map{$0.size.x}.max()!,0.16)
    }
  }
}
