import XCTest
import simd
@testable import WorldCore

final class WorldLandmarkTests: XCTestCase {
  let terrain = TerrainGenerator(seed: 967252643)
  func testLandmarksAreStableDistinctAndLeaveSettlementsIntact() {
    for seed: UInt64 in [0,1,8192,967252643] {
      let a = TerrainGenerator(seed:seed), b = TerrainGenerator(seed:seed)
      XCTAssertEqual(a.landmarks.map(\.id),b.landmarks.map(\.id))
      XCTAssertEqual(a.landmarks.filter { $0.kind == .circuit }.count,1)
      XCTAssertEqual(Set(a.landmarks.map(\.id)).count,2)
      XCTAssertEqual(a.landmarks.filter { $0.kind == .castle }.count,1)
      for site in a.landmarks {
        let region = ChunkCoordinate(floorDivide(site.x,by:SettlementGenerator.regionSize),floorDivide(site.z,by:SettlementGenerator.regionSize))
        if let town = SettlementGenerator.site(in:region,terrain:a) {
          XCTAssertTrue(abs(site.x-town.x) >= site.halfX+town.radius || abs(site.z-town.z) >= site.halfZ+town.radius)
        }
        XCTAssertGreaterThan(site.floor,TerrainGenerator.seaLevel)
      }
    }
  }
  func testEntireRaceLaneHasRoomAndSupportForACar() throws {
    for site in terrain.landmarks where site.kind == .circuit {
      let circuit = site.circuit
      func block(_ p: BlockPosition) -> Block { site.block(at:p,surface:site.floor,natural:site.floor-1) ?? .air }
      for s in stride(from:Float(0),to:circuit.length,by:1.5) {
        let point = circuit.point(at:s), next = circuit.point(at:s+0.1), d = next-point
        let heading = atan2(-d.x,-d.z)
        XCTAssertTrue(VehiclePhysics.isClear(at:point,heading:heading,block:block),"distance \(s)")
        XCTAssertTrue(block(.init(point+[0,-1,0])).isSolid)
      }
      for index in 0..<3 {
        let point = site.circuit.pitPosition(index)
        XCTAssertTrue(VehiclePhysics.isClear(at:point,heading:0,block:block))
      }
    }
  }
  func testCastleHasLongConnectedRouteThroughRoomsAndUpStairs() throws {
    let site = try XCTUnwrap(terrain.landmarks.first { $0.kind == .castle })
    func block(_ p: BlockPosition) -> Block {
      if abs(p.x-site.x)>44 || abs(p.z-site.z)>44 { return .stone }
      return site.block(at:p,surface:site.floor,natural:site.floor-1) ?? (p.y < site.floor ? .stone : .air)
    }
    let route = ResidentNavigation.path(from:site.entrance,to:site.petHome,maximumVisited:24_000,block:block)
    XCTAssertGreaterThan(route.count,170)
    XCTAssertLessThan(simd_distance(try XCTUnwrap(route.last),site.petHome),1.5)
    for point in route { XCTAssertNotNil(ResidentNavigation.walkingPosition(at:point,block:block)) }
    XCTAssertNotNil(HayHay.spawn(in:site,block:block))
    XCTAssertTrue(block(.init(site.petHome+[0,-1,0])).isSolid)
  }
  func testLandmarkChunksMatchDirectQueriesAndKeepPlayerEdits() throws {
    for site in terrain.landmarks.prefix(2) {
      let coordinate = BlockPosition(site.kind == .castle ? site.petHome : site.center+[0,0,site.circuit.radius]).chunk
      let edited = BlockPosition(coordinate.x*16+2,site.floor+1,coordinate.z*16+2)
      let chunk = terrain.generate(coordinate,edits:[edited:.lamp])
      for z in [-1,0,8,15,16] { for x in [-1,0,8,15,16] { for y in [site.floor-1,site.floor,site.floor+8,site.floor+9,site.floor+18,site.floor+26] {
        let point = BlockPosition(coordinate.x*16+x,y,coordinate.z*16+z)
        XCTAssertEqual(chunk[x,y,z],terrain.block(at:point),"\(point)")
      } } }
      XCTAssertEqual(chunk[2,site.floor+1,2],.lamp)
    }
  }
  func testCastleAndTrackRemainVisibleInDistantMeshes() throws {
    for site in terrain.landmarks.prefix(2) {
      let tile = TerrainTile(x:floorDivide(site.x-32,by:64)*4,z:floorDivide(site.z-32,by:64)*4,size:4)
      let result = TerrainSurface.build(tile,terrain:terrain)
      XCTAssertFalse(result.mesh.positions.isEmpty)
      if site.kind == .castle { XCTAssertGreaterThan(result.mesh.positions.map(\.y).max() ?? 0,Float(site.floor+20)) }
    }
  }
  func testLapTimingRejectsReverseShortcutsAndLeavingTrack() throws {
    let c = try XCTUnwrap(terrain.landmarks.first { $0.kind == .circuit }).circuit
    var progress = RaceProgress()
    progress.update(position:c.point(at:-2),seconds:0.1,circuit:c)
    progress.update(position:c.point(at:1),seconds:0.1,circuit:c)
    XCTAssertTrue(progress.active)
    for s in stride(from:Float(3),through:c.length+3,by:2) { progress.update(position:c.point(at:s),seconds:0.1,circuit:c) }
    XCTAssertEqual(progress.laps,1); XCTAssertNotNil(progress.best)
    let best = progress.best
    for s in stride(from:Float(1),through:Float(-20),by:-2) { progress.update(position:c.point(at:s),seconds:0.1,circuit:c) }
    XCTAssertEqual(progress.laps,1)
    progress.update(position:c.center,seconds:1,circuit:c)
    XCTAssertFalse(progress.active); XCTAssertEqual(progress.best,best)
    progress.update(position:c.point(at:c.length-2),seconds:0.1,circuit:c)
    progress.update(position:c.point(at:1),seconds:0.1,circuit:c)
    progress.update(position:c.point(at:c.length-2),seconds:0.1,circuit:c)
    progress.update(position:c.point(at:1),seconds:0.1,circuit:c)
    XCTAssertEqual(progress.laps,1)
  }
  func testRaceCarsAreFasterBrakeAndRetainProfileInSaves() throws {
    var race = VehiclePhysics(position:.zero,kind:.race), normal = VehiclePhysics(position:[8,0,0])
    func block(_ p: BlockPosition) -> Block { p.y < 0 ? .stone : .air }
    for _ in 0..<200 { race.update(deltaTime:0.05,throttle:1,turn:0,brake:0,block:block); normal.update(deltaTime:0.05,throttle:1,turn:0,brake:0,block:block) }
    XCTAssertGreaterThan(race.speed,normal.speed*1.5)
    for _ in 0..<30 { race.update(deltaTime:0.05,throttle:0,turn:0,brake:1,block:block) }
    XCTAssertEqual(race.speed,0)
    let old = Data(#"{"id":1,"siteID":2,"position":[0,0,0],"heading":0,"variant":0,"solar":false}"#.utf8)
    XCTAssertNil(try JSONDecoder().decode(VehicleRecord.self,from:old).kind)
    let saved = VehicleRecord(id:1,siteID:2,position:[0,0,0],heading:0,variant:0,solar:false,kind:.race)
    XCTAssertEqual(try JSONDecoder().decode(VehicleRecord.self,from:JSONEncoder().encode(saved)).kind,.race)
  }
  func testHayHayWaitsToBeFoundAndFriendshipSurvivesSaving() throws {
    let site = try XCTUnwrap(terrain.landmarks.first { $0.kind == .castle })
    var pet = try XCTUnwrap(HayHay.spawn(in:site,block:terrain.block))
    let home = pet.position
    for tick in 0..<120 { pet.update(deltaTime:0.05,time:Double(tick)*0.05,player:site.entrance,offering:.grass,block:terrain.block) }
    XCTAssertEqual(pet.position,home)
    pet.bond.befriended = true
    XCTAssertTrue(pet.followsPlayer(at:1000))
    let bond = try JSONDecoder().decode(AnimalBond.self,from:JSONEncoder().encode(pet.bond))
    XCTAssertTrue(bond.trusting); XCTAssertTrue(bond.isValid)
    XCTAssertEqual(AnimalKind.hayHay.foods,[.grass,.leaves,.flowers])
    XCTAssertFalse(AnimalKind.hayHay.wild)
    let model = HayHaySculpture.make()
    XCTAssertLessThan(model.parts.reduce(0) { $0+$1.boxes.count },150)
    XCTAssertGreaterThan(model.bounds.maximum.y,1)
    XCTAssertEqual(model.name,"Hay Hay")
    let record = FaunaRecord(id:pet.id,species:"hayHay",home:home)
    XCTAssertTrue(record.isValid); XCTAssertEqual(record.behaviorDescription,HayHay.personality)
  }
}
