import RealityKit
import UIKit
import WorldCore

@MainActor final class DoorRenderer {
  private struct Door {
    let descriptor: BuildingDoor
    let hinge: Entity
    var fraction: Float = 0
    var wanted = false
    var closeAfter: Double = 0
  }
  private var doors: [UInt64:Door] = [:]
  private var lastSurvey = -Double.infinity
  private var focused: UInt64?
  private var closedCells = Set<BlockPosition>()
  private(set) var prompt = ""
  private(set) var sounds: [(String,SIMD3<Float>)] = []
  private var lastScratch = -Double.infinity
  var snapshots: [BuildingDoorState] { doors.values.map { .init(door:$0.descriptor,fraction:$0.fraction) } }
  func block(_ p:BlockPosition) -> Block? { closedCells.contains(p) ? .wood:nil }
  func obstructs(_ feet:SIMD3<Float>) -> Bool { doors.values.contains { simd_distance_squared($0.descriptor.origin,feet)<36 && $0.descriptor.obstructs(feet,fraction:$0.fraction) } }
  func clear() { doors.values.forEach { $0.hinge.removeFromParent() }; doors=[:]; closedCells=[]; focused=nil; prompt=""; lastSurvey = -.infinity }
  func update(site:Settlement?,terrain:TerrainGenerator,root:Entity,player:SIMD3<Float>,people:[SIMD3<Float>],
    animals:[AnimalState],time:Double,seconds:Float,block:(BlockPosition)->Block) {
    sounds.removeAll(keepingCapacity:true)
    if time-lastSurvey > 0.5 {
      lastSurvey=time
      var found: [UInt64:BuildingDoor]=[:]
      if let site {
        let lx=floorDivide(Int(floor(player.x))-site.x,by:site.spacing),lz=floorDivide(Int(floor(player.z))-site.z,by:site.spacing)
        for x in lx-2...lx+2 { for z in lz-2...lz+2 {
          guard let descriptor=site.door(lotX:x,lotZ:z,terrain:terrain),simd_distance_squared(descriptor.origin,player)<128*128,
            block(.init(descriptor.origin+[0,-1,0])).isSolid,
            block(.init(descriptor.origin+[0,4,0])).isSolid else { continue }
          found[descriptor.id]=descriptor
        } }
      }
      let newDoors=found.values.filter { doors[$0.id] == nil }.sorted {
        simd_distance_squared($0.origin,player)<simd_distance_squared($1.origin,player)
      }.prefix(2)
      for descriptor in newDoors {
        let hinge=make(descriptor); root.addChild(hinge)
        doors[descriptor.id] = .init(descriptor:descriptor,hinge:hinge)
      }
      for id in Array(doors.keys) where found[id] == nil { doors.removeValue(forKey:id)?.hinge.removeFromParent() }
    }
    guard seconds>0 else { return }
    let occupants=[player]+people+animals.map(\.position)
    closedCells.removeAll(keepingCapacity:true)
    for id in Array(doors.keys) {
      guard var door=doors[id] else { continue }
      let center=door.descriptor.origin+[1,0,0]
      let visitors=people.contains { simd_distance_squared($0,center)<3.6*3.6 }
      let scratching=animals.first { $0.doorVisit.scratching == id }
      // Nearby villagers answer Boomer as well as opening doors on their route.
      let answering=scratching != nil && people.contains { simd_distance_squared($0,center)<9*9 }
      if visitors || answering { door.wanted=true; door.closeAfter=time+5 }
      if scratching != nil && time-lastScratch>1.2 {
        lastScratch=time; sounds.append(("door_scratch",center+[0,0.8,0]))
      }
      let clear = !occupants.contains { simd_distance_squared($0,center)<3*3 }
      if time>door.closeAfter && clear { door.wanted=false }
      let old=door.fraction
      let next = door.wanted ? min(1,old+seconds*3):max(0,old-seconds*2.5)
      // Hold the leaf if closing would touch a person or a pet.
      if next >= old || !occupants.contains(where: { door.descriptor.obstructs($0,fraction:next) }) {
        door.fraction=next
      }
      if door.fraction != old {
        door.hinge.orientation=simd_quatf(angle:door.fraction * .pi/2,axis:[0,1,0])
        if old == 0 || old == 1 { sounds.append(("building_door",center+[0,2,0])) }
      }
      doors[id]=door
      if door.fraction <= 0.9 {
        let o=BlockPosition(door.descriptor.origin)
        for x in 0..<2 { for y in 0..<4 { closedCells.insert(o + .init(x,y,0)) } }
      }
    }
  }
  func focus(eye:SIMD3<Float>,direction:SIMD3<Float>,block:(BlockPosition)->Block) {
    focused=doors.values.filter {
      let d=$0.descriptor.center-eye, distance=simd_length(d)
      return distance>0.01 && distance<7 && simd_dot(d/distance,direction)>0.89
        && VoxelRaycast.cast(origin:eye,direction:d,reach:max(0,distance-0.5),block:block)==nil
    }.min { simd_distance_squared($0.descriptor.center,eye)<simd_distance_squared($1.descriptor.center,eye) }?.descriptor.id
    prompt=focused.flatMap { doors[$0] }.map { "R / LT · \($0.wanted ? "Close":"Open") door" } ?? ""
  }
  func interact(time:Double) -> Bool {
    guard let focused,var door=doors[focused] else { return false }
    door.wanted.toggle(); door.closeAfter=door.wanted ? time+8:time
    doors[focused]=door; return true
  }
  private func make(_ door:BuildingDoor) -> Entity {
    let root=Entity(); root.position=door.origin
    let solar=[ArchitectureStyle.forge,.citadel,.furnace,.sunSpire,.caldera].contains(door.style)
    let modern=door.style == .modern || door.style == .artDeco
    var glass=PhysicallyBasedMaterial(); glass.baseColor = .init(tint:.init(red:0.45,green:0.70,blue:0.75,alpha:1))
    glass.blending = .transparent(opacity:.init(floatLiteral:0.25)); glass.roughness = .init(floatLiteral:0.12)
    let materials: [any Material] = [SimpleMaterial(color:solar ? .darkGray:modern ? .gray:.init(red:0.36,green:0.20,blue:0.10,alpha:1),roughness:0.6,isMetallic:solar || modern),
      SimpleMaterial(color:.init(red:0.79,green:0.62,blue:0.29,alpha:1),roughness:0.24,isMetallic:true),glass]
    let b=SculptureBuilder(materials:materials)
    b.box([1.9,3.86,0.10],[1,2,0],0,parent:root)
    for x:Float in [0.13,1.87] { b.box([0.07,3.80,0.16],[x,2,0],0,parent:root) }
    for y:Float in [0.17,1.9,3.83] { b.box([1.76,0.08,0.16],[1,y,0],0,parent:root) }
    for z:Float in [-0.08,0.08] {
      b.box([0.11,0.34,0.06],[1.66,1.82,z],1,parent:root)
      if modern { b.box([1.46,1.50,0.02],[1,2.80,z],2,parent:root) }
      else { for x:Float in [0.53,1.37] { b.box([0.62,1.48,0.028],[x,2.84,z],0,parent:root); b.box([0.62,1.37,0.028],[x,0.97,z],0,parent:root) } }
    }
    b.finish(); return root
  }
}
