import XCTest
import simd
@testable import WorldCore

final class SpaceVisualTests:XCTestCase {
  func testPlanetMapsAreSeamlessAndCarrySurfaceAndCloudDetail() {
    for planet in SolarSystem(seed:8192).planets {
      let map=PlanetSurfaceMap.generate(planet,width:64)
      for y in 0..<map.height {
        let a=y*map.width*4,b=a+(map.width-1)*4
        XCTAssertEqual(Array(map.color[a..<a+4]),Array(map.color[b..<b+4]))
        XCTAssertEqual(Array(map.normal[a..<a+4]),Array(map.normal[b..<b+4]))
        XCTAssertEqual(Array(map.clouds[a..<a+4]),Array(map.clouds[b..<b+4]))
      }
      XCTAssertGreaterThan(Set(map.color).count,50)
      XCTAssertGreaterThan(Set(map.roughness).count,1)
      if !planet.isStar { XCTAssertGreaterThan(Set(stride(from:3,to:map.clouds.count,by:4).map {map.clouds[$0]}).count,15) }
    }
  }
  func testAtmosphereBridgePreservesViewAndWaitsForTerrain() {
    var departure=AtmosphereTransition(surface:[2,200,3],space:[1000,800,-700],arriving:false)
    XCTAssertEqual(departure.surfaceOpacity,1)
    let motion=SIMD3<Float>(4,7,-9)
    XCTAssertEqual(departure.surfacePoint(departure.spaceAnchor+motion),departure.surfaceAnchor+motion)
    departure.advance(2.5)
    XCTAssertEqual(departure.surfaceOpacity,0.5,accuracy:0.001)
    departure.advance(10); XCTAssertTrue(departure.finished); XCTAssertEqual(departure.surfaceOpacity,0)
    var arrival=AtmosphereTransition(surface:[2,170,3],space:[1000,800,-700],arriving:true)
    arrival.advance(10,ready:false); XCTAssertEqual(arrival.surfaceOpacity,0)
    arrival.advance(5); XCTAssertEqual(arrival.surfaceOpacity,1)
    let head=PlayerFrame(referenceEye:[0,1.7,0],feet:arrival.surfaceAnchor-[0,PlayerPhysics.eyeHeight,0],heading:1,pitch:0.5)
    var far=head; far.feet=arrival.spacePoint(head.feet)
    XCTAssertLessThan(simd_distance(head.trackedPoint(fromWorld:arrival.surfaceAnchor+motion),far.trackedPoint(fromWorld:arrival.spaceAnchor+motion)),0.001)
  }
}
