import XCTest
import simd
@testable import WorldCore

final class GameplayExpansionTests:XCTestCase {
  func testFullSizedBodiesNavigateFourByTwoDoorwayButRejectSmallHole() throws {
    func room(_ p:BlockPosition)->Block {
      if p.y<0 {return .stone}
      if p.z==0 && !(p.x>=0 && p.x<2 && p.y<4) {return .brick}
      return .air
    }
    let feet=SIMD3<Float>(1,0,0.5)
    XCTAssertFalse(PlayerPhysics(position:feet).collides(at:feet,block:room))
    XCTAssertNotNil(ResidentNavigation.walkingPosition(at:feet,block:room))
    let path=ResidentNavigation.path(from:[1,0,-3],to:[1,0,4],block:room)
    XCTAssertGreaterThan(try XCTUnwrap(path.last).z,3)
    for step in path {XCTAssertTrue(ResidentNavigation.clear(at:step,block:room))}
    func small(_ p:BlockPosition)->Block {p.y<0 || (p.z==0 && !(p.x==0 && p.y<2)) ? .stone:.air}
    XCTAssertNil(ResidentNavigation.walkingPosition(at:[0.5,0,0.5],block:small))
    XCTAssertTrue(PlayerPhysics(position:feet).collides(at:[0.5,0,0.5],block:small))
  }
  func testPassageRetainsCrossingOwnerThenLetsWaitingPeopleTakeTurns() {
    var q=ResidentPassageQueue()
    q.update([.init(person:3,passage:8,inside:false)],time:1)
    q.update([.init(person:3,passage:8,inside:true),.init(person:1,passage:8,inside:false),.init(person:2,passage:8,inside:false)],time:2)
    XCTAssertTrue(q.permits(3,passage:8));XCTAssertFalse(q.permits(1,passage:8))
    q.update([.init(person:1,passage:8,inside:false),.init(person:2,passage:8,inside:false)],time:3)
    XCTAssertTrue(q.permits(1,passage:8));XCTAssertFalse(q.permits(2,passage:8))
    q.update([.init(person:0,passage:8,inside:true),.init(person:1,passage:8,inside:false),.init(person:2,passage:8,inside:false)],time:4)
    XCTAssertTrue(q.permits(0,passage:8));XCTAssertFalse(q.permits(1,passage:8))
    q.update([.init(person:1,passage:8,inside:false),.init(person:2,passage:8,inside:false)],time:5)
    XCTAssertTrue(q.permits(1,passage:8))
    q.update([.init(person:2,passage:8,inside:false)],time:6);XCTAssertTrue(q.permits(2,passage:8))
  }
  func testTallStairReservationUsesDistanceToEntranceAndDoesNotStarveWaitingPeople() {
    let stair=ResidentPassage(id:1,low:[0,0,0],high:[12,150,4],axis:0)
    XCTAssertLessThan(stair.distanceSquared(to:[-2,0,2]),10)
    var q=ResidentPassageQueue()
    q.update([.init(person:1,passage:1,inside:false),.init(person:2,passage:1,inside:false)],time:0)
    q.update([.init(person:1,passage:1,inside:false),.init(person:2,passage:1,inside:false)],time:19)
    XCTAssertTrue(q.permits(2,passage:1))
  }
  func testEveryLockerPanelMatchesTheStadiumVoxelGeometry() throws {
    let t=TerrainGenerator(seed:8192),city=Settlement(id:1,kind:.city,name:"City",x:512,z:512,floor:30,ground:.grass)
    let field=try XCTUnwrap(city.sportsGrounds.first{$0.kind == .baseball})
    let venue=SportsVenue(id:1,field:field,floor:30)
    XCTAssertEqual(venue.lockers.count,66)
    var edits:[BlockPosition:Block]=[:]
    for locker in venue.lockers {
      XCTAssertFalse(locker.isOpen {edits[$0] ?? city.block(at:$0,terrain:t) ?? .air})
      for panel in locker.panels {XCTAssertEqual(city.block(at:panel,terrain:t),.wood,"\(panel)");edits[panel] = .air}
      XCTAssertTrue(locker.isOpen {edits[$0] ?? city.block(at:$0,terrain:t) ?? .air})
    }
  }
  func testRacesHoldAllCarsForCountdownAndFinishOnlyAtThreeValidatedLaps() {
    var race=RaceEvent(circuitID:9,player:1,opponents:[2,3,2])
    XCTAssertEqual(race.entrants.count,3)
    for _ in 0..<29 {race.advance(seconds:0.1)}
    XCTAssertFalse(race.canDrive(1));XCTAssertFalse(race.canDrive(2))
    race.record(1,laps:3);XCTAssertTrue(race.finishOrder.isEmpty)
    race.advance(seconds:0.1);XCTAssertTrue(race.canDrive(1));XCTAssertTrue(race.canDrive(2))
    race.record(2,laps:2);XCTAssertTrue(race.finishOrder.isEmpty)
    race.advance(seconds:0.1);race.record(2,laps:3);race.record(1,laps:3)
    let time=race.finishTimes[1];race.advance(seconds:0.1)
    XCTAssertEqual(race.finishTimes[1],time);XCTAssertEqual(race.finishOrder,[2,1]);XCTAssertTrue(race.canDrive(1)) // Finishers roll clear; results stay frozen.
    race.record(3,laps:3);XCTAssertEqual(race.phase,.finished)
  }
  func testHeadSeatsRotateWithDinosaursAndRemainAboveTheirHeads() throws {
    for kind in [DinosaurKind.trex,.brachiosaurus,.spinosaurus] {
      let p=try XCTUnwrap(MountProfile.dinosaur(kind,baby:false))
      let shape=DinosaurSculpture.make(.init(kind:kind,color:.pink,id:0,juvenile:false))
      let head=try XCTUnwrap(shape.parts.first{$0.joint == .head})
      let top=head.pivot.y+(head.boxes.map{$0.center.y+$0.size.y/2}.max() ?? 0)
      XCTAssertEqual(p.seatHeight,WorldScale.blocks(top)+1.4,accuracy:0.001)
      let ride=MountedRide(.init(id:1,name:"Dinosaur",position:[5,20,7],heading:.pi/2,profile:p),boardedAt:.zero)
      XCTAssertEqual(ride.eye.x,5-p.seatForward,accuracy:0.001)
      XCTAssertGreaterThan(ride.eye.y,20+WorldScale.blocks(top))
    }
    XCTAssertGreaterThan(MountProfile.colossal(heightMetres:100).seatHeight,150)
  }
  func testClubTiersHaveDifferentAmenitiesAndPoweredCraftHaveWorkingThrottles() {
    let clubs=YachtClubTier.allCases.map {Marina(id:32,x:0,z:0,floor:27,quarterTurn:0,body:.ocean,tier:$0)}
    XCTAssertEqual(clubs.map{ $0.boats.count },[2,4,6,14])
    XCTAssertLessThan(clubs[0].structures.count,clubs[3].structures.count)
    XCTAssertTrue(clubs[3].tier.amenities.contains("Mooring field"))
    XCTAssertEqual(Set(clubs[3].boats.map(\.physics.kind)),Set(BoatKind.allCases))
    XCTAssertEqual(Set(clubs[3].boats.map(\.id)).count,14)
    XCTAssertNotEqual(Marina(id:768,x:0,z:0,floor:27,quarterTurn:0,body:.init(id:5,kind:.lake,level:24)).tier,.premier)
    for kind in BoatKind.allCases where kind.isMotorized {
      var p=SailingPhysics(kind:kind,position:[0,24,0],heading:0);p.anchored=false
      for _ in 0..<1800 {p.update(deltaTime:1/60,controls:.init(auxiliary:1),wind:.zero,current:.zero,water:.init(height:24,normal:[0,1,0]))}
      XCTAssertLessThan(p.position.z,-100);XCTAssertGreaterThan(p.speed,4)
      for _ in 0..<2400 {p.update(deltaTime:1/60,controls:.init(auxiliary:-1),wind:.zero,current:.zero,water:.init(height:24,normal:[0,1,0]))}
      XCTAssertGreaterThan(p.velocity.z,0);XCTAssertTrue(p.isValid)
    }
  }
  func testAllPremierBerthsFitTheirDredgedBasinAndHaveClearOutboundRoutes() {
    for turn in 0..<4 {
      let site=Marina(id:768,x:0,z:0,floor:27,quarterTurn:turn,body:.ocean,tier:.premier)
      func column(_ x:Int,_ z:Int)->TerrainColumn {
        site.waterColumn(.init(height:16,surface:.sand,water:.ocean),x:x,z:z)
      }
      func block(_ p:BlockPosition)->Block {
        if let b=site.block(at:p,natural:16) {return b}
        let c=column(p.x,p.z)
        return p.y<=c.height ? .sand:Float(p.y)<24 ? .water:.air
      }
      for record in site.boats {
        let p=record.physics
        for distance:Float in [0,4,12,24] {
          XCTAssertTrue(SailingPhysics.isNavigable(position:p.position+p.forward*distance,heading:p.heading,kind:p.kind,column:column,block:block),"\(p.kind) rotation=\(turn) distance=\(distance)")
        }
      }
    }
  }
  func testSoccerOnlyScoresAfterWholeBallPassesBetweenPostsBelowBar() {
    XCTAssertNil(SoccerRules.goal(from:[0,0.3,99],to:[0,0.3,100.1],halfLength:100,floor:0))
    XCTAssertEqual(SoccerRules.goal(from:[0,0.3,99],to:[0,0.3,101],halfLength:100,floor:0),0)
    XCTAssertEqual(SoccerRules.goal(from:[0,0.3,-99],to:[0,0.3,-101],halfLength:100,floor:0),1)
    XCTAssertNil(SoccerRules.goal(from:[9,1,99],to:[9,1,101],halfLength:100,floor:0))
    XCTAssertNil(SoccerRules.goal(from:[0,5,99],to:[0,5,101],halfLength:100,floor:0))
    XCTAssertNil(SoccerRules.goal(from:[0,1,101],to:[0,1,102],halfLength:100,floor:0))
  }
  func testMatchesPlayWithMovingAthletesAndScoresDerivedFromEvents() {
    let diamond=SportsGround(kind:.baseball,x0:-100,x1:300,z0:-300,z1:100)
    var baseball=BaseballMatch(field:diamond,floor:10,seed:42)
    var balls=0
    for _ in 0..<36_000 {baseball.advance(seconds:1/60);balls+=baseball.takeSouvenirs().count}
    XCTAssertGreaterThan(baseball.homeRuns,0);XCTAssertGreaterThan(balls,0)
    XCTAssertEqual(baseball.score.reduce(0,+),baseball.scoredRuns)
    XCTAssertGreaterThan(baseball.inning,1,"phase=\(baseball.phase) outs=\(baseball.outs) score=\(baseball.score) message=\(baseball.message)")
    XCTAssertTrue(baseball.actors.allSatisfy {$0.position.y==10})
    var soccer=SoccerMatch(field:.init(kind:.soccer,x0:-100,x1:100,z0:-130,z1:130),floor:10,seed:9)
    let first=soccer.players.map(\.position)
    for _ in 0..<12_000 {soccer.advance(seconds:1/60)}
    XCTAssertNotEqual(soccer.players.map(\.position),first)
    XCTAssertEqual(soccer.score.reduce(0,+),soccer.goals)
    XCTAssertGreaterThan(soccer.goals,0)
    XCTAssertTrue(soccer.players.allSatisfy{$0.position.x.isFinite && $0.position.z.isFinite})
  }
  func testBaseballIsPersistentAndPowerTradesAccuracyForSpeed() throws {
    var bag=Inventory();_ = bag.collect(.baseball,count:2)
    XCTAssertEqual(try JSONDecoder().decode(Inventory.self,from:JSONEncoder().encode(bag)),bag)
    var charge=BaseballThrow()
    for _ in 0..<20 {charge.hold(seconds:0.05)}
    let controlled=charge.accuracy,velocity=simd_length(charge.velocity(direction:[0,0,-1],sequence:0))
    for _ in 0..<40 {charge.hold(seconds:0.05)}
    XCTAssertLessThan(charge.accuracy,controlled)
    XCTAssertGreaterThan(simd_length(charge.velocity(direction:[0,0,-1],sequence:0)),velocity)
    XCTAssertFalse(InventoryGeometry.mesh(for:.baseball).indices.isEmpty)
  }
  func testPlanetCloudMaskIsSparseAndUsesRedChannel() {
    let planet=SolarSystem(seed:42).planets[0],map=PlanetSurfaceMap.generate(planet,width:64),mask=map.cloudOpacity
    for i in stride(from:0,to:mask.count,by:4) {XCTAssertEqual(mask[i],map.clouds[i+3]);XCTAssertEqual(mask[i+3],255)}
    XCTAssertGreaterThan(stride(from:0,to:mask.count,by:4).filter{mask[$0]==0}.count,64)
    XCTAssertGreaterThan(Set(stride(from:0,to:map.color.count,by:4).map{[map.color[$0],map.color[$0+1],map.color[$0+2]]}).count,64)
  }
}
