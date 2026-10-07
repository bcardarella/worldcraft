import XCTest
import simd
@testable import WorldCore

final class BaseballStadiumTests: XCTestCase {
  let terrain = TerrainGenerator(seed:8192)
  private func city(x:Int=0,z:Int=0) -> Settlement {
    .init(id:1,kind:.city,name:"Ballpark",x:x,z:z,floor:30,ground:.grass)
  }

  func testOnlySurfaceCitiesReserveTheLargerStadiumAndKeepPlayingDimensions() throws {
    let site=city(),field=site.sportsGrounds[1]
    XCTAssertTrue(field.hasStadium)
    XCTAssertGreaterThanOrEqual(field.x1-field.x0,320)
    XCTAssertEqual(WorldScale.metres(field.basePath),27.432,accuracy:0.001)
    let stadium=try XCTUnwrap(field.stadium)
    for angle in stride(from:Float(0),through:Float.pi/2,by:Float.pi/40) {
      let p=field.homePlate+SIMD2(-cos(angle),sin(angle))*Float(BaseballStadium.outerRadius)
      XCTAssertTrue(field.contains(x:Int(p.x),z:Int(p.y)))
      XCTAssertTrue(site.contains(.init(Int(p.x),0,Int(p.y))))
      XCTAssertFalse(site.isRoad(atX:Int(p.x),z:Int(p.y)))
    }
    for third in [false,true] {
      let at=BlockPosition(stadium.point(along:50,depth:50,y:30,thirdBase:third))
      XCTAssertNil(site.building(lotX:floorDivide(at.x,by:site.spacing),lotZ:floorDivide(at.z,by:site.spacing),terrain:terrain))
    }
    for kind in [SettlementKind.village,.town] {
      let other=Settlement(id:2,kind:kind,name:"Small",x:0,z:0,floor:30,ground:.grass)
      XCTAssertFalse(other.sportsGrounds.contains(where:\.hasStadium))
    }
    for habitat in [SettlementHabitat.solar,.aquatic] {
      var other=site;other.habitat=habitat
      XCTAssertFalse(other.sportsGrounds.contains(where:\.hasStadium))
    }
  }

  private func walk(_ player:inout PlayerPhysics,to target:SIMD3<Float>,
    block:(BlockPosition)->Block,file:StaticString=#filePath,line:UInt=#line) {
    let distance=simd_length(SIMD2(target.x-player.position.x,target.z-player.position.z))
    let frames=Int(ceil(distance/6.6*90))*2+180
    for _ in 0..<frames {
      let delta=SIMD3<Float>(target.x-player.position.x,0,target.z-player.position.z)
      if simd_length(delta)<0.10 {break}
      player.update(deltaTime:1/90,movement:simd_normalize(delta),jump:false,sprint:false,block:block)
    }
    for _ in 0..<40 {player.update(deltaTime:1/90,movement:.zero,jump:false,sprint:false,block:block)}
    XCTAssertLessThan(simd_length(SIMD2(target.x-player.position.x,target.z-player.position.z)),0.15,
      "Stopped at \(player.position), wanted \(target)",file:file,line:line)
    XCTAssertEqual(player.position.y,target.y,accuracy:0.08,file:file,line:line)
    XCTAssertFalse(player.collides(at:player.position,block:block),file:file,line:line)
  }

  func testWalkFromEachDugoutEntranceDownToTheLockerRoomAndBackWithoutJumping() throws {
    // Offset through negative world coordinates as well as across chunk seams.
    let site=city(x:-513,z:-897),stadium=try XCTUnwrap(site.sportsGrounds[1].stadium)
    var cache:[BlockPosition:Block]=[:]
    let block:(BlockPosition)->Block = { p in
      if let cached=cache[p] {return cached}
      let value=site.block(at:p,terrain:self.terrain) ?? (p.y<site.floor ? .stone:.air)
      cache[p]=value;return value
    }
    for third in [false,true] {
      func p(_ a:Float,_ d:Float,_ y:Float)->SIMD3<Float> {
        stadium.point(along:a,depth:d,y:Float(site.floor)+y,thirdBase:third)
      }
      for entrance:Float in [25.5,69.5] {
        var player=PlayerPhysics(position:p(entrance,2,0.01));player.grounded=true
        let route=[p(entrance,13,-3),p(50.5,13,-3),p(50.5,44,-11),p(50.5,60,-11)]
        for target in route {walk(&player,to:target,block:block)}
        // Benches flank the main aisle; walk around them to reach locker bays.
        walk(&player,to:p(61,60,-11),block:block)
        walk(&player,to:p(50.5,60,-11),block:block)
        for target in route.dropLast().reversed() {walk(&player,to:target,block:block)}
        walk(&player,to:p(entrance,2,0),block:block)
      }
    }
  }

  func testGrandstandAislesClimbBothTiersAndTheHomePlateCorner() throws {
    let site=city(),stadium=try XCTUnwrap(site.sportsGrounds[1].stadium)
    let block:(BlockPosition)->Block = { site.block(at:$0,terrain:self.terrain) ?? .stone }
    for third in [false,true] {
      for aisle:Float in [16,112,160] {
        var start=stadium.point(along:aisle,depth:19,y:30.01,thirdBase:third)
        var player=PlayerPhysics(position:start);player.grounded=true
        let top=stadium.point(along:aisle,depth:71,y:44,thirdBase:third)
        walk(&player,to:top,block:block)
        start.y=30;walk(&player,to:start,block:block)
      }
    }
    let direction=SIMD3<Float>(-1,0,1)/sqrt(2)
    let home=SIMD3<Float>(stadium.field.homePlate.x,30,stadium.field.homePlate.y)
    var player=PlayerPhysics(position:home+direction*19+[0,0.01,0]);player.grounded=true
    walk(&player,to:home+direction*71+[0,14,0],block:block)
    walk(&player,to:home+direction*19,block:block)
  }

  func testGeneratedBasementsMatchQueriesAndHonorPlayerEdits() throws {
    let site=try XCTUnwrap((-8...8).lazy.flatMap {x in (-8...8).lazy.compactMap {z in
      SettlementGenerator.site(in:.init(x,z),terrain:self.terrain)
    }}.first {$0.sportsGrounds.contains(where:\.hasStadium)})
    let stadium=try XCTUnwrap(site.sportsGrounds.last?.stadium)
    var chunks:[ChunkCoordinate:ChunkData]=[:]
    for third in [false,true] {
      for (a,d):(Float,Float) in [(25,6),(50,20),(50,24),(50,31),(50,38),(50,50),(30,63),(112,60)] {
        let p=BlockPosition(stadium.point(along:a,depth:d,y:Float(site.floor),thirdBase:third))
        let chunk=chunks[p.chunk] ?? terrain.generate(p.chunk);chunks[p.chunk]=chunk
        for y in (site.floor-13)...(site.floor+23) {
          XCTAssertEqual(chunk[p.x-p.chunk.x*16,y,p.z-p.chunk.z*16],terrain.block(at:.init(p.x,y,p.z)),
            "Generation/query mismatch at \(p.x),\(y),\(p.z)")
        }
      }
    }
    let room=BlockPosition(stadium.point(along:50,depth:50,y:Float(site.floor-10)))
    XCTAssertEqual(terrain.block(at:room),.air)
    let edited=terrain.generate(room.chunk,edits:[room:.brick])
    XCTAssertEqual(edited[room.x-room.chunk.x*16,room.y,room.z-room.chunk.z*16],.brick)
    let fixture=BlockPosition(stadium.point(along:40,depth:44,y:Float(site.floor-5)))
    let litChunk=terrain.generate(fixture.chunk)
    XCTAssertEqual(terrain.block(at:fixture),.lantern)
    let fixtures=VoxelMesher.build(litChunk).lampPositions
    XCTAssertTrue(fixtures.contains { simd_distance($0+fixture.chunk.origin,fixture.center)<0.01 })
  }

  func testCarsParkOutsideTheStadiumAndItsUndergroundEntrances() {
    for kind in [SettlementKind.town,.city] {
      let site=Settlement(id:1,kind:kind,name:"Parking",x:-511,z:713,floor:30,ground:.grass)
      var positions=Set<SIMD3<Float>>()
      for i in 0..<site.vehicleCount {
        let at=site.vehiclePosition(i)
        XCTAssertTrue(positions.insert(at).inserted)
        XCTAssertTrue(site.contains(.init(at)))
        XCTAssertTrue(site.isRoad(atX:Int(at.x.rounded(.down)),z:Int(at.z.rounded(.down))))
        XCTAssertNil(site.sportsGround(atX:Int(at.x.rounded(.down)),z:Int(at.z.rounded(.down))))
        XCTAssertTrue(VehiclePhysics.isClear(at:at,heading:0,block:{site.block(at:$0,terrain:self.terrain) ?? .stone}))
      }
    }
  }

  func testStaticSeatingAndBowlSurviveLODWithinBoundedMeshes() throws {
    let site=city(),field=site.sportsGrounds[1],stadium=try XCTUnwrap(field.stadium)
    for point in [stadium.point(along:40,depth:40,y:30),
      SIMD3<Float>(field.homePlate.x-42,30,field.homePlate.y+42)] {
      let coordinate=BlockPosition(point).chunk
      for size in [1,4,16,32] {
        let tile=TerrainTile(x:floorDivide(coordinate.x,by:size)*size,z:floorDivide(coordinate.z,by:size)*size,
          size:size,fullDetail:size == 1)
        let mesh=SportsGroundMesher.build(field,floor:30,tile:tile)
        XCTAssertFalse(mesh.positions.isEmpty)
        XCTAssertLessThan(mesh.faceCount,32_000)
        XCTAssertTrue(mesh.windWeights.isEmpty)
        XCTAssertEqual(Set(mesh.materials),[0])
        XCTAssertTrue(mesh.positions.allSatisfy {$0.x >= -0.001 && $0.z >= -0.001 && $0.x <= Float(tile.blockSize)+0.001 && $0.z <= Float(tile.blockSize)+0.001})
        if size >= 16 {
          XCTAssertGreaterThan(mesh.positions.map(\.y).max() ?? 0,51)
          XCTAssertTrue(mesh.normals.contains {$0.y>0.99})
        }
      }
    }
  }
}
