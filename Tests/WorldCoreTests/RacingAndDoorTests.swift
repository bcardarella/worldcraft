import XCTest
import simd
@testable import WorldCore

final class RacingAndDoorTests: XCTestCase {
  func testGarageCarsFitGeneratedSaffronChunksIncludingSeams() {
    let terrain = TerrainGenerator(seed: 1667327165707871140, style: .dune)
    for track in terrain.landmarks where track.kind == .circuit {
      var chunks: [ChunkCoordinate: ChunkData] = [:]
      for bay in 0..<RaceGarage.bayCount {
        let point = track.circuit.pitPosition(bay)
        for coordinate in RaceGarage.requiredChunks(at: point) where chunks[coordinate] == nil {
          chunks[coordinate] = terrain.generate(coordinate)
        }
        func block(_ p: BlockPosition) -> Block {
          guard let chunk = chunks[p.chunk] else { return .stone }
          return chunk[p.x - p.chunk.x * 16, p.y, p.z - p.chunk.z * 16]
        }
        XCTAssertTrue(VehiclePhysics.isClear(at: point, heading: 0, kind: .race, block: block), "\(track.name) bay \(bay)")
        XCTAssertTrue(block(BlockPosition(point - [0, 1, 0])).isSolid)
      }
    }
  }
  func testPlanetsChooseSixLayoutsWithOneRareTrackAndStableGarages() {
    var layouts = Set<Int>()
    for seed: UInt64 in Array(0..<40) + [8192, 967252643, 1667327165707871140] {
      let tracks = TerrainGenerator(seed: seed).landmarks.filter { $0.kind == .circuit }
      XCTAssertEqual(Set(tracks.map { $0.circuit.layout.rawValue }).count, 1)
      layouts.formUnion(tracks.map { $0.circuit.layout.rawValue })
      for track in tracks {
        // Alternate layouts retain the existing pit location of each discipline.
        let old = RaceCircuit(id: track.id, center: track.center,
          layout: CircuitLayout(rawValue: track.variant % 3)!)
        for bay in 0..<RaceGarage.bayCount {
          XCTAssertEqual(old.pitPosition(bay), track.circuit.pitPosition(bay))
        }
      }
    }
    XCTAssertEqual(layouts, Set(CircuitLayout.allCases.map(\.rawValue)))
  }

  func testEveryLayoutHasThreeClearGaragesWithDrivableExits() {
    for layout in CircuitLayout.allCases {
      let site = WorldLandmark(id: 1, kind: .circuit, x: 320, z: 320, floor: 40, variant: layout.rawValue)
      func block(_ p: BlockPosition) -> Block { site.block(at: p, surface: site.floor, natural: site.floor - 1) ?? .stone }
      for bay in 0..<RaceGarage.bayCount {
        let point = site.circuit.pitPosition(bay)
        XCTAssertTrue(VehiclePhysics.isClear(at: point, heading: 0, kind: .race, block: block))
        XCTAssertTrue(block(BlockPosition(point - [0, 1, 0])).isSolid)
        var car = VehiclePhysics(position: point, kind: .race)
        for _ in 0..<120 {
          car.update(deltaTime: 1 / 30, throttle: 0.6, turn: 0, brake: 0, block: block)
          if car.position.z <= Float(site.z) + site.circuit.startZ { break }
        }
        XCTAssertLessThanOrEqual(car.position.z, Float(site.z) + site.circuit.startZ, "\(layout) bay \(bay)")
        for other in 0..<bay {
          XCTAssertFalse(VehiclePhysics.overlaps(position: point, heading: 0, kind: .race,
            otherPosition: site.circuit.pitPosition(other), otherHeading: 0, otherKind: .race))
        }
      }
    }
  }

  func testGarageSpawningWaitsForFullFootprintAndDoesNotImmediatelyRetire() {
    let circuit = RaceCircuit(id: 1, center: [320, 40, 320])
    let point = circuit.pitPosition(1), chunks = RaceGarage.requiredChunks(at: point)
    XCTAssertGreaterThan(chunks.count, 1) // The garage straddles chunk boundaries.
    XCTAssertFalse(chunks.isSubset(of: [BlockPosition(point).chunk]))
    for distance: Float in [0, 150, 201, 239] {
      let player = point + [distance, 0, 0]
      XCTAssertTrue(RaceGarage.isNear(point, player: player))
      XCTAssertTrue(RaceGarage.isNear(point, player: player, retaining: true))
    }
    XCTAssertFalse(RaceGarage.isNear(point, player: point + [241, 0, 0]))
    XCTAssertTrue(RaceGarage.isNear(point, player: point + [300, 0, 0], retaining: true))
    XCTAssertFalse(RaceGarage.isNear(point, player: point + [341, 0, 0], retaining: true))
    XCTAssertEqual(Set((0..<3).map { RaceGarage.carID(track: 1, bay: $0) }).count, 3)
  }
  func testTrackVarietyHasLongLapsAndContinuousProgress() {
    for layout in CircuitLayout.allCases {
      let c=RaceCircuit(id:1,center:.zero,layout:layout)
      XCTAssertGreaterThan(c.length,1_200)
      for s in stride(from:Float(1),to:c.length-1,by:2.3) {
        let p=c.point(at:s)
        XCTAssertEqual(c.laneDistance(x:p.x,z:p.z),0,accuracy:0.02)
        XCTAssertEqual(c.progress(at:p),s,accuracy:0.05)
        XCTAssertLessThan(simd_length(c.point(at:s+0.01)-p),0.03)
      }
    }
  }
  func testLocalDriverCompletesAllLayoutsWithoutNetwork() {
    for layout in CircuitLayout.allCases {
      let c=RaceCircuit(id:1,center:.zero,layout:layout)
      var car=VehiclePhysics(position:c.point(at:1),heading: -.pi/2,kind:.race), driver=RaceDriver(), lap=RaceProgress()
      var maxDeviation:Float=0
      lap.update(position:c.point(at:-1),seconds:0,circuit:c)
      for _ in 0..<7_200 {
        let o=RacerObservation(id:2,circuit:c,physics:car,traffic:[],previous:.steady)
        let input=driver.controls(physics:car,circuit:c,tactic:.steady,observation:o,seconds:1/30)
        car.update(deltaTime:1/30,throttle:input.throttle,turn:input.steering,brake:0,block: { $0.y<0 ? .basalt:.air })
        maxDeviation=max(maxDeviation,abs(c.laneDistance(x:car.position.x,z:car.position.z)))
        lap.update(position:car.position,seconds:1/30,circuit:c)
        if lap.laps>=1 { break }
      }
      XCTAssertGreaterThan(lap.laps,0,"\(layout) car \(car.position)")
      XCTAssertLessThan(maxDeviation,8,"\(layout)")
    }
  }
  func testRacerOptionsAndControllerVetoOccupiedPassingLane() throws {
    let c=RaceCircuit(id:1,center:.zero), car=VehiclePhysics(position:c.point(at:5),heading: -.pi/2,kind:.race)
    let traffic=[VehicleTraffic(id:2,position:c.point(at:12),previousPosition:c.point(at:12),velocity:.zero,heading: -.pi/2,playerDriven:true),
      VehicleTraffic(id:3,position:c.point(at:5,lane:-3),previousPosition:c.point(at:5,lane:-3),velocity:.zero,heading: -.pi/2,playerDriven:false)]
    let o=RacerObservation(id:1,circuit:c,physics:car,traffic:traffic,previous:.steady)
    XCTAssertNil(o.options["passLeft"]); XCTAssertNil(o.options["push"])
    var driver=RaceDriver()
    _=driver.controls(physics:car,circuit:c,tactic:.passLeft,observation:o,seconds:0.05)
    XCTAssertEqual(driver.lane,0)
    let request=JevRacingRequest(observations:[o])
    let data=try JSONSerialization.jsonObject(with:JSONEncoder().encode(request)) as! [String:Any]
    XCTAssertNotNil((data["questions"] as? [String:Any])?["racer_1"])
  }
  func testDoorFitsHumansAndDogAsksBothWays() throws {
    let terrain=TerrainGenerator(seed:8192), site=try XCTUnwrap(SettlementGenerator.site(in:.init(0,0),terrain:terrain))
    var found:BuildingDoor?
    for x in -5...5 { for z in -5...5 { if found == nil { found=site.door(lotX:x,lotZ:z,terrain:terrain) } } }
    let door=try XCTUnwrap(found), outside=door.approach(inside:false), inside=door.approach(inside:true)
    XCTAssertGreaterThan(BuildingDoor.height,PlayerPhysics.height)
    XCTAssertTrue(door.obstructs(door.origin+[1,0,0],fraction:0))
    XCTAssertFalse(door.obstructs(door.origin+[1,0,0],fraction:1))
    var visit=DogDoorVisit()
    _=visit.directive(position:outside,player:outside,time:1,shelter:false,offeredFood:false,doors:[.init(door:door,fraction:0)],id:1)
    XCTAssertEqual(visit.scratching,door.id)
    _=visit.directive(position:inside,player:outside,time:2,shelter:false,offeredFood:false,doors:[.init(door:door,fraction:1)],id:1)
    XCTAssertNil(visit.scratching)
    _=visit.directive(position:inside,player:outside,time:35,shelter:false,offeredFood:false,doors:[.init(door:door,fraction:0)],id:1)
    XCTAssertEqual(visit.scratching,door.id)
  }
}
