import XCTest
import simd
@testable import WorldCore

final class RaceTrafficTests: XCTestCase {
  func testRivalCanPassAParkedCarWithoutWaitingForANetworkDecision() {
    let circuit=RaceCircuit(id:9,center:[0,40,0],layout:.speedway)
    let start:Float=30,obstacle=circuit.point(at:start+30)
    let tangent=circuit.tangent(at:start),heading=atan2(-tangent.x,-tangent.z)
    var car=VehiclePhysics(position:circuit.point(at:start),heading:heading,kind:.race)
    let parked=VehicleTraffic(id:2,position:obstacle,previousPosition:obstacle,velocity:.zero,heading:heading,playerDriven:false,kind:.race)
    var driver=RaceDriver()
    var furthest:Float=0
    for _ in 0..<1_200 {
      let observation=RacerObservation(id:1,circuit:circuit,physics:car,traffic:[parked],previous:.steady)
      let controls=driver.controls(physics:car,circuit:circuit,tactic:.steady,observation:observation,seconds:1/30)
      car.update(deltaTime:1/30,throttle:controls.throttle,turn:controls.steering,brake:0,
        block:{ $0.y<40 ? .stone:.air },occupied:{ p,yaw in
          VehiclePhysics.overlaps(position:p,heading:yaw,kind:.race,otherPosition:obstacle,otherHeading:heading,otherKind:.race)
        })
      furthest=max(furthest,circuit.progress(at:car.position))
    }
    XCTAssertGreaterThan(furthest,start+80,"Progress wraps at each completed lap")
    XCTAssertGreaterThan(abs(car.speed),2)
  }
  func testFourRivalsKeepMovingOnActualTrackGeometryWithoutJev() {
    for layout in CircuitLayout.allCases {
      let track=WorldLandmark(id:9,kind:.circuit,x:320,z:320,floor:40,variant:layout.rawValue)
      let circuit=track.circuit
      var cars=(0..<4).map { index -> VehiclePhysics in
        let progress=Float(index)*circuit.length/4+30,d=circuit.tangent(at:progress)
        return .init(position:circuit.point(at:progress,lane:index%2 == 0 ? -2.2:2.2),heading:atan2(-d.x,-d.z),kind:.race)
      }
      var drivers=Array(repeating:RaceDriver(),count:4),blocks:[BlockPosition:Block]=[:]
      var distance=Array(repeating:Float(0),count:4)
      func block(_ p:BlockPosition)->Block {
        if let value=blocks[p] {return value}
        let value=track.block(at:p,surface:track.floor,natural:track.floor-1) ?? .stone
        blocks[p]=value;return value
      }
      for frame in 0..<2_700 {
        for i in cars.indices {
          let traffic=cars.enumerated().map { k,car in VehicleTraffic(id:UInt64(k),position:car.position,
            previousPosition:car.position,velocity:car.velocity,heading:car.heading,playerDriven:false,kind:car.kind) }
          let observation=RacerObservation(id:UInt64(i),circuit:circuit,physics:cars[i],traffic:traffic,previous:.steady)
          let control=drivers[i].controls(physics:cars[i],circuit:circuit,tactic:.steady,observation:observation,seconds:1/30)
          var car=cars[i];let before=car.position
          car.update(deltaTime:1/30,throttle:control.throttle,turn:control.steering,brake:0,block:block,occupied:{ p,yaw in
            cars.indices.contains { $0 != i && VehiclePhysics.overlaps(position:p,heading:yaw,kind:.race,
              otherPosition:cars[$0].position,otherHeading:cars[$0].heading,otherKind:.race) }
          })
          cars[i]=car
          if frame>=1_800 {distance[i]+=simd_distance(before,car.position)}
        }
      }
      for i in cars.indices {XCTAssertGreaterThan(distance[i],100,"\(layout), car \(i) stopped at \(cars[i].position)")}
    }
  }
}
