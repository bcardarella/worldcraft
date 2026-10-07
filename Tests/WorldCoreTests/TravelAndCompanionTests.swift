import XCTest
import simd
@testable import WorldCore

final class TravelAndCompanionTests: XCTestCase {
  private func house(style: ArchitectureStyle = .timber, height: Int = 32) -> BuildingDescriptor {
    .init(style:style,height:height,minimum:0,maximum:36,wall:.brick,frame:.wood,roof:.stone,roofRise:0,hash:1)
  }
  func testWalkEveryStairFlightWithoutJumpingOrHittingCeiling() {
    for style: ArchitectureStyle in [.timber,.modern,.citadel] {
      let building=house(style:style,height:80)
      let world: (BlockPosition)->Block = { building.block(x:$0.x,y:$0.y,z:$0.z) }
      for floor in 0..<building.floorCount-1 {
        var player=PlayerPhysics(position:[Float(building.stairStartX)-1.2,Float(floor*building.storey+1)+0.01,Float(building.stairZ.lowerBound)+1.5])
        player.grounded=true
        for _ in 0..<150 { player.update(deltaTime:1/60,movement:[1,0,0],jump:false,sprint:false,block:world) }
        XCTAssertGreaterThan(player.position.x,Float(building.stairStartX+building.storey),"\(style) floor \(floor): \(player.position)")
        XCTAssertEqual(player.position.y,Float((floor+1)*building.storey+1),accuracy:0.08)
        XCTAssertFalse(player.collides(at:player.position,block:world))
      }
    }
  }
  func testStairsKeepHeadroomButDoNotLetWalkingClimbTwoBlockWalls() {
    var player=PlayerPhysics(position:[0.5,0.01,0.5]); player.grounded=true
    let wall: (BlockPosition)->Block = { $0.y<0 || ($0.x>=3 && $0.y<2) ? .stone:.air }
    for _ in 0..<100 { player.update(deltaTime:1/60,movement:[1,0,0],jump:false,sprint:false,block:wall) }
    XCTAssertLessThan(player.position.x,2.5)
    XCTAssertLessThan(player.position.y,0.1)
    let stair: (BlockPosition)->Block = { $0 == .init(0,0,0) ? .woodStairsEast : .air }
    // Above the low half is clear; the raised half blocks a player's body.
    let edge=PlayerPhysics(position:[-0.5,0.51,0.5])
    XCTAssertFalse(edge.collides(at:edge.position,block:stair))
    XCTAssertTrue(edge.collides(at:[0.5,0.51,0.5],block:stair))
  }
  func testElevatorClosesBeforeMovingAndStopsExactlyOnEveryLanding() {
    let shaft=ElevatorShaft(id:1,origin:[10,11,10],storey:9,floors:9)
    var lift=ElevatorMotion(shaft:shaft,floor:0)
    lift.request(8)
    for _ in 0..<10 { lift.advance(seconds:0.05,obstructed:true) }
    XCTAssertEqual(lift.height,11); XCTAssertEqual(lift.doorOpen,1)
    lift.advance(seconds:0.05)
    XCTAssertEqual(lift.height,11); XCTAssertLessThan(lift.doorOpen,1)
    for _ in 0..<700 { lift.advance(seconds:0.05) }
    XCTAssertFalse(lift.travelling); XCTAssertEqual(lift.floor,8)
    XCTAssertEqual(lift.height,83); XCTAssertEqual(lift.doorOpen,1)
    lift.request(-4)
    for _ in 0..<700 { lift.advance(seconds:0.05) }
    XCTAssertEqual(lift.floor,0); XCTAssertEqual(lift.height,11)
    XCTAssertTrue(shaft.contains([10,11,10],at:lift.height))
    XCTAssertFalse(shaft.contains([14,11,10],at:lift.height))
  }
  func testElevatorShaftHasNoSolidFloorBetweenStopsAndReachableDoors() {
    let building=house(style:.modern,height:80)
    XCTAssertTrue(building.hasElevator)
    for y in 1..<building.height { XCTAssertEqual(building.block(x:6,y:y,z:9),.air) }
    for floor in 0..<building.floorCount {
      let y=floor*building.storey+1
      for head in 0..<4 { XCTAssertEqual(building.block(x:6,y:y+head,z:6),.air) }
      XCTAssertTrue(building.block(x:6,y:y-1,z:5).isSolid)
    }
    XCTAssertFalse(house(height:16).hasElevator)
  }
  func testHayHayCollectionRearmsAndSavesBeyondActivePresentationLimit() throws {
    let castle=try XCTUnwrap(TerrainGenerator(seed:8192).landmarks.first { $0.kind == .castle })
    var collection=HayHayCollection()
    for _ in 0..<75 {
      XCTAssertNotNil(collection.collect(castle:castle))
      XCTAssertNil(collection.collect(castle:castle))
      collection.rearm(castle:castle,player:castle.petHome+[30,0,0])
    }
    XCTAssertEqual(collection.count,75); XCTAssertEqual(collection.activeIDs.count,16)
    let restored=try JSONDecoder().decode(HayHayCollection.self,from:JSONEncoder().encode(collection))
    XCTAssertEqual(restored.ids,collection.ids); XCTAssertTrue(restored.isValid)
    let point=try XCTUnwrap(HayHayCollection.landing(near:[0,0,0],ordinal:0,occupied:[],block:{ $0.y<0 ? .stone:.air }))
    let pet=HayHayCollection.companion(id:restored.ids[0],at:point)
    XCTAssertTrue(pet.collectedCompanion); XCTAssertEqual(pet.bond.befriended,true)
    XCTAssertNil(HayHayCollection.landing(near:.zero,ordinal:0,occupied:[],block:{ _ in .water }))
    XCTAssertNil(HayHayCollection.landing(near:.zero,ordinal:0,occupied:[],block:{ _ in .stone }))
  }
  func testHayHayFitsEveryFrontPassengerSeatWithoutCoveringTheDriverOrPiercingTheRoof() {
    let bounds=HayHaySculpture.make().bounds
    for kind in VehicleKind.allCases {
      let car=VehiclePhysics(position:[100,30,-200],heading:.pi/2,kind:kind)
      let carrier=CompanionCarrier(id:12,kind:.car(kind),position:car.position,heading:car.heading)
      let seat=carrier.passenger(ordinal:0)
      let local=carrier.rotation.inverse.act(seat.position-car.position)*WorldScale.metresPerBlock
      let left=local.x+bounds.minimum.x*seat.scale, right=local.x+bounds.maximum.x*seat.scale
      XCTAssertGreaterThan(left,0,"Hay Hay belongs on the passenger side: \(kind)")
      XCTAssertLessThan(right,WorldScale.metres(kind.halfWidth)-0.04)
      XCTAssertLessThan(local.y+bounds.maximum.y*seat.scale,WorldScale.metres(kind.height)-0.06)
      XCTAssertGreaterThan(local.y,0.45)
      XCTAssertGreaterThan(simd_distance(seat.position,car.eye),0.5)
      XCTAssertTrue(seat.visible);XCTAssertFalse(carrier.passenger(ordinal:1).visible)
    }
  }
  func testBoatPassengersFollowHullMotionAndJetSkiCompanionClingsBehindTheUprightRider() {
    for kind in BoatKind.allCases {
      let origin=SIMD3<Float>(100,24,80)
      let flat=CompanionCarrier(id:3,kind:.boat(kind),position:origin,heading:0)
      let tilted=CompanionCarrier(id:3,kind:.boat(kind),position:origin+[90,2,-50],heading:1.2,heel:0.18,pitch:-0.12)
      var points:[SIMD3<Float>]=[]
      for index in 0..<flat.capacity {
        let a=flat.passenger(ordinal:index),b=tilted.passenger(ordinal:index)
        XCTAssertLessThan(simd_distance(b.position,tilted.position+tilted.rotation.act(a.position-origin)),0.0001)
        XCTAssertGreaterThan(a.position.y,24)
        if !kind.isMotorized {
          let earTop=WorldScale.metres(a.position.y-origin.y)+HayHaySculpture.make().bounds.maximum.y*a.scale
          XCTAssertLessThan(earTop,kind.freeboard+0.80,"Ears must stay below the swinging boom: \(kind)")
        }
        XCTAssertTrue(points.allSatisfy {simd_distance($0,a.position)>0.6})
        points.append(a.position)
      }
      if kind == .jetSki {
        let seat=tilted.passenger(ordinal:0)
        let local=tilted.rotation.inverse.act(seat.position-tilted.position)*WorldScale.metresPerBlock
        XCTAssertGreaterThan(local.z,kind.helm.z+0.2)
        XCTAssertLessThan(local.z,kind.helm.z+0.35,"Cling to the rider's back rather than float behind the seat")
        XCTAssertLessThan(abs(local.x),0.01)
        XCTAssertTrue(seat.clinging)
        XCTAssertLessThan(simd_distance(seat.rotation.act([0,1,0]),[0,1,0]),0.0001)
      } else {
        XCTAssertGreaterThan(simd_distance(tilted.rotation.act([0,1,0]),[0,1,0]),0.1)
      }
    }
  }
  func testPassengerJourneyKeepsExtraCompanionsAndExitPlacementAvoidsVehicleBodies() throws {
    var carrier=CompanionCarrier(id:5,kind:.car(.deliveryVan),position:.zero,heading:.pi/3)
    carrier.journey=9
    for i in 0..<16 {
      var pet=HayHayCollection.companion(id:UInt64(i+1),at:[90,10,90])
      pet.moving=true;pet.grazing=true;pet.resting=true
      pet.board(carrier,ordinal:i)
      XCTAssertEqual(pet.companionJourney,9);XCTAssertTrue(pet.collectedCompanion)
      XCTAssertEqual(pet.passenger?.visible,i==0)
      XCTAssertFalse(pet.moving || pet.grazing || pet.resting)
    }
    let landing=try XCTUnwrap(HayHayCollection.landing(near:[2,0,0],ordinal:0,occupied:[],
      occupiedSpace:carrier.obstructsCompanion,block:{$0.y<0 ? .stone:.air}))
    XCTAssertFalse(carrier.obstructsCompanion(at:landing))
    XCTAssertTrue(AnimalKind.hayHay.canStand(at:landing,juvenile:false,block:{$0.y<0 ? .stone:.air}))
  }
  func testMountedAnimalsMoveCollideStepAndDismountSafely() throws {
    XCTAssertNil(MountProfile.animal(.rabbit,baby:false))
    XCTAssertNil(MountProfile.dinosaur(.trex,baby:true))
    XCTAssertNotNil(MountProfile.dinosaur(.trex,baby:false))
    let profile=try XCTUnwrap(MountProfile.animal(.horse,baby:false))
    var ride=MountedRide(.init(id:1,name:"Horse",position:.zero,heading:0,profile:profile),boardedAt:[-3,0,0])
    let world: (BlockPosition)->Block = { p in p.y < (p.x>6 ? 1:0) || (p.x>18 && p.y<12) ? .stone:.air }
    for _ in 0..<500 { ride.update(seconds:1/60,movement:[1,0,0],sprint:false,jump:false,block:world) }
    XCTAssertGreaterThan(ride.position.x,7); XCTAssertLessThan(ride.position.x,19)
    XCTAssertEqual(ride.position.y,1,accuracy:0.05)
    XCTAssertTrue(ride.clear(at:ride.position,block:world))
    let exit=try XCTUnwrap(ride.dismount(block:world))
    XCTAssertEqual(VehiclePhysics.safeFooting(at:exit,block:world),true)
  }
  func testCarClimbsAndDescendsOneBlockWithoutLosingMomentum() {
    let world: (BlockPosition)->Block = { $0.y < ((-18 ... -7).contains($0.z) ? 1:0) ? .stone:.air }
    var car=VehiclePhysics(position:.zero)
    var reachedTop=false, impact:Float=0
    for _ in 0..<300 {
      car.update(deltaTime:1/60,throttle:0.7,turn:0,brake:0,block:world)
      reachedTop = reachedTop || car.position.y>0.9
      impact=max(impact,car.impactSpeed)
    }
    XCTAssertTrue(reachedTop); XCTAssertLessThan(car.position.z,-23)
    XCTAssertEqual(car.position.y,0,accuracy:0.08); XCTAssertGreaterThan(car.speed,5)
    XCTAssertLessThan(impact,2)
  }
  func testGlancingCarImpactPreservesTravelAlongWall() {
    let world: (BlockPosition)->Block = { $0.y<0 || $0.x>=7 ? .stone:.air }
    var car=VehiclePhysics(position:.zero,heading:-0.6)
    var impact:Float=0
    for _ in 0..<300 {
      car.update(deltaTime:1/60,throttle:1,turn:0,brake:0,block:world)
      impact=max(impact,car.impactSpeed)
    }
    XCTAssertGreaterThan(impact,1); XCTAssertLessThan(car.position.x,7)
    XCTAssertLessThan(car.position.z,-18)
    XCTAssertTrue(VehiclePhysics.isClear(at:car.position,heading:car.heading,block:world))
  }
  func testStairRaySelectionRespectsEmptyHalfAndPlacedOrientation() {
    let world: (BlockPosition)->Block = { $0 == .init(0,0,0) ? .woodStairsEast:.air }
    XCTAssertNil(VoxelRaycast.cast(origin:[0.1,0.75,-2],direction:[0,0,1],reach:6,block:world))
    XCTAssertEqual(VoxelRaycast.cast(origin:[0.8,0.75,-2],direction:[0,0,1],reach:6,block:world)?.block,.init(0,0,0))
    XCTAssertEqual(Block.woodStairsEast.facing([0,0,-1]),.woodStairsNorth)
    XCTAssertEqual(Block.stoneStairsEast.facing([-1,0,0]),.stoneStairsWest)
  }
  func testOldSnowEditsMeltBelowWaterAndRemainSnowOnDryMountains() throws {
    let terrain=TerrainGenerator(seed:8192,style:.frost)
    var wet: BlockPosition?, dry: BlockPosition?
    for x in stride(from:-800,through:800,by:11) {
      let column=terrain.column(atX:x,z:0)
      if let water=column.water, Float(column.height)<water.level-2 { wet = .init(x,column.height,0) }
      if column.water == nil && column.surface == .snow { dry = .init(x,column.height,0) }
      if wet != nil && dry != nil { break }
    }
    let bed=try XCTUnwrap(wet), mountain=try XCTUnwrap(dry)
    XCTAssertEqual(terrain.waterSafeMaterial(.snow,at:bed),.sand)
    XCTAssertEqual(terrain.waterSafeMaterial(.snow,at:mountain),.snow)
    let chunk=terrain.generate(bed.chunk,edits:[bed:.snow])
    XCTAssertEqual(chunk[bed.x-bed.chunk.x*16,bed.y,bed.z-bed.chunk.z*16],.sand)
    let p=mountain + .init(0,8,0)
    let melt=terrain.generate(p.chunk,edits:[p:.snow,p + .init(0,1,0):.water])
    XCTAssertEqual(melt[p.x-p.chunk.x*16,p.y,p.z-p.chunk.z*16],.sand)
  }
  func testTorchAndLampMetadataDoesNotTreatSignageAsAFlame() {
    var chunk=ChunkData(coordinate:.init(0,0))
    chunk[2,1,2] = .torch; chunk[4,1,4] = .lantern; chunk[6,1,6] = .lamp
    chunk[8,1,8] = .torch; chunk[8,2,8] = .water
    let mesh=VoxelMesher.build(chunk)
    XCTAssertEqual(mesh.firePositions.count,1); XCTAssertEqual(mesh.lampPositions.count,1)
    XCTAssertEqual(Block.limestone.rawValue,21); XCTAssertEqual(Block.torch.rawValue,22)
  }
}
