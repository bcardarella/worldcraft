import RealityKit
import UIKit
import WorldCore

@MainActor final class SportsRenderer {
  private let worker=SportsSimulation()
  private var task:Task<Void,Never>?,generation=0
  private var accumulator:Float=0,lockerClock:Float=0
  private var snapshots:[SportsSnapshot]=[]
  private struct GameVisual {var people:[Int:ActorRig]=[:];var teams:[Int:Int]=[:];let ball:ModelEntity;let board:Entity;var label=""}
  private var visuals:[UInt64:GameVisual]=[:]
  private var loose:[(ball:SportBall,node:ModelEntity,age:Float)]=[]
  private var pendingDrops:[(position:SIMD3<Float>,playerOwned:Bool)]=[]
  private var selectedLocker:StadiumLocker?
  private var openDoors:[UInt64:ModelEntity]=[:]
  private(set) var prompt=""
  private let ballMesh=MeshResource.generateSphere(radius:0.074)
  private let ballMaterial=SimpleMaterial(color:UIColor(white:0.92,alpha:1),roughness:0.85,isMetallic:false)
  func clear() {
    generation+=1;task?.cancel();task=nil;accumulator=0;snapshots=[]
    for game in visuals.values {game.people.values.forEach{$0.root.removeFromParent()};game.ball.removeFromParent();game.board.removeFromParent()}
    visuals=[:];loose.forEach{$0.node.removeFromParent()};loose=[];pendingDrops=[]
    openDoors.values.forEach{$0.removeFromParent()};openDoors=[:];selectedLocker=nil;prompt=""
  }
  func update(terrain:TerrainGenerator,player:SIMD3<Float>,root:Entity,seconds:Float,block:(BlockPosition)->Block) {
    guard seconds>0 else {return}
    accumulator=min(0.2,accumulator+seconds)
    if task==nil && accumulator>=0.1 {
      let dt=accumulator,ticket=generation;accumulator=0
      task=Task { [weak self,worker] in
        let result=await worker.update(terrain:terrain,player:player,seconds:dt)
        guard let self,!Task.isCancelled,ticket==self.generation else {return}
        self.snapshots=result
        for game in result {for position in game.souvenirs where self.pendingDrops.count<32 {self.pendingDrops.append((position,false))}}
        self.task=nil
      }
    }
    let live=Set(snapshots.map{ $0.venue.id })
    for id in Array(visuals.keys) where !live.contains(id) {
      if let old=visuals.removeValue(forKey:id) {old.people.values.forEach{$0.root.removeFromParent()};old.ball.removeFromParent();old.board.removeFromParent()}
    }
    var added=false
    for snapshot in snapshots {
      let venue=snapshot.venue
      if visuals[venue.id]==nil {
        let ball=ModelEntity(mesh:ballMesh,materials:[ballMaterial]);ball.position=snapshot.ball.position;root.addChild(ball)
        if venue.field.kind == .soccer {ball.scale = .init(repeating:0.22/0.074)}
        let board=Entity();board.position=venue.scoreboard;root.addChild(board)
        visuals[venue.id] = .init(ball:ball,board:board)
      }
      guard var game=visuals[venue.id] else {continue}
      let ids=Set(snapshot.players.map(\.id))
      for id in Array(game.people.keys) where !ids.contains(id) {game.people.removeValue(forKey:id)?.root.removeFromParent()}
      for person in snapshot.players {
        if let team=game.teams[person.id],team != person.team {game.people.removeValue(forKey:person.id)?.root.removeFromParent()}
        game.teams[person.id]=person.team
        if game.people[person.id]==nil && !added,let geometry=ActorModelLibrary.shared.geometry(for:.athlete(team:person.team,baseball:venue.field.kind == .baseball,batting:person.id==999)) {
          let rig=ActorRig(geometry,library:.shared);rig.root.position=person.position;root.addChild(rig.root);game.people[person.id]=rig;added=true
        }
        guard let rig=game.people[person.id] else {continue}
        let distance=simd_distance_squared(player,person.position)
        rig.root.isEnabled=distance<620*620
        rig.root.position += (person.position-rig.root.position)*min(1,seconds*18)
        rig.root.orientation=simd_slerp(rig.root.orientation,simd_quatf(angle:person.heading,axis:[0,1,0]),min(1,seconds*18))
        if rig.updateDetail(distanceSquared:distance) {
          for (i,joint) in [ActorJoint.limb2,.limb3].enumerated() {rig[joint].orientation=simd_quatf(angle:sin(person.gait+Float(i) * .pi)*0.5,axis:[1,0,0])}
          rig[.limb0].orientation=simd_quatf(angle:person.action>0 ? -1.4:-sin(person.gait)*0.3,axis:[1,0,0])
          rig[.limb1].orientation=simd_quatf(angle:person.action>0 ? -1.4:sin(person.gait)*0.3,axis:[1,0,0])
        }
      }
      game.ball.position += (snapshot.ball.position-game.ball.position)*min(1,seconds*25)
      if game.label != snapshot.label {
        game.label=snapshot.label;game.board.children.removeAll()
        let panel=ModelEntity(mesh:.generateBox(size:[19.8,4.8,0.1]),materials:[UnlitMaterial(color:UIColor(white:0.018,alpha:1))])
        panel.position=[0,7.5,0.09];game.board.addChild(panel)
        for sign:Float in [-1,1] {
          let text=ModelEntity(mesh:.generateText("HOME       AWAY\n"+snapshot.label,extrusionDepth:0.001,font:.monospacedSystemFont(ofSize:0.76,weight:.bold),alignment:.center),materials:[UnlitMaterial(color:UIColor(red:0.94,green:0.85,blue:0.40,alpha:1))])
          let bounds=text.visualBounds(relativeTo:text)
          text.position=[-bounds.center.x,6,-0.18*sign]
          if sign>0 {text.orientation=simd_quatf(angle:.pi,axis:[0,1,0]);text.position.x=bounds.center.x}
          game.board.addChild(text)
        }
      }
      visuals[venue.id]=game
    }
    // Loose thrown balls use bounded substeps; missed frames are never replayed.
    for i in loose.indices.reversed() {
      loose[i].age += seconds
      var p=loose[i].ball
      let n=max(1,Int(ceil(min(seconds,0.05)*120))),dt=min(seconds,0.05)/Float(n)
      for _ in 0..<n {
        p.velocity.y -= 19.62*dt
        for axis in 0..<3 {
          var candidate=p.position;candidate[axis] += p.velocity[axis]*dt
          let leading=candidate+SIMD3<Float>(axis==0 ? copysign(0.074,p.velocity[axis]):0,axis==1 ? copysign(0.074,p.velocity[axis]):0,axis==2 ? copysign(0.074,p.velocity[axis]):0)
          if block(.init(leading)).isSolid {p.velocity[axis] *= -0.32;p.velocity *= 0.84}
          else {p.position=candidate}
        }
      }
      loose[i].ball=p;loose[i].node.position=p.position
      if simd_length(p.velocity)<0.7 || loose[i].age>12 || p.position.y<Float(ChunkData.minimumY) {
        pendingDrops.append((p.position,true));loose[i].node.removeFromParent();loose.remove(at:i)
      }
    }
    lockerClock += seconds
    guard lockerClock>=0.25 else {return}
    lockerClock=0
    let nearbyLockers=snapshots.flatMap {$0.venue.lockers}.filter{simd_distance_squared(player,$0.center)<50*50}
    let lockerIDs=Set(nearbyLockers.map(\.id))
    for id in Array(openDoors.keys) where !lockerIDs.contains(id) {openDoors.removeValue(forKey:id)?.removeFromParent()}
    for locker in nearbyLockers {
      let isOpen=locker.isOpen(block:block)
      if isOpen,openDoors[locker.id]==nil,simd_distance_squared(player,locker.center)<50*50 {
        let door=ModelEntity(mesh:.generateBox(size:[0.12,3.9,1.9]),materials:[SimpleMaterial(color:UIColor(red:0.33,green:0.19,blue:0.09,alpha:1),roughness:0.8,isMetallic:false)])
        door.position=locker.center+locker.front*0.9-SIMD3<Float>(Float(locker.across.x),0,Float(locker.across.z))*0.95
        if locker.across.z != 0 {door.orientation=simd_quatf(angle:.pi/2,axis:[0,1,0])}
        root.addChild(door);openDoors[locker.id]=door
      } else if !isOpen {openDoors.removeValue(forKey:locker.id)?.removeFromParent()}
    }
  }
  func focus(eye:SIMD3<Float>,direction:SIMD3<Float>,block:(BlockPosition)->Block) {
    selectedLocker=snapshots.flatMap{$0.venue.lockers}.filter {
      let d=$0.center-eye,len=simd_length(d)
      return len<6 && len>0.01 && simd_dot(d/len,direction)>0.92 && VoxelRaycast.cast(origin:eye,direction:d,reach:max(0,len-1),block:block)==nil
    }.min {simd_distance_squared($0.center,eye)<simd_distance_squared($1.center,eye)}
    prompt=selectedLocker.map {"Locker · LT / R: \($0.isOpen(block:block) ? "close":"open")"} ?? ""
  }
  func lockerChanges(player:PlayerPhysics,block:(BlockPosition)->Block)->[BlockPosition:Block]? {
    guard let locker=selectedLocker else {return nil}
    let open=locker.isOpen(block:block)
    if open && locker.panels.contains(where:{player.overlaps($0)}) {return [:]}
    return Dictionary(uniqueKeysWithValues:locker.panels.map {($0,open ? .wood:.air)})
  }
  func throwBall(origin:SIMD3<Float>,velocity:SIMD3<Float>,root:Entity)->Bool {
    guard loose.count<8,pendingDrops.filter({$0.playerOwned}).count<24 else {return false}
    let node=ModelEntity(mesh:ballMesh,materials:[ballMaterial]);node.position=origin;root.addChild(node)
    loose.append((.init(position:origin,velocity:velocity),node,0));return true
  }
  func publishDrops(to pickups:ItemDropRenderer) {
    while let drop=pendingDrops.first,pickups.freeSlots>0 {
      guard pickups.add(.init(.baseball),at:drop.position,delay:0.5) else {break}
      pendingDrops.removeFirst()
    }

  }
}
