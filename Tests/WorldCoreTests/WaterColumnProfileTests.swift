import XCTest
@testable import WorldCore

final class WaterColumnProfileTests: XCTestCase {
  private func inspect(_ chunk:ChunkData,x:Int=0,z:Int=0,body:WaterBody? = .ocean,
    file:StaticString = #filePath,line:UInt = #line) throws -> WaterColumnProfile {
    guard case let .ready(value)=WaterColumnProfile.inspect(chunk,x:x,z:z,body:body) else {
      XCTFail("Expected a complete column",file:file,line:line);throw Failure.invalid
    }
    return value
  }
  private enum Failure:Error {case invalid}
  private func column(_ liquid:Block = .water,upper:Int=24)->ChunkData {
    var chunk=ChunkData(coordinate:.init(-2,7))
    chunk[0,3,0] = .sand
    for y in 4..<upper {chunk[0,y,0]=liquid}
    return chunk
  }
  func testActualLiquidAndFractionalRiverAgreeWithGeneratorConvention() throws {
    for body in [WaterBody.ocean,.init(id:8,kind:.lake,level:38),
      .init(id:9,kind:.river,level:38.125,current:[0.8,0,0.2]),.lava] {
      let upper=Int(ceil(body.level)),block:Block=body.kind == .lava ? .lava:.water
      let result=try inspect(column(block,upper:upper),body:body)
      XCTAssertEqual(result.proceduralSurface,0)
      XCTAssertEqual(result.spans.count,1);XCTAssertEqual(result.spans[0].lower,4)
      XCTAssertEqual(result.spans[0].upper,upper);XCTAssertEqual(result.spans[0].material,block)
      XCTAssertTrue(result.additionalSurfaces.isEmpty);XCTAssertTrue(result.unsupportedBottoms.isEmpty)
    }
  }
  func testRemovedTopWaterDoesNotReappearFromProceduralBody() throws {
    var chunk=column();chunk[0,23,0] = .air
    let removed=try inspect(chunk)
    XCTAssertNil(removed.proceduralSurface);XCTAssertEqual(removed.additionalSurfaces,[0])
    XCTAssertEqual(removed.spans[0].upper,23)
    for y in 4..<23 {chunk[0,y,0] = .air}
    let dry=try inspect(chunk)
    XCTAssertTrue(dry.spans.isEmpty);XCTAssertNil(dry.proceduralSurface)
    XCTAssertTrue(dry.additionalSurfaces.isEmpty)
  }
  func testPlacedFluidsRequireTheirOwnSurfaceIdentityAndDoNotBorrowOceanKind() throws {
    let placed=try inspect(column(upper:60),body:nil)
    XCTAssertNil(placed.proceduralSurface);XCTAssertEqual(placed.additionalSurfaces,[0])
    let raised=try inspect(column(upper:60))
    XCTAssertNil(raised.proceduralSurface);XCTAssertEqual(raised.additionalSurfaces,[0])
    let lavaInWater=try inspect(column(.lava))
    XCTAssertNil(lavaInWater.proceduralSurface);XCTAssertEqual(lavaInWater.additionalSurfaces,[0])
    let waterInLava=try inspect(column(),body:.lava)
    XCTAssertNil(waterInLava.proceduralSurface);XCTAssertEqual(waterInLava.additionalSurfaces,[0])
  }
  func testRoofsHolesAndTransparentOrShapedBoundariesRemainDistinct() throws {
    var chunk=column();chunk[0,24,0] = .stone
    let roof=try inspect(chunk)
    XCTAssertNil(roof.proceduralSurface);XCTAssertTrue(roof.additionalSurfaces.isEmpty)
    for block in [Block.glass,.leaves,.cherryLeaves,.woodStairsEast,.torch,.lantern] {
      chunk[0,24,0]=block;chunk[0,3,0]=block
      let value=try inspect(chunk)
      XCTAssertEqual(value.proceduralSurface,0);XCTAssertEqual(value.unsupportedBottoms,[0])
      XCTAssertFalse(value.spans[0].coveredAbove)
    }
    chunk[0,24,0] = .air;chunk[0,3,0] = .sand;chunk[0,11,0] = .air
    let cavity=try inspect(chunk)
    XCTAssertEqual(cavity.spans.map(\.lower),[4,12]);XCTAssertEqual(cavity.spans.map(\.upper),[11,24])
    XCTAssertEqual(cavity.proceduralSurface,1);XCTAssertEqual(cavity.additionalSurfaces,[0])
    XCTAssertEqual(cavity.unsupportedBottoms,[1])
  }
  func testMultipleKindsAndSnapshotBoundsNeverPretendToBeClosedVolumes() throws {
    var chunk=ChunkData(coordinate:.init(0,0))
    for y in ChunkData.minimumY..<0 {chunk[0,y,0] = .lava}
    for y in 0..<24 {chunk[0,y,0] = .water}
    chunk[0,127,0] = .water
    let result=try inspect(chunk)
    XCTAssertEqual(result.spans.map(\.material),[.lava,.water,.water])
    XCTAssertEqual(result.proceduralSurface,1);XCTAssertEqual(result.additionalSurfaces,[0,2])
    XCTAssertEqual(result.unsupportedBottoms,[0,1,2])
    XCTAssertNil(try inspect(chunk,body:.init(id:1,kind:.lake,level:128)).proceduralSurface)
    for x in [-2,17] {
      XCTAssertEqual(WaterColumnProfile.inspect(chunk,x:x,z:0,body:nil),.invalidInput)
    }
    for level:Float in [.nan,.infinity,-65,-64,129] {
      XCTAssertEqual(WaterColumnProfile.inspect(chunk,x:0,z:0,body:.init(id:0,kind:.lake,level:level)),.invalidInput)
    }
  }
  func testHaloAndFrozenProfilesAgreeWithIndependentCellEnumeration() throws {
    var chunk=column(),copy=chunk
    for y in 4..<24 {chunk[-1,y,16] = .water};chunk[-1,3,16] = .sand
    let frozen=try inspect(chunk,x:-1,z:16)
    for y in 4..<24 {copy[0,y,0] = .air}
    XCTAssertNil(try inspect(copy).proceduralSurface)
    XCTAssertEqual(frozen.proceduralSurface,0)
    for x in -1...16 {for z in -1...16 {
      let result=try inspect(chunk,x:x,z:z)
      var reconstructed:[Int:Block]=[:]
      for span in result.spans {for y in span.lower..<span.upper {
        XCTAssertNil(reconstructed.updateValue(span.material,forKey:y))
      }}
      for y in ChunkData.minimumY..<ChunkData.height {
        XCTAssertEqual(reconstructed[y],chunk[x,y,z].isLiquid ? chunk[x,y,z]:nil)
      }
    }}
  }
  func testCancellationNeverReturnsAColumnProof() async {
    let result=await Task.detached {
      withUnsafeCurrentTask {$0?.cancel()}
      return WaterColumnProfile.inspect(ChunkData(coordinate:.init(0,0)),x:0,z:0,body:nil)
    }.value
    XCTAssertEqual(result,.cancelled)
  }
}
