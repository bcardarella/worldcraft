import XCTest
@testable import WorldCore

final class WaterWaveEnvelopeTests:XCTestCase {
  func testEveryBodyAndDepthEnclosesSampledWavesAndMaximumAdmittedRipples() {
    let bodies:[WaterBody] = [.ocean,.lava,.init(id:3,kind:.lake,level:47),
      .init(id:4,kind:.river,level:-13.2,current:[0.7,0,0.3])]
    for body in bodies {for depth:Float in [0,0.2,1,3,5,20] {
      let range=WaterWaveEnvelope.verticalRange(depth:depth,body:body)
      let undisturbed=WaterWaveEnvelope.verticalRange(depth:depth,body:body,includingDisturbances:false)
      for t in stride(from:0.0,through:10_020.0,by:137.0) {
        var environment=WorldEnvironment(elapsed:t)
        for i in 0..<40 {environment.disturbWater(atX:Float(i%4)*0.21-1,z:Float(i%3)*0.19,body:body,energy:1)}
        XCTAssertEqual(environment.disturbances.count,24)
        XCTAssertTrue(environment.disturbances.allSatisfy {$0.energy==0.35})
        for age in [0.0,0.1,0.4,1.0,4.5] {
          var aged=environment;aged.advance(age)
          for x:Float in [-16,-2,-0.3,0,0.4,1,4,16,10_000] {
            let value=aged.water(atX:x,z:x*0.27,depth:depth,body:body).height
            XCTAssertTrue(range.contains(value),"\(body.kind) \(depth) \(value) outside \(range)")
            let base=WorldEnvironment(elapsed:t+age).water(atX:x,z:x*0.27,depth:depth,body:body).height
            XCTAssertTrue(undisturbed.contains(base))
          }
        }
      }
    }}
  }
  func testBoundsCoverTheConservativeOceanLimitBeyondTheOldTenBlocks() {
    let body=WaterBody.ocean,range=WaterWaveEnvelope.verticalRange(depth:20,body:body)
    let bound:Float=0.65+(0.42+0.22+0.13+0.045)*1.18+24*0.35
    XCTAssertGreaterThan(bound,10)
    XCTAssertLessThan(range.lowerBound,body.level-bound)
    XCTAssertGreaterThan(range.upperBound,body.level+bound)
    let still=WaterWaveEnvelope.verticalRange(depth:20,body:.init(id:1,kind:.lake,level:24),includingDisturbances:false)
    XCTAssertLessThan(still.upperBound-still.lowerBound,0.003)
  }
  func testPackedSlicesAndMergedPartsEncloseMixedHeightAndKindBounds() {
    let a=TerrainTile(x:-4,z:8,fullDetail:true),b=TerrainTile(x:-3,z:8,fullDetail:true)
    var water=WaterGeometry()
    water.samples=[.init(position:[0,0],depth:20,body:.ocean),
      .init(position:[0,16],depth:1,body:.init(id:3,kind:.river,level:63.4)),
      .init(position:[16,0],depth:4,body:.lava)]
    water.shallowIndices=[0,1,2]
    let batch=WaterMeshBatch(key:.init(a),geometry:[a:water,b:water])
    let parts=batch.parts(visible:[a,b],bands:[:])
    XCTAssertEqual(parts.count,1)
    for slice in batch.slices {for sample in water.samples {
      let bounds=WaterWaveEnvelope.verticalRange(depth:sample.depth,body:sample.body)
      XCTAssertLessThanOrEqual(slice.minimum.y,bounds.lowerBound)
      XCTAssertGreaterThanOrEqual(slice.maximum.y,bounds.upperBound)
      XCTAssertLessThanOrEqual(parts[0].minimum.y,bounds.lowerBound)
      XCTAssertGreaterThanOrEqual(parts[0].maximum.y,bounds.upperBound)
    }}
  }
}
