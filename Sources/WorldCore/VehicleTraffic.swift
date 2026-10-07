import Foundation

public struct VehicleTraffic: Sendable {
  public let id: UInt64
  public let position, previousPosition, velocity: SIMD3<Float>
  public let heading: Float
  public let playerDriven: Bool
  public let kind: VehicleKind
  public init(id: UInt64, position: SIMD3<Float>, previousPosition: SIMD3<Float>, velocity: SIMD3<Float>,
    heading: Float, playerDriven: Bool, kind:VehicleKind = .touring) {
    self.id = id; self.position = position; self.previousPosition = previousPosition
    self.velocity = velocity; self.heading = heading; self.playerDriven = playerDriven; self.kind=kind
  }
  public struct Reaction: Sendable { public let target: SIMD3<Float>; public let bumped: Bool }

  /// Swept contact catches a car crossing between actor ticks. Look-ahead also
  /// works in reverse; a parked car does not continuously frighten pedestrians.
  public func reaction(at feet: SIMD3<Float>, personID: UInt64,
    navigable: (SIMD3<Float>) -> SIMD3<Float>?) -> Reaction? {
    guard abs(feet.y-position.y) < 3.5 else { return nil }
    let speed = (velocity.x*velocity.x + velocity.z*velocity.z).squareRoot()
    let travel = position - previousPosition
    guard speed > 0.15 || travel.x*travel.x + travel.z*travel.z > 0.0001 else { return nil }
    let c = cos(heading), s = sin(heading)
    let right = SIMD3<Float>(c, 0, -s)
    func inCorridor(from start: SIMD3<Float>, to end: SIMD3<Float>, margin: Float) -> Bool {
      let travel = end-start
      let square = travel.x*travel.x + travel.z*travel.z
      let d = feet-start
      let t = square > 0.001 ? min(1, max(0, (d.x*travel.x+d.z*travel.z)/square)) : 0
      let point = start + travel*t
      let offset = feet-point
      return abs(c*offset.x-s*offset.z) < kind.halfWidth + margin
        && abs(s*offset.x+c*offset.z) < kind.halfLength + margin
    }
    let bumped = inCorridor(from: previousPosition, to: position, margin: 0.5)
    guard bumped || inCorridor(from: position, to: position + velocity*0.9, margin: 0.9) else { return nil }
    let delta = feet-position
    let lateral = c*delta.x-s*delta.z
    let first: Float = abs(lateral) > 0.1 ? (lateral > 0 ? 1 : -1) : (personID % 2 == 0 ? 1 : -1)
    for side in [first, -first] {
      let clearance: Float = bumped ? kind.halfWidth+0.9 : kind.halfWidth+3.3
      let displacement = right * (side * clearance - lateral)
      let length = (displacement.x*displacement.x + displacement.z*displacement.z).squareRoot()
      let steps = max(1, Int(ceil(length/0.25)))
      var end = feet, clear = true
      for step in 1...steps {
        var point = feet + displacement * (Float(step)/Float(steps)); point.y = end.y
        guard let next = navigable(point) else { clear = false; break }
        end = next
      }
      if clear { return .init(target: end, bumped: bumped) }
    }
    return nil
  }
}
