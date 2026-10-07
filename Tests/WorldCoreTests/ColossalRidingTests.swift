import XCTest
import simd
@testable import WorldCore

final class ColossalRidingTests:XCTestCase {
  private let site=ColossalRexSite(id:17,region:.init(0,0),position:[0,30,0],heightMetres:140,color:.pink)
  func testGiantRideMovesWithBoundedGroundWorkAndDismountsAtFeet() throws {
    var ride=MountedRide(.init(id:site.id,name:"Colossal T-rex",position:site.position,heading:0,
      profile:.colossal(heightMetres:site.heightMetres)),boardedAt:[40,30,0])
    var probes=0
    for _ in 0..<900 {
      ride.updateColossal(seconds:1/90,movement:[0,0,-1],sprint:false) { _,_ in probes += 1; return .init(height:30) }
    }
    XCTAssertLessThan(ride.position.z,-100)
    XCTAssertLessThanOrEqual(probes,205)
    XCTAssertEqual(ride.position.y,30,accuracy:0.001)
    XCTAssertGreaterThan(ride.eye.y,WorldScale.blocks(95))
    var boardingProbes=0
    XCTAssertTrue(ride.clear(at:ride.position) { _ in boardingProbes += 1; return .air })
    XCTAssertLessThan(boardingProbes,80)
    let exit=try XCTUnwrap(ride.dismount(block: { $0.y<30 ? .stone:.air }))
    XCTAssertEqual(exit.y,30.02,accuracy:0.001)
    XCTAssertGreaterThan(simd_distance(exit,ride.position),ride.profile.radius)
    var rex=ColossalRexState(site:site); rex.applyRider(ride,seconds:0.05)
    XCTAssertEqual(rex.position,ride.position); XCTAssertTrue(rex.moving)
    let before=ride.position
    for _ in 0..<90 { ride.updateColossal(seconds:1/90,movement:[0,0,-1],sprint:true) { _,_ in .init(height:30,waterDepth:50) } }
    XCTAssertLessThan(simd_distance(before,ride.position),4,"Deep ocean must stop a land mount")
  }
  func testSpaceBoundaryIsOneKilometreAboveGroundAndNeverAppliesToMounts() {
    XCTAssertEqual(WorldScale.metres(SolarSystem.departureAltitude),1_000)
    XCTAssertFalse(SolarSystem.canDepart(height:2_050,ground:100,flying:true,mounted:false))
    XCTAssertTrue(SolarSystem.canDepart(height:2_100,ground:100,flying:true,mounted:false))
    XCTAssertFalse(SolarSystem.canDepart(height:4_000,ground:100,flying:true,mounted:true))
    XCTAssertFalse(SolarSystem.canDepart(height:4_000,ground:100,flying:false,mounted:false))
    XCTAssertEqual(SolarSystem.atmosphereDensity(height:125+WorldScale.blocks(site.heightMetres)),1)
    var previous:Float=1
    for y in stride(from:Float(600),through:2_050,by:10) {
      let density=SolarSystem.atmosphereDensity(height:y)
      XCTAssertLessThanOrEqual(density,previous); previous=density
    }
    XCTAssertEqual(previous,0)
  }
  func testCrushingIsSweptBoundedAndDoesNotDigWhileIdle() {
    var damage=ColossalTrample()
    let loaded:Set<ChunkCoordinate>=[.init(-1,-1),.init(0,-1),.init(-1,0),.init(0,0)]
    var world:[BlockPosition:Block]=[.init(0,4,0):.wood,.init(1,6,0):.leaves,
      .init(3,8,0):.brick,.init(4,9,0):.glass,.init(3,10,0):.torch,
      .init(2,5,0):.water,.init(2,6,0):.lava,.init(10,8,0):.brick,.init(0,2,0):.stone]
    damage.walked(from:[0,4,0],to:[0.1,4,0],radius:2)
    damage.walked(from:[0.1,4,0],to:[4,4,0],radius:2)
    var materials=Set<Block>(),iterations=0
    while damage.hasPending && iterations<1_000 {
      var probes=0
      let batch=damage.next(probeLimit:100,changeLimit:2,loaded:loaded) { p in
        probes += 1
        return world[p] ?? (p.y == 3 ? .dirt:.air)
      }
      XCTAssertLessThanOrEqual(probes,100); XCTAssertLessThanOrEqual(batch.count,2)
      for b in batch { world[b.position] = .air; materials.insert(b.material) }
      iterations += 1
    }
    XCTAssertFalse(damage.hasPending)
    XCTAssertTrue(Set([Block.wood,.leaves,.brick,.glass,.torch,.dirt]).isSubset(of:materials))
    XCTAssertEqual(world[.init(2,5,0)],.water); XCTAssertEqual(world[.init(2,6,0)],.lava)
    XCTAssertEqual(world[.init(10,8,0)],.brick); XCTAssertEqual(world[.init(0,2,0)],.stone)
    damage.walked(from:[4,4,0],to:[4,4,0],radius:2)
    XCTAssertTrue(damage.next(loaded:loaded,block:{ _ in .stone }).isEmpty)
  }
  func testCrushCursorCanBeRolledBackWithoutLosingDamage() {
    var cursor=ColossalTrample()
    cursor.walked(from:[-17,10,0],to:[-15,10,0],radius:2)
    var retry=cursor
    let loaded:Set<ChunkCoordinate>=[.init(-2,-1),.init(-1,-1),.init(-2,0),.init(-1,0)]
    let first=cursor.next(loaded:loaded,block:{ _ in .stone })
    XCTAssertEqual(first,retry.next(loaded:loaded,block:{ _ in .stone }))
    XCTAssertEqual(first.count,512)
    XCTAssertTrue(first.allSatisfy { $0.position.y>=9 && $0.position.y<ChunkData.height })
  }
  func testCrushingWaitsForVoxelDataWithoutLosingCrossedTerrain() {
    var damage=ColossalTrample()
    damage.walked(from:[8,30,8],to:[10,30,8],radius:1)
    XCTAssertTrue(damage.next(loaded:[],block:{ _ in XCTFail("Unloaded terrain must not trigger procedural volume queries"); return .stone }).isEmpty)
    XCTAssertTrue(damage.hasPending)
    let batch=damage.next(loaded:[.init(0,0)],block:{ $0.y==29 ? .dirt:.air })
    XCTAssertFalse(batch.isEmpty)
    XCTAssertTrue(batch.allSatisfy { $0.position.y == 29 })
    XCTAssertFalse(damage.hasPending)
  }
}
