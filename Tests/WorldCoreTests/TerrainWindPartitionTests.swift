import XCTest
@testable import WorldCore

final class TerrainWindPartitionTests: XCTestCase {
  private func signature(_ vertex: TerrainVertex) -> [UInt32] {
    [vertex.px.bitPattern, vertex.py.bitPattern, vertex.pz.bitPattern, UInt32(vertex.u), UInt32(vertex.v)]
      + (0..<4).flatMap { [UInt32(vertex.normal[$0]), UInt32(vertex.tangent[$0]), UInt32(vertex.bitangent[$0])] }
  }
  private func equal(_ first: PackedTerrainMesh, _ second: PackedTerrainMesh,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(first.vertices.map(signature), second.vertices.map(signature), file: file, line: line)
    XCTAssertEqual(first.indices, second.indices, file: file, line: line)
    XCTAssertEqual(first.parts.count, second.parts.count, file: file, line: line)
    XCTAssertEqual(first.byteCount, second.byteCount, file: file, line: line)
    for (a,b) in zip(first.parts,second.parts) {
      XCTAssertEqual(a.offset,b.offset,file:file,line:line); XCTAssertEqual(a.count,b.count,file:file,line:line)
      XCTAssertEqual(a.material,b.material,file:file,line:line)
      XCTAssertEqual(a.minimum,b.minimum,file:file,line:line); XCTAssertEqual(a.maximum,b.maximum,file:file,line:line)
    }
  }
  private func compare(_ mesh: PackedTerrainMesh, file: StaticString = #filePath, line: UInt = #line) {
    let reference = mesh.separatingWind(indexed: false), candidate = mesh.separatingWind()
    equal(candidate.stationary,reference.stationary,file:file,line:line)
    XCTAssertEqual(candidate.animated == nil,reference.animated == nil,file:file,line:line)
    if let actual = candidate.animated, let expected = reference.animated { equal(actual,expected,file:file,line:line) }
    XCTAssertEqual(candidate.stationary.indices.count+(candidate.animated?.indices.count ?? 0),mesh.indices.count,file:file,line:line)
  }

  func testSharedVerticesMixedWeightsAndRepeatedMaterialPartsKeepExactOrder() {
    var vertices = (0..<97).map { i in
      var value = TerrainVertex(position: [Float(i%11),Float(i/11),-Float(i%7)],normal:[0,1,0],
        uv:[Float(i)/128,Float(i)/64],tangent:[1,0,0],bitangent:[0,0,1])
      value.normal.w = i%9 == 0 ? Float16(0.35).bitPattern : 0
      value.tangent.w = Float16(i%128).bitPattern
      return value
    }
    // Preserve raw weight semantics, including negative zero and NaN. No float
    // equality, canonicalization or welding is permitted in this remap.
    vertices[2].normal.w = 0x8000; vertices[3].normal.w = 0x7e00
    vertices[4].px = -0.0
    var indices: [UInt32] = []
    for i in 0..<300 {
      indices.append(UInt32((i*17)%97))
      indices.append(UInt32((i*7+1)%97))
      indices.append(UInt32((i*5+2)%97))
    }
    let parts: [PackedTerrainMesh.Part] = (0..<10).map { i in
      .init(offset:i*90,count:90,material:i%4,minimum:[0,0,-7],maximum:[11,9,0])
    }
    let mesh = PackedTerrainMesh(vertices:vertices,indices:indices,parts:parts)
    compare(mesh)
    let split = mesh.separatingWind()
    XCTAssertFalse(split.stationary.vertices.isEmpty)
    XCTAssertFalse(split.animated!.vertices.isEmpty)
    let stationary = Set(split.stationary.vertices.map(signature))
    XCTAssertFalse(stationary.intersection(Set(split.animated!.vertices.map(signature))).isEmpty,
      "Zero-weight shared corners may participate in both static and moving triangles")
  }

  func testEmptyStaticMovingAndUnreferencedWeightSemantics() {
    compare(.init(VoxelMesh()))
    var box = VoxelMesh(); box.appendBox(size:.one,center:.zero,material:0)
    compare(.init(box))
    box.windWeights = .init(repeating:1,count:box.positions.count)
    let moving = PackedTerrainMesh(box); compare(moving)
    XCTAssertTrue(moving.separatingWind().stationary.parts.isEmpty)
    var vertices = PackedTerrainMesh(VoxelMesh()).vertices
    var orphan = TerrainVertex(position:.zero,normal:[0,1,0],uv:.zero,tangent:[1,0,0],bitangent:[0,0,1])
    orphan.normal.w = Float16(1).bitPattern; vertices.append(orphan)
    let mesh = PackedTerrainMesh(vertices:vertices,indices:[],parts:[])
    compare(mesh)
    XCTAssertNotNil(mesh.separatingWind().animated, "Retain the original unused-weight behavior")
  }

  func testProceduralChunkPlantsEditsAndAtlasModesRemainByteIdentical() throws {
    for style in PlanetStyle.allCases {
      let terrain = TerrainGenerator(seed:1667327165707871140,style:style)
      for coordinate in [ChunkCoordinate(19,51),.init(-2,-3)] {
        let edits: [BlockPosition:Block] = [.init(coordinate.x*16+2,80,coordinate.z*16+2):.glass,
          .init(coordinate.x*16+3,80,coordinate.z*16+2):.woodStairsEast,
          .init(coordinate.x*16+4,80,coordinate.z*16+2):.torch]
        let chunk = terrain.generate(coordinate,edits:edits)
        let plants = SurfaceDecorationMesher.instances(in:chunk,terrain:terrain,lush:true,changes:[:])
        for repeating in [false,true] {
          var mesh = VoxelMesher.build(chunk,includeWater:false,repeatAtlas:repeating)
          mesh.append(SurfaceDecorationMesher.mesh(plants,chunk:coordinate))
          let packed = PackedTerrainMesh(mesh,repeatOpaqueAtlas:repeating)
          compare(packed)
          let request = TerrainPreparationRequest(id:.init(world:UUID(),tile:.init(x:coordinate.x,z:coordinate.z,fullDetail:true),
            revision:1,lush:true,repeatAtlas:repeating),terrain:terrain,edits:edits,service:.detail,priority:0)
          let key = TerrainPayloadKey(request)
          let archives = [false,true].map { indexed in
            let split = packed.separatingWind(indexed:indexed)
            return TerrainPayloadCodec.encode(.init(id:request.id,chunk:chunk,mesh:split.stationary,animated:split.animated,
              water:.init(WaterPatch.build(chunk,terrain:terrain)),plants:plants,lamps:mesh.lampPositions,fires:mesh.firePositions),key:key)
          }
          XCTAssertNotNil(archives[0]); XCTAssertEqual(archives[0],archives[1])
        }
      }
    }
  }
}
