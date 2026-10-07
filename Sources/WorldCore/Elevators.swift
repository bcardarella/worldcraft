import Foundation

public struct ElevatorShaft: Sendable, Equatable {
  public let id: UInt64
  /// Center at the ground floor's standing surface.
  public let origin: SIMD3<Float>
  public let storey: Int
  public let floors: Int
  public init(id: UInt64, origin: SIMD3<Float>, storey: Int, floors: Int) {
    self.id=id; self.origin=origin; self.storey=storey; self.floors=max(1,floors)
  }
  public func height(of floor: Int) -> Float { origin.y+Float(max(0,min(floors-1,floor))*storey) }
  public func nearestFloor(to y: Float) -> Int { max(0,min(floors-1,Int(((y-origin.y)/Float(storey)).rounded()))) }
  public func contains(_ feet: SIMD3<Float>, at height: Float) -> Bool {
    abs(feet.x-origin.x)<2.35 && abs(feet.z-origin.z)<2.35 && abs(feet.y-height)<0.25
  }
}

public struct ElevatorMotion: Sendable {
  public let shaft: ElevatorShaft
  public private(set) var floor: Int
  public private(set) var target: Int
  public private(set) var height: Float
  public private(set) var doorOpen: Float = 1
  public private(set) var travelling = false
  private var speed: Float = 0
  public init(shaft: ElevatorShaft, floor: Int) {
    self.shaft=shaft; self.floor=max(0,min(shaft.floors-1,floor)); target=self.floor
    height=shaft.height(of:self.floor)
  }
  public mutating func request(_ floor: Int) {
    guard !travelling else { return }
    target=max(0,min(shaft.floors-1,floor)); travelling=target != self.floor
  }
  public mutating func advance(seconds: Float, obstructed: Bool = false) {
    let dt=max(0,min(0.05,seconds))
    guard dt>0 else { return }
    if !travelling { doorOpen=min(1,doorOpen+dt*1.8); return }
    if obstructed { speed=0; return }
    if doorOpen>0 { doorOpen=max(0,doorOpen-dt*1.8); return }
    let distance=shaft.height(of:target)-height
    let desired=min(6,sqrt(abs(distance)*8))
    speed=min(desired,speed+4*dt)
    let step=min(abs(distance),max(0.05,speed)*dt)
    height += distance>=0 ? step : -step
    if abs(distance)<=step+0.002 { height=shaft.height(of:target); floor=target; travelling=false; speed=0 }
  }
}

extension Settlement {
  public func elevator(lotX: Int, lotZ: Int, terrain: TerrainGenerator) -> ElevatorShaft? {
    guard let building=building(lotX:lotX,lotZ:lotZ,terrain:terrain), building.hasElevator else { return nil }
    return .init(id:building.hash,origin:[Float(x+lotX*spacing+building.minimum+6)+0.5,
      Float(floor+1),Float(z+lotZ*spacing+building.minimum+9)+0.5],storey:building.storey,floors:building.floorCount)
  }
}
