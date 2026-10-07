import Foundation
import simd

public struct BuildingDoor: Sendable {
  public let id: UInt64
  public let origin: SIMD3<Float>
  public let minimum, maximum: SIMD2<Float>
  public let style: ArchitectureStyle
  public let home: Bool
  public static let width: Float = 2
  public static let height: Float = 4
  public var center: SIMD3<Float> { origin+[Self.width/2,Self.height/2,0] }
  public func contains(_ point: SIMD3<Float>) -> Bool {
    point.x > minimum.x && point.x < maximum.x && point.z > minimum.y && point.z < maximum.y
      && point.y >= origin.y-0.2 && point.y < origin.y+7
  }
  public func approach(inside: Bool) -> SIMD3<Float> { origin+[Self.width/2,0,inside ? 1.6:-1.6] }
  public func exit(inside: Bool) -> SIMD3<Float> { origin+[Self.width/2,0,inside ? -3.2:3.2] }
  public func obstructs(_ feet: SIMD3<Float>, fraction: Float) -> Bool {
    let local=simd_quatf(angle:-fraction * .pi/2,axis:[0,1,0]).act(feet-origin)
    return RocketBox([Self.width-0.08,Self.height-0.10,0.12],[Self.width/2,Self.height/2,0]).overlaps(feet:local)
  }
}
public struct BuildingDoorState: Sendable {
  public let door: BuildingDoor
  public let fraction: Float
  public init(door: BuildingDoor, fraction: Float) { self.door=door; self.fraction=fraction }
  public var passable: Bool { fraction > 0.9 }
  public func blocks(_ point: BlockPosition) -> Bool {
    !passable && point.y >= Int(door.origin.y) && point.y < Int(door.origin.y)+4
      && point.x >= Int(door.origin.x) && point.x < Int(door.origin.x)+2
      && point.z == Int(floor(door.origin.z))
  }
}
extension Settlement {
  public func door(lotX:Int,lotZ:Int,terrain:TerrainGenerator) -> BuildingDoor? {
    guard let building=building(lotX:lotX,lotZ:lotZ,terrain:terrain),!building.aquatic else { return nil }
    let bx=x+lotX*spacing, bz=z+lotZ*spacing, middle=(building.minimum+building.maximum)/2
    return .init(id:building.hash ^ 0x444f4f52,origin:[Float(bx+middle),Float(floor+1),Float(bz+building.minimum)+0.5],
      minimum:[Float(bx+building.minimum),Float(bz+building.minimum)],
      maximum:[Float(bx+building.maximum),Float(bz+building.maximum)],style:building.style,home:building.use == .home)
  }
}

/// The dog's short-lived physical plan stays on SimulationActor with its other
/// needs. A closed door stops her on either side until a person opens it.
public struct DogDoorVisit: Sendable {
  private var selected: UInt64?
  private var arrived: Double?
  private var approachedAt: Double?
  private var nextVisit: Double = 0
  public private(set) var scratching: UInt64?
  public init() {}
  public mutating func directive(position:SIMD3<Float>,player:SIMD3<Float>,time:Double,
    shelter:Bool,offeredFood:Bool,doors:[BuildingDoorState],id:UInt64
  ) -> AnimalDecisionOption? {
    scratching=nil
    if let room=doors.first(where: { $0.door.contains(position) }) {
      if selected != room.door.id || arrived == nil { selected=room.door.id; arrived=time; approachedAt=nil }
      let stay=shelter && !offeredFood
      let leaving = !stay && (offeredFood || time-(arrived ?? time)>12+Double(id%19))
      if !leaving {
        return .init(shelter ? .shelter:.sniff,at:.init(room.door.origin+[1,0,4]),description:"Boomer is enjoying a safe room")
      }
      let target=room.passable ? room.door.exit(inside:true):room.door.approach(inside:true)
      if !room.passable && simd_distance_squared(position,target)<1.2*1.2 { scratching=room.door.id }
      return .init(.shelter,at:.init(target),description:"Boomer scratches to be let outside")
    }
    if arrived != nil { selected=nil; arrived=nil; approachedAt=nil; nextVisit=time+65+Double(id%40) }
    if offeredFood { return nil }
    if let started=approachedAt,time-started>30 {
      selected=nil; approachedAt=nil; nextVisit=time+40; return nil
    }
    guard shelter || time >= nextVisit || doors.contains(where: { $0.door.contains(player) }), !doors.isEmpty else { return nil }
    let eligible=doors.filter { simd_distance_squared($0.door.origin,position)<40*40 }
    guard let door=eligible.first(where:{$0.door.id == selected}) ?? eligible.min(by:{
      simd_distance_squared($0.door.origin,position) < simd_distance_squared($1.door.origin,position)
    }) else { return nil }
    if selected != door.door.id || approachedAt == nil { approachedAt=time }
    selected=door.door.id
    let target=door.passable ? door.door.exit(inside:false):door.door.approach(inside:false)
    if !door.passable && simd_distance_squared(position,target)<1.2*1.2 { scratching=door.door.id }
    return .init(.shelter,at:.init(target),description:shelter ? "Boomer asks to come in out of the weather":"Boomer smells something interesting indoors")
  }
}
