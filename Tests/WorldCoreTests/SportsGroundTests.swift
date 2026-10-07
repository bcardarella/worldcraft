import XCTest
import simd
@testable import WorldCore

final class SportsGroundTests: XCTestCase {
  private func site(_ kind: SettlementKind) -> Settlement {
    .init(id:1,kind:kind,name:"Sports town",x:0,z:0,floor:30,ground:.grass)
  }

  func testFieldsHaveRealDimensionsAndRemainInsideTheirReservedParcels() {
    for kind in [SettlementKind.town,.city] {
      let settlement=site(kind)
      let soccer=settlement.sportsGrounds[0],baseball=settlement.sportsGrounds[1]
      XCTAssertEqual(WorldScale.metres(soccer.pitchHalfSize.x*2),kind == .city ? 68:45,accuracy:0.01)
      XCTAssertEqual(WorldScale.metres(soccer.pitchHalfSize.y*2),kind == .city ? 105:90,accuracy:0.01)
      XCTAssertEqual(WorldScale.metres(baseball.basePath)/0.3048,kind == .city ? 90:60,accuracy:0.01)
      XCTAssertEqual(WorldScale.metres(baseball.pitchingDistance)/0.3048,kind == .city ? 60.5:46,accuracy:0.01)
      for field in settlement.sportsGrounds {
        for (x,z) in [(field.x0,field.z0),(field.x1,field.z1)] {
          XCTAssertTrue(settlement.contains(.init(x,0,z)))
          XCTAssertNotNil(settlement.sportsGround(atX:x,z:z))
          XCTAssertFalse(settlement.isRoad(atX:x,z:z))
        }
      }
      for i in 0...90 {
        let angle=Float(i)*Float.pi/180
        let r=baseball.outfieldRadius(u:cos(angle),v:sin(angle))
        let x=baseball.homePlate.x+cos(angle)*r,z=baseball.homePlate.y-sin(angle)*r
        XCTAssertTrue(baseball.contains(x:Int(x),z:Int(z)),"Fence escaped parcel at \(i) degrees")
      }
    }
  }

  func testPlaySurfacesAreLevelAndHaveClearRunoffAndGoalMouths() {
    for kind in [SettlementKind.town,.city] {
      let soccer=site(kind).sportsGrounds[0],c=soccer.center,h=soccer.pitchHalfSize
      for z in stride(from:Int(c.y-h.y-4),through:Int(c.y+h.y+4),by:3) {
        for x in stride(from:Int(c.x-h.x-4),through:Int(c.x+h.x+4),by:3) {
          XCTAssertEqual(soccer.block(x:x,y:-1,z:z),.grass)
          for y in 0...5 {XCTAssertEqual(soccer.block(x:x,y:y,z:z),.air)}
        }
      }
      let baseball=site(kind).sportsGrounds[1],home=baseball.homePlate
      for (u,v) in [(Float(0),Float(0)),(baseball.basePath,0),(0,baseball.basePath),(baseball.basePath,baseball.basePath)] {
        XCTAssertEqual(baseball.surface(x:home.x+u,z:home.y-v),.dirt)
        for y in 0...5 {XCTAssertEqual(baseball.block(x:Int(home.x+u),y:y,z:Int(home.y-v)),.air)}
      }
      let r=baseball.outfieldRadius(u:1,v:1)-3
      XCTAssertEqual(baseball.surface(x:home.x+r/sqrt(2),z:home.y-r/sqrt(2)),.dirt)
    }
  }

  func testPlantDensityIsSubstantiallyLowerWithStableDetailSubsets() {
    let terrain=TerrainGenerator(seed:8192)
    var before=0,after=0,far=0
    for z in -16 ..< -8 {for x in -16 ..< -8 {
      let coordinate=ChunkCoordinate(x,z)
      var chunk=ChunkData(coordinate:coordinate)
      for dz in 0..<16 {for dx in 0..<16 {
        chunk[dx,30,dz] = .grass
        if terrain.hash(x*16+dx,z*16+dz,salt:30+8291)%3 == 0 {before+=1}
      }}
      let near=SurfaceDecorationMesher.instances(in:chunk,terrain:terrain)
      let distant=SurfaceDecorationMesher.instances(in:chunk,terrain:terrain,lush:false)
      after+=near.count; far+=distant.count
      XCTAssertEqual(near,SurfaceDecorationMesher.instances(in:chunk,terrain:terrain))
      let positions=Set(near.map(\.position))
      XCTAssertTrue(distant.allSatisfy{positions.contains($0.position)})
    }}
    XCTAssertGreaterThan(after,before/6)
    XCTAssertLessThan(after,before/3)
    XCTAssertGreaterThan(far,0)
    XCTAssertLessThan(far,after/3)
  }

  func testGeneratedSportsReservationsSuppressAllWildPlantsAtBothDetails() throws {
    let terrain=TerrainGenerator(seed:8192)
    let sites=(-8...8).flatMap {x in (-8...8).compactMap {z in
      SettlementGenerator.site(in:.init(x,z),terrain:terrain)
    }}.filter{!$0.sportsGrounds.isEmpty}
    XCTAssertFalse(sites.isEmpty)
    for settlement in sites.prefix(3) {
      for field in settlement.sportsGrounds {
        for point in [field.center,SIMD2(Float(field.x0+2),Float(field.z0+2)),SIMD2(Float(field.x1-2),Float(field.z1-2))] {
          let coordinate=BlockPosition([point.x,30,point.y]).chunk
          // Deliberately fertile even at the boundary: exclusion must use the
          // land reservation, not chance, soil colour, or the nearest chunk.
          var chunk=ChunkData(coordinate:coordinate)
          for z in 0..<16 {for x in 0..<16 {chunk[x,29,z] = .grass}}
          for lush in [true,false] {
            let plants=SurfaceDecorationMesher.instances(in:chunk,terrain:terrain,lush:lush)
            XCTAssertFalse(plants.contains{field.contains(x:$0.position.x,z:$0.position.z)})
          }
          let generated=terrain.generate(coordinate)
          let plants=SurfaceDecorationMesher.instances(in:generated,terrain:terrain)
          XCTAssertFalse(plants.contains{field.contains(x:$0.position.x,z:$0.position.z)})
        }
      }
    }
  }

  func testFieldMeshesAreStaticBoundedAndRetainedInDistantTiles() {
    // Positive coordinates keep the complete park inside one coarse tile.
    for kind in [SettlementKind.town,.city] {
      let settlement=Settlement(id:1,kind:kind,name:"Park",x:448,z:0,floor:30,ground:.grass)
      for field in settlement.sportsGrounds {
        let coordinate=BlockPosition([field.center.x,30,field.center.y]).chunk
        for size in [1,4,16] {
          let tile=TerrainTile(x:floorDivide(coordinate.x,by:size)*size,z:floorDivide(coordinate.z,by:size)*size,size:size,fullDetail:size == 1)
          let mesh=SportsGroundMesher.build(field,floor:30,tile:tile)
          XCTAssertFalse(mesh.positions.isEmpty)
          XCTAssertLessThan(mesh.faceCount,12_000)
          XCTAssertEqual(Set(mesh.materials),[0])
          XCTAssertTrue(mesh.windWeights.isEmpty)
          XCTAssertTrue(mesh.positions.allSatisfy{$0.x >= -0.001 && $0.z >= -0.001 && $0.x <= Float(tile.blockSize)+0.001 && $0.z <= Float(tile.blockSize)+0.001})
          XCTAssertTrue(mesh.normals.allSatisfy{abs(simd_length($0)-1)<0.001})
          for i in stride(from:0,to:mesh.positions.count,by:4) {
            let face=mesh.positions[i..<i+4]
            if face.allSatisfy({abs($0.y-30.018)<0.00001}) {
              let lo=face.reduce(SIMD3<Float>(repeating:.infinity),simd_min)
              let hi=face.reduce(SIMD3<Float>(repeating:-.infinity),simd_max)
              XCTAssertLessThanOrEqual(hi.x-lo.x,Float(tile.sampleStride)+0.001)
              XCTAssertLessThanOrEqual(hi.z-lo.z,Float(tile.sampleStride)+0.001)
            }
          }
          let packed=PackedTerrainMesh(mesh)
          XCTAssertTrue(packed.vertices.allSatisfy{$0.px.isFinite && $0.py.isFinite && $0.pz.isFinite})
          XCTAssertNil(packed.separatingWind().animated)
        }
      }
    }
  }

  func testPaintDoesNotCoverAHoleDugIntoThePlayingSurface() {
    let field=site(.town).sportsGrounds[0],c=field.center
    let hole=BlockPosition(Int(c.x),29,Int(c.y))
    let tile=TerrainTile(x:hole.chunk.x,z:hole.chunk.z,fullDetail:true)
    let original=SportsGroundMesher.build(field,floor:30,tile:tile)
    let edited=SportsGroundMesher.build(field,floor:30,tile:tile,edits:[hole:.air])
    let target=SIMD2(Float(hole.x)+0.05-Float(tile.x*16),Float(hole.z)+0.05-Float(tile.z*16))
    func covers(_ mesh:VoxelMesh)->Bool {
      for t in stride(from:0,to:mesh.indices.count,by:3) {
        let p=(0..<3).map{mesh.positions[Int(mesh.indices[t+$0])]}
        guard p.allSatisfy({abs($0.y-30)<0.1}) else {continue}
        let a=SIMD2(p[0].x,p[0].z),b=SIMD2(p[1].x,p[1].z),c=SIMD2(p[2].x,p[2].z)
        func cross(_ u:SIMD2<Float>,_ v:SIMD2<Float>)->Float {u.x*v.y-u.y*v.x}
        let area=cross(b-a,c-a)
        guard abs(area)>0.000001 else {continue}
        let u=cross(target-a,c-a)/area,v=cross(b-a,target-a)/area
        if u>=0 && v>=0 && u+v<=1 {return true}
      }
      return false
    }
    XCTAssertTrue(covers(original))
    XCTAssertFalse(covers(edited))
  }

  func testFieldPaintHasNoGapsOrDuplicatesAtChunkSeams() {
    for original in site(.town).sportsGrounds {
      let field=SportsGround(kind:original.kind,x0:32,x1:32+original.x1-original.x0,
        z0:32,z1:32+original.z1-original.z0)
      func area(_ mesh:VoxelMesh)->Float {
        var total:Float=0
        for i in stride(from:0,to:mesh.indices.count,by:3) {
          let a=mesh.positions[Int(mesh.indices[i])],b=mesh.positions[Int(mesh.indices[i+1])],c=mesh.positions[Int(mesh.indices[i+2])]
          guard abs(a.y-b.y)<0.00001,abs(a.y-c.y)<0.00001,
            [Float(0.018),0.04,0.045,0.046,0.05,0.055].contains(where:{abs(a.y-$0)<0.00001}) else {continue}
          total+=simd_length(simd_cross(b-a,c-a))/2
        }
        return total
      }
      let whole=area(SportsGroundMesher.build(field,floor:0,tile:.init(x:0,z:0,size:16)))
      var tiled:Float=0
      for z in floorDivide(field.z0,by:16)...floorDivide(field.z1,by:16) {
        for x in floorDivide(field.x0,by:16)...floorDivide(field.x1,by:16) {
          tiled+=area(SportsGroundMesher.build(field,floor:0,tile:.init(x:x,z:z,fullDetail:true)))
        }
      }
      XCTAssertGreaterThan(whole,500)
      XCTAssertEqual(tiled,whole,accuracy:whole*0.0002)
    }
  }
}
