import RealityKit
import UIKit
import WorldCore

@MainActor final class BoatModelLibrary {
  private let palette=ActorModelLibrary()
  private var prepared:[BoatKind:PreparedVehicleModel]=[:]
  private var prototypes:[BoatKind:Entity]=[:]
  private var task:Task<Void,Never>?
  func model(_ kind:BoatKind)->Entity? {
    if let prototype=prototypes[kind] { return prototype.clone(recursive:true) }
    guard let geometry=prepared[kind] else {
      if task == nil {
        task=Task { [weak self] in
          let result=await BoatMeshPreparation.shared.prepare(kind)
          self?.prepared[kind]=result;self?.task=nil
        }
      }
      return nil
    }
    do {
      let root=Entity();root.scale = .init(repeating:WorldScale.blocks(1))
      let material=palette.material(BoatModel.colors)
      for (i,part) in geometry.parts.enumerated() {
        let node=ModelEntity(mesh:try TerrainMeshResource.make(geometry.meshes[i]),materials:[material])
        node.name=part.name;node.position=part.pivot;root.addChild(node)
      }
      prototypes[kind]=root;return root.clone(recursive:true)
    } catch { print("WORLDCRAFT_BOAT mesh error: \(error)");return nil }
  }
}

/// MainActor only owns RealityKit presentation and a bounded fleet. Regional
/// shoreline surveys and geometry preparation run away from the frame callback.
@MainActor final class BoatRenderer {
  private struct Boat { var record:BoatRecord;let root:Entity;var model:Entity?;var nextPresentation:Double=0 }
  private var boats:[Boat]=[]
  private var saved:[UInt64:BoatRecord]=[:]
  private let library=BoatModelLibrary()
  private var survey:Task<Void,Never>?
  private var generation=0
  private var lastSurvey=SIMD3<Float>(repeating: .infinity)
  private var nextFleetRefresh:Double=0
  private var marinas:[Marina]=[]
  private var driver:UInt64?
  private var focused:UInt64?
  private var time:Double=0
  private var lastWake:Double=0
  private var notice=""
  private var noticeUntil:Double=0
  var isSailing:Bool { driver != nil }
  var eye:SIMD3<Float>? { helmed?.physics.eye }
  var heading:Float? { helmed?.physics.heading }
  var companionCarrier:CompanionCarrier? {
    driver.flatMap { companionCarrier(for:$0) }
  }
  func companionCarrier(for id:UInt64)->CompanionCarrier? {
    guard let boat=boats.first(where:{$0.record.id==id})?.record else {return nil}
    let p=boat.physics
    return .init(id:boat.id,kind:.boat(p.kind),position:p.position,heading:p.heading,heel:p.heel,pitch:p.pitch)
  }
  var velocity:SIMD3<Float> { (helmed?.physics.velocity ?? .zero)*WorldScale.blocks(1) }
  var speed:Float { helmed?.physics.speed ?? 0 }
  var driverID:UInt64? { driver }
  private var helmed:BoatRecord? { boats.first{$0.record.id==driver}?.record }
  var hasInteraction:Bool { isSailing || focused != nil }
  var records:[BoatRecord] {
    var all=saved
    for boat in boats { var record=boat.record;record.physics.moor();all[record.id]=record }
    return Array(all.values.sorted{ a,b in
      if a.id == b.id {return false}
      if a.id == driver {return true};if b.id == driver {return false};return a.id<b.id
    }.prefix(128))
  }
  var prompt:String {
    if time<noticeUntil {return notice}
    if let boat=helmed {
      let p=boat.physics
      if p.kind.isMotorized {
        return "\(p.kind.name) · \(p.pointOfSail) · \(String(format:"%.1f",p.speed*1.94384)) kn\nStick / A D: steer · RT / W: accelerate · LT / S: reverse\nRB / Space: anchor · Y / R: leave"
      }
      let wind="Wind \(Int(p.windSpeed*1.94384)) kn · \(Int(abs(p.windAngle)*180 / .pi))° \(p.windAngle<0 ? "port":"starboard") · \(p.automaticTrim ? "Auto trim" : "Manual trim")"
      return "\(p.kind.name) · \(p.pointOfSail) · \(String(format:"%.1f",p.speed*1.94384)) kn\n\(wind)\nA / D · stick: steer · W / S · stick up/down: \(p.kind == .dinghy ? "paddle" : "harbour motor")\nA / H: sails · RB / Space: anchor · triggers / [ ]: trim · LB / T: auto · Y / R: leave"
    }
    if let boat=boats.first(where:{$0.record.id==focused}) {
      return "\(boat.record.physics.kind.name) · LT / Y / R: take the helm"
    }
    return ""
  }
  var destination:SIMD3<Float>? { marinas.first?.world([0,0,12]) }
  var marinaName:String? { marinas.first?.name }
  func restore(_ records:[BoatRecord],driver:UInt64? = nil) {
    saved=Dictionary(records.filter(\.isValid).prefix(128).map{($0.id,$0)},uniquingKeysWith:{$1})
    if let driver,var record=saved[driver] {
      record.physics.moor();self.driver=driver
      boats.append(.init(record:record,root:Entity(),model:nil))
    }
  }
  func clear() {
    generation+=1;survey?.cancel();survey=nil
    boats.forEach{$0.root.removeFromParent()};boats=[];saved=[:];marinas=[]
    driver=nil;focused=nil;lastSurvey = .init(repeating:.infinity);nextFleetRefresh=0;notice="";noticeUntil=0
  }
  func update(terrain:TerrainGenerator,root:Entity,player:SIMD3<Float>,environment:WorldEnvironment,seconds:Float) {
    time=environment.elapsed
    if survey == nil && simd_distance_squared(player,lastSurvey)>128*128 {
      lastSurvey=player;let ticket=generation
      survey=Task { [weak self] in
        let work=Task.detached(priority:.utility) {
          MarinaGenerator.sites(x:Int(player.x)-768,z:Int(player.z)-768,width:1536,terrain:terrain)
            .sorted{simd_distance_squared($0.world(.zero),player)<simd_distance_squared($1.world(.zero),player)}
        }
        let sites=await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        guard let self,self.generation==ticket,!Task.isCancelled else {return}
        self.marinas=sites;self.survey=nil;self.nextFleetRefresh=0
      }
    }
    if time>=nextFleetRefresh {
      nextFleetRefresh=time+0.10
      for i in boats.indices.reversed() where boats[i].record.id != driver && simd_distance_squared(boats[i].record.physics.position,player)>1_800*1_800 {
        remember(boats[i].record);boats[i].root.removeFromParent();boats.remove(at:i)
      }
      // Keep moved boats where the player left them, including after a reload.
      let candidates=Array(saved.values.filter{simd_distance_squared($0.physics.position,player)<1_500*1_500}.sorted{$0.id<$1.id})
        + marinas.flatMap(\.boats).map{saved[$0.id] ?? $0}
      if boats.count<24,let next=candidates.first(where:{ candidate in
        !boats.contains{$0.record.id==candidate.id} && simd_distance_squared(candidate.physics.position,player)<1_500*1_500
      }),let model=library.model(next.physics.kind) {
        let node=Entity();node.addChild(model);root.addChild(node)
        boats.append(.init(record:next,root:node,model:model))
      }
    }
    let weather=WorldWeather.sample(seed:terrain.seed,time:time,style:terrain.style)
    for i in boats.indices {
      if boats[i].root.parent == nil {root.addChild(boats[i].root)}
      if boats[i].model == nil,let model=library.model(boats[i].record.physics.kind) {
        boats[i].model=model;boats[i].root.addChild(model)
        positionModel(i)
      }
      // Nearby idle hulls bob smoothly; distant anchored craft need very few
      // transform publications. The helmed boat updates at the input cadence.
      guard boats[i].record.id != driver else {continue}
      guard time>=boats[i].nextPresentation else {continue}
      let near=simd_distance_squared(boats[i].record.physics.position,player)<240*240
      let interval:Double=near ? 1/30:1/5
      boats[i].nextPresentation=time+interval*(0.92+Double(boats[i].record.id%11)*0.016)
      if boats[i].record.id != driver {
        let p=boats[i].record.physics.position
        if let body=terrain.waterBody(atX:Int(floor(p.x)),z:Int(floor(p.z))) {
          let wind=WorldWind.sample(seed:terrain.seed,time:time,position:p,weather:weather)
          boats[i].record.physics.update(deltaTime:seconds>0 ? Float(interval):0,controls:.init(),wind:wind.velocity,current:.zero,
            water:environment.water(atX:p.x,z:p.z,body:body))
        }
      }
      positionModel(i)
    }
  }
  private func remember(_ record:BoatRecord) {
    if saved[record.id] == nil && saved.count>=128,let key=saved.keys.filter({$0 != driver}).min() {saved.removeValue(forKey:key)}
    saved[record.id]=record
  }
  func sail(seconds:Float,frame:InputFrame,terrain:TerrainGenerator,environment:inout WorldEnvironment,
    block:(BlockPosition)->Block)->Float {
    guard let i=boats.firstIndex(where:{$0.record.id==driver}) else {return 0}
    var p=boats[i].record.physics
    let oldHeading=p.heading
    if frame.boatAnchor { p.anchored.toggle() }
    if frame.boatHoist && !p.kind.isMotorized { p.sailRaised.toggle(); if p.sailRaised {p.anchored=false} }
    if frame.boatAutoTrim { p.automaticTrim=true }
    let throttle=p.kind.isMotorized ? frame.driveThrottle:frame.movement.y
    if abs(throttle)>0.05 {p.anchored=false}
    let weather=WorldWeather.sample(seed:terrain.seed,time:environment.elapsed,style:terrain.style)
    let wind=WorldWind.sample(seed:terrain.seed,time:environment.elapsed,position:p.position,weather:weather)
    let body=terrain.waterBody(atX:Int(floor(p.position.x)),z:Int(floor(p.position.z)))
    guard let body else {p.moor();boats[i].record.physics=p;return 0}
    // Reuse samples across hull corners and 120-Hz substeps. Never gate on a
    // rendered chunk: sea depth and world edits remain authoritative during flight/streaming.
    var columns:[SIMD2<Int>:TerrainColumn]=[:],blocks:[BlockPosition:Block]=[:]
    p.update(deltaTime:seconds,controls:.init(rudder:frame.driveSteering,sheet:p.kind.isMotorized ? 0:frame.boatTrim,auxiliary:throttle),
      wind:wind.velocity,current:terrain.waterCurrent(at:p.position,time:environment.elapsed)*WorldScale.metresPerBlock,
      water:environment.water(atX:p.position.x,z:p.position.z,body:body),navigable:{ [self] candidate,yaw,kind in
        guard !boats.contains(where:{$0.record.id != driver && Self.overlaps(candidate,yaw: yaw,kind:kind,other:$0.record.physics)}) else {return false}
        return SailingPhysics.isNavigable(position:candidate,heading:yaw,kind:kind,column:{ x,z in
          let key=SIMD2(x,z);if let c=columns[key] {return c}
          let c=terrain.column(atX:x,z:z);columns[key]=c;return c
        },block:{ point in
          if let cached=blocks[point] {return cached}
          let value=block(point);blocks[point]=value;return value
        })
      })
    boats[i].record.physics=p;positionModel(i)
    if p.speed>0.3 && environment.elapsed-lastWake>0.20 {
      lastWake=environment.elapsed
      for side:Float in [-1,1] {
        let stern=p.worldPoint([side*p.kind.beam*0.35,0,p.kind.length*0.4])
        environment.disturbWater(atX:stern.x,z:stern.z,body:body,energy:min(0.30,p.speed*0.045))
      }
    }
    return atan2(sin(p.heading-oldHeading),cos(p.heading-oldHeading))
  }
  private static func overlaps(_ position:SIMD3<Float>,yaw:Float,kind:BoatKind,other:SailingPhysics)->Bool {
    let axes=[SIMD3<Float>(cos(yaw),0,-sin(yaw)),SIMD3<Float>(sin(yaw),0,cos(yaw)),other.right,-other.forward]
    let a=[axes[0]*WorldScale.blocks(kind.beam/2),axes[1]*WorldScale.blocks(kind.length/2)]
    let b=[other.right*WorldScale.blocks(other.kind.beam/2),other.forward*WorldScale.blocks(other.kind.length/2)]
    return axes.allSatisfy { axis in
      abs(simd_dot(position-other.position,axis)) < a.reduce(0){$0+abs(simd_dot($1,axis))}+b.reduce(0){$0+abs(simd_dot($1,axis))}
    }
  }
  func focus(eye:SIMD3<Float>,direction:SIMD3<Float>,block:(BlockPosition)->Block) {
    guard !isSailing else {focused=nil;return}
    focused=boats.filter { boat in
      let p=boat.record.physics
      let delta=eye-p.position,localX=simd_dot(delta,p.right),localZ=simd_dot(delta,p.forward)
      let closest=p.position+p.right*max(-WorldScale.blocks(p.kind.beam/2),min(WorldScale.blocks(p.kind.beam/2),localX))
        + p.forward*max(-WorldScale.blocks(p.kind.length*0.45),min(WorldScale.blocks(p.kind.length*0.45),localZ))
        + SIMD3<Float>(0,WorldScale.blocks(p.kind.freeboard),0)
      let aim=closest-eye,distance=simd_length(aim)
      return distance<9 && p.speed<0.6 && (distance<1 || simd_dot(aim/max(0.001,distance),direction)>0.5)
        && VoxelRaycast.cast(origin:eye,direction:aim,reach:max(0,distance-1),block:block)==nil
    }.min{simd_distance_squared($0.record.physics.position,eye)<simd_distance_squared($1.record.physics.position,eye)}?.record.id
  }
  func interact(terrain:TerrainGenerator,block:(BlockPosition)->Block)->SIMD3<Float>? {
    if let i=boats.firstIndex(where:{$0.record.id==driver}) {
      let p=boats[i].record.physics
      guard let exit=p.exitPosition(block:block,water:{terrain.waterBody(atX:$0,z:$1)},occupied:{ [self] point in
        boats.contains{$0.record.id != driver && Self.contains(point,boat:$0.record.physics,radius:PlayerPhysics.radius)}
      }) else {notice="No clear exit · move away from the bank";noticeUntil=time+3;return nil}
      boats[i].record.physics.moor();remember(boats[i].record);driver=nil;focused=nil;return exit
    }
    if let focused,let i=boats.firstIndex(where:{$0.record.id==focused}) {
      driver=focused;boats[i].record.physics.moor();noticeUntil=0
    }
    return nil
  }
  private static func contains(_ point:SIMD3<Float>,boat:SailingPhysics,radius:Float)->Bool {
    let d=point-boat.position
    return abs(simd_dot(d,boat.right))<WorldScale.blocks(boat.kind.beam/2)+radius
      && abs(simd_dot(d,boat.forward))<WorldScale.blocks(boat.kind.length/2)+radius
      && d.y < WorldScale.blocks(boat.kind.freeboard)+radius && d.y > -WorldScale.blocks(boat.kind.draft)-radius
  }
  func obstructsPlayer(at point:SIMD3<Float>)->Bool {
    boats.contains{$0.record.id != driver && Self.contains(point,boat:$0.record.physics,radius:PlayerPhysics.radius)}
  }
  func obstructsCamera(_ point:SIMD3<Float>,radius:Float)->Bool {
    boats.contains{$0.record.id != driver && Self.contains(point,boat:$0.record.physics,radius:radius)}
  }
  private func positionModel(_ i:Int) {
    let b=boats[i],p=b.record.physics
    b.root.position=p.position
    b.root.orientation=simd_quatf(angle:p.heading,axis:[0,1,0]) * simd_quatf(angle:p.heel,axis:[0,0,1]) * simd_quatf(angle:p.pitch,axis:[1,0,0])
    let flutter=p.luffing ? sin(Float(time)*9+Float(b.record.id%17))*0.06:0
    for name in ["Mainsail","Jib"] {
      let node=b.model?.findEntity(named:name)
      node?.isEnabled=p.sailRaised
      node?.orientation=simd_quatf(angle:p.boomAngle*(name == "Jib" ? 0.55:1)+flutter,axis:[0,1,0])
    }
    b.model?.findEntity(named:"Rudder")?.orientation=simd_quatf(angle:-p.yawRate*0.5,axis:[0,1,0])
    b.model?.findEntity(named:"Wind pennant")?.orientation=simd_quatf(angle:-p.windAngle,axis:[0,1,0])
  }
}
