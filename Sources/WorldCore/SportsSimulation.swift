import Foundation
import simd

public struct SportsVenue:Sendable {
  public let id:UInt64,field:SportsGround,floor:Float
  public init(id:UInt64,field:SportsGround,floor:Float) {self.id=id;self.field=field;self.floor=floor}
  public var scoreboard:SIMD3<Float> {
    if field.kind == .soccer {return [field.center.x,floor,field.center.y-field.pitchHalfSize.y-10]}
    let d=field.outfieldRadius(u:1,v:1)/sqrt(2)+12
    return [field.homePlate.x+d,floor,field.homePlate.y-d]
  }
  public var lockers:[StadiumLocker] {
    guard field.stadium != nil else {return []}
    var result:[StadiumLocker]=[]
    let homeX=Int(floorf(field.homePlate.x)),homeZ=Int(floorf(field.homePlate.y))
    for side in [false,true] {
      func add(along:Int,depth:Int,depthwise:Bool,frontSign:Float) {
        let origin=BlockPosition(homeX+(side ? -depth:along),Int(floor)-11,homeZ+(side ? -along:depth))
        let across:BlockPosition=depthwise ? (side ? .init(-1,0,0):.init(0,0,1)):(side ? .init(0,0,-1):.init(1,0,0))
        let front:SIMD3<Float>=depthwise ? (side ? [0,0,-frontSign]:[frontSign,0,0]):(side ? [1,0,0]:[0,0,-1])
        result.append(.init(id:id &+ UInt64(result.count+1),origin:origin,across:across,front:front))
      }
      for along in stride(from:31,through:79,by:3) {add(along:along,depth:63,depthwise:false,frontSign:1)}
      for depth in stride(from:40,through:61,by:3) {
        add(along:30,depth:depth,depthwise:true,frontSign:1)
        add(along:82,depth:depth,depthwise:true,frontSign:-1)
      }
    }
    return result
  }
}
public struct StadiumLocker:Sendable {
  public let id:UInt64,origin:BlockPosition,across:BlockPosition,front:SIMD3<Float>
  public var center:SIMD3<Float> {origin.center+SIMD3(Float(across.x)*0.5,1.4,Float(across.z)*0.5)+front*0.55}
  public var panels:[BlockPosition] {(0..<4).flatMap {y in [origin + .init(0,y,0),origin+across + .init(0,y,0)]}}
  public func isOpen(block:(BlockPosition)->Block)->Bool {panels.allSatisfy{!block($0).isSolid}}
}
public struct SportsSnapshot:Sendable {
  public let venue:SportsVenue,players:[SportPlayer],ball:SportBall,label:String,souvenirs:[SIMD3<Float>]
}
/// Bounded simulation and venue discovery. No RealityKit objects and no await
/// of AI/network work; the renderer consumes the latest completed snapshots.
public actor SportsSimulation {
  private struct Game:Sendable {let venue:SportsVenue;var baseball:BaseballMatch?;var soccer:SoccerMatch?}
  private var games:[UInt64:Game]=[:],order:[UInt64]=[],selected:[SportsVenue]=[]
  private var lastSurvey=SIMD3<Float>(repeating:.infinity),lastSeed:UInt64?
  public init() {}
  public func update(terrain:TerrainGenerator,player:SIMD3<Float>,seconds:Float)->[SportsSnapshot] {
    if terrain.seed != lastSeed {games=[:];order=[];selected=[];lastSurvey = .init(repeating:.infinity);lastSeed=terrain.seed}
    if simd_distance_squared(lastSurvey,player)>64*64 {
      lastSurvey=player
      let region=SettlementGenerator.regionSize,rx=floorDivide(Int(player.x),by:region),rz=floorDivide(Int(player.z),by:region)
      var venues:[SportsVenue]=[]
      for x in (rx-1)...(rx+1) {for z in (rz-1)...(rz+1) {
        guard let site=SettlementGenerator.site(in:.init(x,z),terrain:terrain),site.habitat == .surface else {continue}
        for (index,field) in site.sportsGrounds.enumerated() {
          let near=SIMD2<Float>(max(Float(field.x0),min(Float(field.x1),player.x)),max(Float(field.z0),min(Float(field.z1),player.z)))
          if simd_distance_squared(near,[player.x,player.z])<360*360 {venues.append(.init(id:site.id ^ UInt64(index+1),field:field,floor:Float(site.floor)))}
        }
      }}
      selected=Array(venues.sorted {simd_distance_squared($0.field.center,[player.x,player.z])<simd_distance_squared($1.field.center,[player.x,player.z])}.prefix(2))
    }
    return selected.map { venue in
      var game=games[venue.id] ?? Game(venue:venue,
        baseball:venue.field.kind == .baseball ? .init(field:venue.field,floor:venue.floor,seed:venue.id):nil,
        soccer:venue.field.kind == .soccer ? .init(field:venue.field,floor:venue.floor,seed:venue.id):nil)
      game.baseball?.advance(seconds:seconds);game.soccer?.advance(seconds:seconds)
      let snapshot=SportsSnapshot(venue:venue,players:game.baseball?.actors ?? game.soccer?.players ?? [],
        ball:game.baseball?.ball ?? game.soccer!.ball,label:game.baseball?.label ?? game.soccer!.label,souvenirs:game.baseball?.takeSouvenirs() ?? [])
      if games[venue.id]==nil {order.append(venue.id)}
      games[venue.id]=game
      while order.count>8 {let old=order.removeFirst();games.removeValue(forKey:old)}
      return snapshot
    }
  }
}
