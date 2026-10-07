import Foundation
import simd

/// The route belongs to the driver, not the rendered model. Preserve it when a
/// car leaves the presentation radius or the world is saved.
public struct CityTrafficDriver: Codable, Sendable {
  public let route: [SIMD3<Float>]
  public private(set) var waypoint: Int
  public static let parked = Self(route: [])

  public init(route: [SIMD3<Float>], waypoint: Int = 0) {
    self.route = route; self.waypoint = waypoint
  }
  public var isActive: Bool { !route.isEmpty }
  public var isValid: Bool {
    if route.isEmpty { return waypoint == 0 }
    return (3...16).contains(route.count) && route.indices.contains(waypoint)
      && route.allSatisfy { p in (0..<3).allSatisfy { p[$0].isFinite && abs(p[$0]) < 100_000_000 } }
      && route.indices.allSatisfy { simd_distance_squared(route[$0], route[($0+1)%route.count]) > 1 }
  }

  public static func carID(in site: Settlement, index: Int) -> UInt64 {
    site.id &+ UInt64(index + 1) &* 0xC2B2_AE3D_27D4_EB4F
  }

  public static func spawned(in site: Settlement, index: Int) -> Self {
    guard site.kind == .city, site.habitat != .aquatic,
      (0..<site.vehicleCount).contains(index), index % 3 != 0 else { return .parked }
    let extent = Float(site.spacing)
    let route: [SIMD3<Float>] = [[3.5,0,3.5], [extent+3.5,0,3.5],
      [extent+3.5,0,extent+3.5], [3.5,0,extent+3.5]].map { site.vehicleDistrict(index)+$0 }
    // Sports superblocks remove interior roads. Never reanimate a car onto a
    // route through a pitch, dugout or stadium.
    for i in route.indices {
      let a=route[i], b=route[(i+1)%route.count]
      let steps=max(1,Int(ceil(simd_distance(a,b)/2)))
      for step in 0...steps {
        let p=a+(b-a)*Float(step)/Float(steps)
        let block=BlockPosition(p)
        guard site.contains(block), site.isRoad(atX:block.x,z:block.z) else { return .parked }
      }
    }
    return .init(route: route)
  }

  /// Older saves did not distinguish traffic from parked cars. Recover only a
  /// known city-traffic identity still aligned with its original road loop.
  public mutating func rejoin(position: SIMD3<Float>, heading: Float) -> Bool {
    guard isActive, isValid else { return false }
    let forward=SIMD3<Float>(-sin(heading),0,-cos(heading))
    var nearest: (distance: Float, end: Int)?
    for i in route.indices {
      let end=(i+1)%route.count, edge=route[end]-route[i]
      let along=max(0,min(1,simd_dot(position-route[i],edge)/simd_length_squared(edge)))
      let distance=simd_distance_squared(position,route[i]+edge*along)
      guard distance < 6*6, simd_dot(forward,simd_normalize(edge)) > 0.5 else { continue }
      if nearest == nil || distance < nearest!.distance { nearest=(distance,end) }
    }
    guard let nearest else { return false }
    waypoint=nearest.end
    return true
  }

  public mutating func update(physics: inout VehiclePhysics, seconds: Float,
    block: (BlockPosition)->Block, occupied: (SIMD3<Float>,Float)->Bool = { _,_ in false }) {
    guard isActive, isValid, seconds > 0 else { return }
    var difference=route[waypoint]-physics.position
    if simd_length(difference) < 2 {
      waypoint=(waypoint+1)%route.count
      difference=route[waypoint]-physics.position
    }
    let angle=atan2(-difference.x,-difference.z)-physics.heading
    let steering = -max(-1,min(1,atan2(sin(angle),cos(angle))*2))
    physics.update(deltaTime:seconds,throttle:physics.speed < 4 ? 0.25:0,
      turn:steering,brake:0,block:block,occupied:occupied)
  }
}

extension VehicleRecord {
  /// nil means migration is pending until the car's settlement is available.
  /// An explicit empty driver is parked and must never be assigned an AI route.
  public func restoredTraffic(in site: Settlement?) -> CityTrafficDriver? {
    if let traffic { return traffic }
    guard let site, site.id == siteID else { return nil }
    guard isValid, parkingBrake != true,
      let index=(0..<site.vehicleCount).first(where:{CityTrafficDriver.carID(in:site,index:$0) == id})
    else { return .parked }
    var driver=CityTrafficDriver.spawned(in:site,index:index)
    return driver.rejoin(position:.init(position[0],position[1],position[2]),heading:heading) ? driver:.parked
  }
}
