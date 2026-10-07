import XCTest
import simd
@testable import WorldCore

final class MarinaTests:XCTestCase {
  func testOnlyLargeNavigableWaterQualifies() {
    XCTAssertTrue(MarinaGenerator.eligibleBody(.ocean,lake:nil))
    XCTAssertFalse(MarinaGenerator.eligibleBody(.lava,lake:nil))
    XCTAssertFalse(MarinaGenerator.eligibleBody(.init(id:9,kind:.river,level:30),lake:nil))
    let small=InlandLake(id:9,x:0,z:0,radiusX:80,radiusZ:80,level:30)
    let large=InlandLake(id:10,x:0,z:0,radiusX:230,radiusZ:220,level:30)
    XCTAssertFalse(MarinaGenerator.eligibleBody(small.body,lake:small))
    XCTAssertFalse(MarinaGenerator.eligibleBody(large.body,lake:small))
    XCTAssertTrue(MarinaGenerator.eligibleBody(large.body,lake:large))
    XCTAssertNil(MarinaGenerator.site(in:.init(0,0),terrain:.init(seed:42,style:.solar)))
  }
  func testRegionalPlacementIsDeterministicAndBerthsOpenIntoWater() throws {
    let terrain=TerrainGenerator(seed:967252643)
    let site=try XCTUnwrap(MarinaGenerator.site(in:.init(-2,0),terrain:terrain))
    XCTAssertTrue(MarinaGenerator.validSite(site,terrain:terrain))
    let again=try XCTUnwrap(MarinaGenerator.site(in:.init(-2,0),terrain:terrain))
    XCTAssertEqual(site.id,again.id);XCTAssertEqual(site.x,again.x);XCTAssertEqual(site.z,again.z)
    XCTAssertGreaterThanOrEqual(site.boats.count,2)
    XCTAssertEqual(Set(site.boats.map(\.id)).count,site.boats.count)
    XCTAssertTrue(site.boats.contains {$0.physics.kind == .dinghy})
    for record in site.boats {
      let p=record.physics
      XCTAssertTrue(record.isValid)
      XCTAssertTrue(SailingPhysics.isNavigable(position:p.position,heading:p.heading,kind:p.kind,
        column:{terrain.column(atX:$0,z:$1)},block:terrain.block),"Berth blocked for \(p.kind) at \(p.position)")
      // Outbound helms start parallel to the finger pier, with no closed end.
      for distance:Float in [4,12,24] {
        XCTAssertTrue(SailingPhysics.isNavigable(position:p.position+p.forward*distance,heading:p.heading,kind:p.kind,
          column:{terrain.column(atX:$0,z:$1)},block:terrain.block),"Exit blocked for \(p.kind)")
      }
    }
  }
  func testGeneratedPiersAndClubhouseMatchBlockCollisionAndEdits() throws {
    let terrain=TerrainGenerator(seed:967252643)
    let site=try XCTUnwrap(MarinaGenerator.site(in:.init(-2,0),terrain:terrain))
    var chunks:[ChunkCoordinate:ChunkData]=[:]
    for local:SIMD3<Float> in [[0.5,0,-50.5],[-30.5,0,8.5],[-40.5,0,8.5],[-47.5,0,16.5],[35.5,0,-83.5],[0.5,0,40.5]] {
      let p=BlockPosition(site.world(local))
      let chunk=chunks[p.chunk] ?? terrain.generate(p.chunk);chunks[p.chunk]=chunk
      for y in (site.floor-16)...(site.floor+24) {
        XCTAssertEqual(chunk[p.x-p.chunk.x*16,y,p.z-p.chunk.z*16],terrain.block(at:.init(p.x,y,p.z)),"At \(p.x),\(y),\(p.z)")
      }
    }
    let deck=BlockPosition(site.world([0.5,-0.5,-50.5]))
    let removed=terrain.generate(deck.chunk,edits:[deck:.air])
    XCTAssertEqual(removed[deck.x-deck.chunk.x*16,deck.y,deck.z-deck.chunk.z*16],.air)
    let decorations=SurfaceDecorationMesher.instances(in:removed,terrain:terrain)
    XCTAssertFalse(decorations.contains{site.contains(x:$0.position.x,z:$0.position.z)})
  }
  func testOceanHarbourDredgingConnectsEveryBerthToDeepWater() throws {
    let terrain=TerrainGenerator(seed:42)
    let site=try XCTUnwrap(MarinaGenerator.site(in:.init(-3,-1),terrain:terrain))
    XCTAssertEqual(site.body.kind,.ocean)
    XCTAssertTrue(MarinaGenerator.validSite(site,terrain:terrain))
    for record in site.boats {
      let p=record.physics
      XCTAssertTrue(SailingPhysics.isNavigable(position:p.position,heading:p.heading,kind:p.kind,
        column:{terrain.column(atX:$0,z:$1)},block:terrain.block))
      // Leave the finger pier, then follow either side of the main pier before
      // merging into the dredged approach. Sample along the whole route.
      let localZ=Float(site.local(x:Int(floor(p.position.x)),z:Int(floor(p.position.z))).y)
      let side:Float=record.id%2 == 1 ? -1:1
      for v in stride(from:localZ,through:Float(-184),by:-2) {
        let point=site.world([side*56,site.body.level-Float(site.floor),v])
        XCTAssertTrue(SailingPhysics.isNavigable(position:point,heading:Float(site.quarterTurn)*Float.pi/2,kind:p.kind,
          column:{terrain.column(atX:$0,z:$1)},block:terrain.block),"Blocked outer fairway for \(p.kind) at \(v)")
      }
    }
    for v in stride(from:-184,through:-304,by:-4) {
      let point=site.world([0,site.body.level-Float(site.floor),Float(v)])
      XCTAssertTrue(SailingPhysics.isNavigable(position:point,heading:Float(site.quarterTurn)*Float.pi/2,kind:.yacht,
        column:{terrain.column(atX:$0,z:$1)},block:terrain.block),"Blocked channel at \(v)")
    }
    let bed=BlockPosition(site.world([0.5,site.body.level-Float(site.floor)-8,-200.5]))
    let column=terrain.column(atX:bed.x,z:bed.z)
    XCTAssertEqual(column.water?.kind,.ocean)
    XCTAssertLessThanOrEqual(column.height,Int(site.body.level)-8)
    let chunk=terrain.generate(bed.chunk)
    for y in column.height...Int(site.body.level)+2 {
      XCTAssertEqual(chunk[bed.x-bed.chunk.x*16,y,bed.z-bed.chunk.z*16],terrain.block(at:.init(bed.x,y,bed.z)))
    }
  }
  func testRotatedClubhouseDoorwayAndBerthsKeepTheirGeometry() {
    for turn in 0..<4 {
      let site=Marina(id:32,x:-400,z:-600,floor:30,quarterTurn:turn,body:.ocean,tier:.regional)
      for local:SIMD3<Float> in [[-30.5,1.5,8.5],[-30.5,4.5,8.5],[-30.5,6.5,8.5]] {
        XCTAssertEqual(site.block(at:.init(site.world(local)),natural:25),.air)
      }
      let deck=BlockPosition(site.world([0.5,-0.5,-50.5]))
      XCTAssertEqual(site.block(at:deck,natural:8),.wood)
      let corner=site.world([-48.5,0,0.5])+[0,0.01,0]
      var player=PlayerPhysics(position:corner)
      XCTAssertFalse(player.collides(at:corner,block:{site.block(at:$0,natural:25) ?? .air}))
      for _ in 0..<15 {player.update(deltaTime:1/90,movement:.zero,jump:false,sprint:false,block:{site.block(at:$0,natural:25) ?? .air})}
      XCTAssertTrue(player.grounded)
    }
  }
  func testFarMeshKeepsGrandClubhouseAndLongPiersWithoutMovingWaterToLand() throws {
    let terrain=TerrainGenerator(seed:967252643)
    let site=try XCTUnwrap(MarinaGenerator.site(in:.init(-2,0),terrain:terrain))
    let p=BlockPosition(site.world([0,0,-88]))
    let tile=TerrainTile(x:floorDivide(p.chunk.x,by:8)*8,z:floorDivide(p.chunk.z,by:8)*8,size:8)
    let detailed=MarinaMesher.build(tile,sites:[site])
    XCTAssertGreaterThan(detailed.indices.count,0)
    XCTAssertLessThan(detailed.indices.count/3,2_000)
    let far=TerrainSurface.build(tile,terrain:terrain)
    XCTAssertGreaterThan(far.water.samples.count,0)
    XCTAssertTrue(far.mesh.positions.allSatisfy{$0.x.isFinite && $0.y.isFinite && $0.z.isFinite})
  }
}
