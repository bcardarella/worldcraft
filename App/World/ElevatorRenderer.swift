import RealityKit
import UIKit
import WorldCore

@MainActor final class ElevatorRenderer {
  enum Control { case call(Int), previous, next, go }
  private let root=Entity(), cabin=Entity(), screen=Entity()
  private var doors: [(Int,Entity)] = []
  private var motion: ElevatorMotion?
  private var selected=0
  private var lastSurvey = -Double.infinity
  private var lastLabel=""
  private var passenger: SIMD3<Float>?
  private var focused: Control?
  private(set) var prompt=""
  var riding: Bool { passenger != nil }
  var safeSavePosition: SIMD3<Float>? {
    guard riding,let motion else { return nil }
    return [motion.shaft.origin.x,motion.shaft.height(of:motion.floor),motion.shaft.origin.z-4.5]
  }
  func clear() {
    root.removeFromParent(); root.children.removeAll(); cabin.children.removeAll(); screen.children.removeAll()
    doors=[]; motion=nil; passenger=nil; focused=nil; prompt=""; lastLabel=""; lastSurvey = -.infinity
  }
  func contains(_ feet: SIMD3<Float>) -> Bool { motion.map { $0.shaft.contains(feet,at:$0.height) } ?? false }
  func obstructsCamera(_ point: SIMD3<Float>, radius: Float) -> Bool {
    guard let motion else { return false }
    let center = motion.shaft.origin
    if RocketBox([5,0.2,5], [center.x,motion.height-0.1,center.z]).overlaps(center: point, radius: radius) { return true }
    for floor in 0..<motion.shaft.floors {
      if floor == motion.floor && motion.doorOpen > 0.98 && !motion.travelling { continue }
      if RocketBox([3.2,5.5,0.18], [center.x,motion.shaft.height(of:floor)+2.75,center.z-3])
        .overlaps(center: point, radius: radius) { return true }
    }
    return false
  }
  func obstructs(_ feet: SIMD3<Float>) -> Bool {
    guard let motion else { return false }
    let center=motion.shaft.origin
    if RocketBox([5,0.2,5],[center.x,motion.height-0.1,center.z]).overlaps(feet:feet) { return true }
    for floor in 0..<motion.shaft.floors {
      if floor == motion.floor && motion.doorOpen>0.98 && !motion.travelling { continue }
      if RocketBox([3.2,5.5,0.18],[center.x,motion.shaft.height(of:floor)+2.75,center.z-3]).overlaps(feet:feet) { return true }
    }
    return false
  }
  func survey(site: Settlement?, terrain: TerrainGenerator, player: SIMD3<Float>, time: Double, worldRoot: Entity) {
    if root.parent == nil { worldRoot.addChild(root) }
    guard !riding,time-lastSurvey>0.5 else { return }; lastSurvey=time
    guard let site, site.habitat != .aquatic else { if motion != nil { clear() }; return }
    let lx=floorDivide(Int(floor(player.x))-site.x,by:site.spacing)
    let lz=floorDivide(Int(floor(player.z))-site.z,by:site.spacing)
    var best: ElevatorShaft?, distance=Float(64*64)
    for dz in -1...1 { for dx in -1...1 {
      guard let candidate=site.elevator(lotX:lx+dx,lotZ:lz+dz,terrain:terrain) else { continue }
      let d=SIMD2(candidate.origin.x-player.x,candidate.origin.z-player.z)
      if simd_length_squared(d)<distance { distance=simd_length_squared(d); best=candidate }
    } }
    guard best?.id != motion?.shaft.id else { return }
    clear(); worldRoot.addChild(root)
    if let shaft=best { motion = .init(shaft:shaft,floor:shaft.nearestFloor(to:player.y)); selected=motion!.floor; build() }
  }
  func focus(eye: SIMD3<Float>, direction: SIMD3<Float>, feet: SIMD3<Float>, block:(BlockPosition)->Block) {
    focused=nil; prompt=""
    guard let motion,!motion.travelling else {
      if riding { prompt="Elevator · Travelling to floor \(selected+1)" }; return
    }
    let center=motion.shaft.origin
    var candidates: [(Control,SIMD3<Float>)] = []
    if contains(feet) {
      candidates=[(.previous,[center.x-1.0,motion.height+2.4,center.z+2.2]),
        (.next,[center.x+1.0,motion.height+2.4,center.z+2.2]),(.go,[center.x,motion.height+1.6,center.z+2.2])]
      prompt="Elevator · Floor \(selected+1) of \(motion.shaft.floors) · D-pad / , . to choose · R / LT to go"
    } else {
      let floor=motion.shaft.nearestFloor(to:feet.y)
      candidates=[(.call(floor),[center.x+2,motion.shaft.height(of:floor)+3,center.z-3.6])]
    }
    var best: Float=0.92
    for (control,point) in candidates {
      let d=point-eye, distance=simd_length(d)
      guard distance>0.01,distance<8,simd_dot(d/distance,direction)>best,
        VoxelRaycast.cast(origin:eye,direction:d,reach:max(0,distance-0.6),block:block)==nil else { continue }
      best=simd_dot(d/distance,direction); focused=control
    }
    switch focused {
    case .call: prompt="R / LT · Call elevator"
    case .previous: prompt="R / LT · Select lower floor"
    case .next: prompt="R / LT · Select higher floor"
    default: break
    }
  }
  func choose(_ delta: Int) {
    guard let motion,!motion.travelling else { return }
    selected=max(0,min(motion.shaft.floors-1,selected+delta)); label()
  }
  @discardableResult func interact(player: SIMD3<Float>) -> Bool {
    guard var motion,!motion.travelling else { return riding }
    switch focused {
    case .call(let floor): selected=floor; motion.request(floor)
    case .previous: choose(-1); return true
    case .next: choose(1); return true
    case .go, nil:
      guard contains(player) else { return false }
      motion.request(selected)
      if motion.travelling { passenger=player-[motion.shaft.origin.x,motion.height,motion.shaft.origin.z] }
    }
    self.motion=motion; label(); return true
  }
  func advance(seconds: Float, player: SIMD3<Float>, block:(BlockPosition)->Block) -> SIMD3<Float>? {
    guard var motion else { return nil }
    // The door waits for a body in its aperture. A rider is already safely inside.
    let doorway=RocketBox([3.4,5.5,0.6],[motion.shaft.origin.x,motion.height+2.75,motion.shaft.origin.z-3])
    motion.advance(seconds:seconds,obstructed:passenger == nil && doorway.overlaps(feet:player))
    if let offset=passenger {
      let proposed=SIMD3<Float>(motion.shaft.origin.x,motion.height,motion.shaft.origin.z)+offset
      if PlayerPhysics(position:proposed).collides(at:proposed,block:block) {
        // Player construction in a shaft is never overwritten or clipped through.
        // Return to a clear landing if a world edit obstructs an occupied car.
        // Do not strand the player midway through a shaft with controls locked.
        for floor in [motion.floor,motion.target] {
          let landing=SIMD3<Float>(motion.shaft.origin.x,motion.shaft.height(of:floor),motion.shaft.origin.z-4.5)
          if VehiclePhysics.safeFooting(at:landing,block:block) {
            self.motion = .init(shaft:motion.shaft,floor:floor); passenger=nil
            prompt="Elevator obstructed · Returned to landing"
            return landing
          }
        }
        prompt="Elevator obstructed"
        return player
      }
    }
    self.motion=motion
    cabin.position=[motion.shaft.origin.x,motion.height,motion.shaft.origin.z]
    for (floor,door) in doors { door.position.x=motion.shaft.origin.x+(floor == motion.floor ? motion.doorOpen*3.4:0) }
    label()
    guard let offset=passenger else { return nil }
    let point=SIMD3<Float>(motion.shaft.origin.x,motion.height,motion.shaft.origin.z)+offset
    if !motion.travelling && motion.doorOpen>0.98 { passenger=nil }
    return point
  }
  private func label() {
    guard let motion else { return }
    let text="FLOOR \(selected+1) / \(motion.shaft.floors)"
    guard text != lastLabel else { return }; lastLabel=text; screen.children.removeAll()
    addText(text,at:[0,3.4,2.25],width:3,parent:screen)
  }
  private func addText(_ text:String,at point:SIMD3<Float>,width:Float,parent:Entity) {
    let mesh=MeshResource.generateText(text,extrusionDepth:0.002,font:.monospacedSystemFont(ofSize:1,weight:.bold))
    let model=ModelEntity(mesh:mesh,materials:[UnlitMaterial(color:.init(red:0.6,green:1,blue:0.8,alpha:1))])
    let scale=min(width/max(mesh.bounds.extents.x,0.001),0.32/max(mesh.bounds.extents.y,0.001))
    model.scale = .init(repeating:scale)
    model.orientation=simd_quatf(angle:.pi,axis:[0,1,0])
    model.position=point+[mesh.bounds.center.x*scale,-mesh.bounds.center.y*scale,0]
    parent.addChild(model)
  }
  private func build() {
    guard let motion else { return }
    let metal=SimpleMaterial(color:.init(white:0.34,alpha:1),roughness:0.3,isMetallic:true)
    let warm=UnlitMaterial(color:.init(red:1,green:0.87,blue:0.65,alpha:1))
    let dark=SimpleMaterial(color:.init(white:0.07,alpha:1),isMetallic:false)
    let builder=SculptureBuilder(materials:[metal,warm,dark])
    root.addChild(cabin); cabin.addChild(screen)
    cabin.position=[motion.shaft.origin.x,motion.height,motion.shaft.origin.z]
    builder.box([5,0.2,5],[0,-0.1,0],0,parent:cabin)
    builder.box([5,0.12,5],[0,5.5,0],0,parent:cabin)
    builder.box([3,0.03,3],[0,5.4,0],1,parent:cabin)
    builder.box([3.8,2.5,0.12],[0,2.8,2.4],2,parent:cabin)
    for (text,p) in [("-",SIMD3<Float>(-1,2.4,2.25)),("+",[1,2.4,2.25]),("GO",[0,1.6,2.25])] {
      builder.box([0.85,0.55,0.14],p+[0,0,0.05],0,parent:cabin)
      addText(text,at:p-[0,0,0.04],width:0.7,parent:cabin)
    }
    for floor in 0..<motion.shaft.floors {
      let door=Entity(); root.addChild(door)
      door.position=[motion.shaft.origin.x+(floor == motion.floor ? 3.4:0),motion.shaft.height(of:floor)+2.75,motion.shaft.origin.z-3]
      builder.box([3.2,5.5,0.15],.zero,0,parent:door); doors.append((floor,door))
      let p=SIMD3<Float>(motion.shaft.origin.x+2,motion.shaft.height(of:floor)+3,motion.shaft.origin.z-3.6)
      builder.box([0.6,0.75,0.1],p,2,parent:root)
      addText("↕",at:p-[0,0,0.06],width:0.45,parent:root)
    }
    builder.finish(); label()
  }
}
