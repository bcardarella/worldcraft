import RealityKit
import UIKit
import WorldCore

@MainActor final class DinosaurRenderer {
  @MainActor private struct Dinosaur {
    var state: RexState
    let rig: ActorRig
    let headRest: SIMD3<Float>
    var gait: Float = 0
    var root: Entity { rig.root }
  }
  @MainActor private struct Giant {
    var state: ColossalRexState
    let rig: ActorRig
    let scale: Float
    var root: Entity { rig.root }
  }
  private var families: [ChunkCoordinate: [Dinosaur]] = [:]
  var riddenID: UInt64?
  var mounts: [MountCandidate] {
    var result:[MountCandidate] = families.values.flatMap { $0 }.compactMap { dinosaur in
      let state=dinosaur.state
      guard let profile=MountProfile.dinosaur(state.kind,baby:state.baby,scale:state.scale) else { return nil }
      return .init(id:state.id,name:state.kind.name,position:state.position,heading:state.heading,profile:profile)
    }
    if let giant {
      result.append(.init(id:giant.state.site.id,name:"Colossal T-rex",position:giant.state.position,
        heading:giant.state.heading,profile:.colossal(heightMetres:giant.state.site.heightMetres)))
    }
    return result
  }
  func applyRider(_ ride: MountedRide, seconds: Float) {
    if population.giant?.state.site.id == ride.id { population.giant?.state.applyRider(ride,seconds:seconds) }
    if giant?.state.site.id == ride.id {
      giant?.state.applyRider(ride,seconds:seconds)
      giant?.root.position=ride.position
      giant?.root.orientation=simd_quatf(angle:ride.heading,axis:[0,1,0])
    }
    for key in Array(population.families.keys) {
      if let i=population.families[key]?.firstIndex(where:{$0.id == ride.id}) { population.families[key]![i].applyRider(ride,seconds:seconds) }
    }
    for key in Array(families.keys) {
      if let i=families[key]?.firstIndex(where:{$0.state.id == ride.id}) {
        families[key]![i].state.applyRider(ride,seconds:seconds)
        families[key]![i].root.position=ride.position
        families[key]![i].root.orientation=simd_quatf(angle:ride.heading,axis:[0,1,0])
      }
    }
  }
  private var giant: Giant?
  private var population = DinosaurPopulation()
  private var eggEntities: [UInt64: Entity] = [:]
  private var eggModels: [Int: Entity] = [:]
  private var hatchEffects: [(Entity, Double)] = []
  private var pendingHatches: [SIMD3<Float>] = []
  private(set) var hatches: [SIMD3<Float>] = []
  private var lastEggUpdate = -Double.infinity
  private var pendingBites: [(SIMD3<Float>, String)] = []
  var simulationStates: DinosaurPopulation { population }
  func applySimulation(_ states: DinosaurPopulation, bites: [(SIMD3<Float>, String)]) {
    var states = states
    if let riddenID,let current=population.giant,current.state.site.id == riddenID,
      states.giant?.state.site.id == riddenID { states.giant?.state=current.state }
    if let riddenID, let rider = population.families.values.flatMap({ $0 }).first(where: { $0.id == riddenID }) {
      for key in Array(states.families.keys) {
        if let index = states.families[key]?.firstIndex(where: { $0.id == riddenID }) { states.families[key]![index] = rider }
      }
    }
    let newborns = Set(states.families.values.flatMap { $0 }.filter(\.baby).map(\.id))
    for egg in population.eggs where newborns.contains(egg.id) { pendingHatches.append(egg.position) }
    population = states
    pendingBites += bites
    for key in Array(families.keys) {
      let incoming = Dictionary(uniqueKeysWithValues: (states.families[key] ?? []).map { ($0.id, $0) })
      families[key]?.removeAll { dinosaur in
        if incoming[dinosaur.state.id] == nil { dinosaur.root.removeFromParent(); return true }
        return false
      }
      if var family = families[key] {
        for i in family.indices { if let state = incoming[family[i].state.id] { family[i].state = state } }
        families[key] = family
      }
    }
    if let state = states.giant?.state, giant?.state.site.id == state.site.id { giant?.state = state }
    else { giant?.root.removeFromParent(); giant = nil }
  }
  private(set) var bites: [SIMD3<Float>] = []
  private(set) var biteName = "Dinosaur"
  private(set) var encounterMessage = ""
  weak var life: FaunaLife?
  var snapshots: [FaunaSnapshot] { population.snapshots }
  var count: Int { families.values.reduce(0) { $0 + $1.count } + (giant == nil ? 0 : 1) }
  /// Only carnivores alarm residents; a grazing herbivore is not a T-rex threat.
  var threatPositions: [SIMD3<Float>] {
    families.values.flatMap { $0 }.filter { !$0.state.baby && $0.state.kind.carnivore }.map { $0.state.position }
      + (giant.map { [$0.state.position] } ?? [])
  }
  var calls: [(name: String, position: SIMD3<Float>, range: Float, level: Float)] {
    var result: [(name: String, position: SIMD3<Float>, range: Float, level: Float)] = []
    for dinosaur in families.values.flatMap({ $0 }) where !dinosaur.state.baby {
      let kind = dinosaur.state.kind
      let name = kind == .trex ? "rex_roar" : kind == .velociraptor ? "raptor_call" : kind.rawValue
      let position = dinosaur.root.position + SIMD3<Float>(0, WorldScale.blocks(dinosaur.rig[.head].position.y), 0)
      result.append((name, position, 44, 0))
    }
    if let giant {
      result.insert(("colossal_roar", giant.root.position + [0, WorldScale.blocks(giant.state.site.heightMetres * 0.68), 0], 640, 10), at: 0)
    }
    return result
  }
  func removePrey(id: UInt64) -> Bool {
    let existed = contains(id: id)
    for key in Array(population.families.keys) { population.families[key]?.removeAll { $0.id == id } }
    for key in Array(families.keys) {
      if let i = families[key]?.firstIndex(where: { $0.state.id == id }) {
        families[key]!.remove(at: i).root.removeFromParent()
        return true
      }
    }
    return existed
  }
  func contains(id: UInt64) -> Bool {
    population.giant?.state.site.id == id || population.families.values.contains { $0.contains { $0.id == id } }
  }
  func configure() throws { clear() }

  func update(deltaTime: Float, time: Double, player: SIMD3<Float>, terrain: TerrainGenerator,
    loaded: Set<ChunkCoordinate>, root: Entity, drawRadius: Int, block: (BlockPosition) -> Block) {
    bites.removeAll(keepingCapacity: true)
    guard deltaTime > 0 else { return }
    updateEggs(time: time, root: root)
    hatches = pendingHatches; pendingHatches = []
    bites = pendingBites.map(\.0)
    if let last = pendingBites.last { biteName = last.1 }
    pendingBites.removeAll(keepingCapacity: true)
    var createdRig = false
    for (coordinate, states) in population.families {
      guard let state = states.first(where: { state in families[coordinate]?.contains { $0.state.id == state.id } != true }) else { continue }
      let look = DinosaurAppearance(kind: state.kind, color: state.color, id: state.id, juvenile: state.baby)
      guard let geometry = ActorModelLibrary.shared.geometry(for: .dinosaur(look)) else { break }
      let rig = ActorRig(geometry, library: .shared)
      rig.root.scale *= state.scale; rig.root.position = state.position
      rig.root.orientation = simd_quatf(angle: state.heading, axis: [0,1,0]); root.addChild(rig.root)
      families[coordinate, default: []].append(.init(state: state, rig: rig, headRest: rig[.head].position))
      createdRig = true; break
    }
    for coordinate in Array(families.keys) {
      guard var family = families[coordinate] else { continue }
      for i in family.indices {
        var animal = family[i]
        let weight = min(1, deltaTime * 30)
        animal.root.position += (animal.state.position - animal.root.position) * weight
        animal.root.orientation = simd_slerp(animal.root.orientation, simd_quatf(angle: animal.state.heading, axis: [0,1,0]), weight)
        animal.gait += (animal.state.gait - animal.gait) * weight
        if animal.rig.updateDetail(distanceSquared: simd_distance_squared(animal.state.position, player) / max(1, animal.rig.height / 3)) {
          let state = animal.state, phase = Float(time.truncatingRemainder(dividingBy: 1_000)) + Float(state.id % 50)
          let attacking = state.mood == .windingUp || state.mood == .chomping
          animal.rig.face(time: time, id: state.id, asleep: state.resting, talking: false)
          animal.rig[.mouth].orientation = simd_quatf(angle: -state.jaw * 0.8 + (state.grazing ? sin(phase * 7) * 0.10 : 0), axis: [1,0,0])
          animal.rig[.head].position = animal.headRest + [0, attacking ? -0.35 : 0, 0]
          animal.rig[.head].orientation = simd_quatf(angle: state.grazing ? -0.22 : attacking ? -0.22 : sin(phase * 0.5) * 0.025, axis: [1,0,0])
          if riddenID == state.id {animal.rig[.head].position=animal.headRest;animal.rig[.head].orientation=simd_quatf()}
          animal.rig[.tail].orientation = simd_quatf(angle: sin(animal.gait * 0.5 + phase * 0.3) * 0.13, axis: [0,1,0])
          for (j, joint) in [ActorJoint.limb0, .limb1, .limb2, .limb3].enumerated() {
            let arm = state.kind.biped && j < 2
            let offset: Float = state.kind.biped ? Float(j % 2) * .pi : ((j == 0 || j == 3) ? 0 : .pi)
            animal.rig[joint].orientation = simd_quatf(angle: state.moving ? sin(animal.gait + offset) * (arm ? 0.13 : 0.30) : 0, axis: [1,0,0])
          }
        }
        family[i] = animal
      }
      families[coordinate] = family
    }
    updateGiant(deltaTime: deltaTime, time: time, player: player, terrain: terrain, loaded: loaded,
      root: root, drawRadius: drawRadius, mayCreate: !createdRig, block: block)
  }

  private func updateGiant(deltaTime: Float, time: Double, player: SIMD3<Float>, terrain: TerrainGenerator,
    loaded: Set<ChunkCoordinate>, root: Entity, drawRadius: Int, mayCreate: Bool, block: (BlockPosition) -> Block) {
    let range = Float(max(1, drawRadius) * 16)
    if giant == nil, mayCreate, let initial = population.giant {
      let state = initial.state, site = state.site
      let look = DinosaurAppearance(kind: .trex, color: site.color, id: site.id, juvenile: false)
      guard let geometry = ActorModelLibrary.shared.geometry(for: .dinosaur(look)) else { return }
      let rig = ActorRig(geometry, library: .shared), scale = site.heightMetres / rig.height
      rig.root.scale *= scale; rig.root.position = state.position
      rig.root.orientation = simd_quatf(angle: state.heading, axis: [0,1,0]); root.addChild(rig.root)
      giant = .init(state: state, rig: rig, scale: scale)
      print("WORLDCRAFT_DINOSAUR colossal_spawn height_m=\(Int(site.heightMetres)) x=\(Int(state.position.x)) z=\(Int(state.position.z))")
    }
    guard let animal = giant else { encounterMessage = ""; return }
    let weight = min(1, deltaTime * 10)
    animal.root.position += (animal.state.position - animal.root.position) * weight
    animal.root.orientation = simd_slerp(animal.root.orientation, simd_quatf(angle: animal.state.heading, axis: [0,1,0]), weight)
    let distance = simd_distance_squared(animal.state.position, player)
    animal.root.isEnabled = riddenID == animal.state.site.id || distance < range * range
    if animal.rig.updateDetail(distanceSquared: distance / (animal.scale * animal.scale)) {
      let phase = Float(time.truncatingRemainder(dividingBy: 1_000))
      animal.rig.face(time: time, id: animal.state.site.id, asleep: animal.state.resting && animal.state.display < 0.1, talking: false)
      let delta = player - animal.state.position
      let turn = atan2(-delta.x, -delta.z) - animal.state.heading
      let glance = min(0.4, max(-0.4, atan2(sin(turn), cos(turn)))) * animal.state.display
      animal.rig[.head].orientation = simd_quatf(angle: glance, axis: [0,1,0])
        * simd_quatf(angle: -animal.state.display * 0.17, axis: [1,0,0])
      if riddenID == animal.state.site.id {animal.rig[.head].orientation=simd_quatf()}
      animal.rig[.mouth].orientation = simd_quatf(angle: -max(0, sin(phase * 0.6)) * animal.state.display * 0.25, axis: [1,0,0])
      animal.rig[.tail].orientation = simd_quatf(angle: sin(phase * 0.18) * 0.07, axis: [0,1,0])
      for (j, joint) in [ActorJoint.limb2, .limb3].enumerated() {
        animal.rig[joint].orientation = simd_quatf(angle: animal.state.moving ? sin(animal.state.gait + Float(j) * .pi) * 0.13 : 0, axis: [1,0,0])
      }
    }
    encounterMessage = animal.root.isEnabled ? "Colossal T-rex · \(Int(animal.state.site.heightMetres)) m tall · \(life?.goal(id: animal.state.site.id) ?? "Roaming")" : ""
    giant = animal
  }
  private func updateEggs(time: Double, root: Entity) {
    guard time-lastEggUpdate > 0.1 || !pendingHatches.isEmpty else { return }
    lastEggUpdate = time
    let wanted = Set(population.eggs.map(\.id))
    for id in Array(eggEntities.keys) where !wanted.contains(id) { eggEntities.removeValue(forKey:id)?.removeFromParent() }
    for egg in population.eggs {
      if eggEntities[egg.id] == nil {
        let model: Entity
        if let cached = eggModels[egg.color] { model = cached.clone(recursive:true) }
        else {
          let shell = Entity()
          let color = RexColor(rawValue:egg.color)?.rgb ?? [0.8,0.7,0.4]
          let tint = UIColor(red:CGFloat(0.75+color.x*0.22),green:CGFloat(0.75+color.y*0.22),blue:CGFloat(0.67+color.z*0.22),alpha:1)
          let b = SculptureBuilder(materials:[SimpleMaterial(color:tint,roughness:0.86,isMetallic:false),
            SimpleMaterial(color:.init(red:0.30,green:0.22,blue:0.10,alpha:1),roughness:1,isMetallic:false),
            SimpleMaterial(color:.init(white:0.18,alpha:1),roughness:1,isMetallic:false)])
          for (i,width) in [Float(0.32),0.52,0.62,0.58,0.42,0.24].enumerated() {
            b.box([width,0.14,width],[0,Float(i)*0.13+0.12,0],0,parent:shell)
          }
          for i in 0..<8 {
            let angle = Float(i) * .pi/4
            b.box([0.22,0.08,0.2],[sin(angle)*0.5,0.04,cos(angle)*0.5],1,parent:shell)
          }
          let cracks=Entity(); cracks.name="Cracks"
          for i in 0..<4 { b.box([0.025,0.12,0.018],[i%2 == 0 ? 0.025 : -0.025,0.26+Float(i)*0.09,-0.304],2,parent:cracks) }
          shell.addChild(cracks); b.finish(); eggModels[egg.color]=shell
          model=shell.clone(recursive:true)
        }
        model.name="T-rex egg"; root.addChild(model); eggEntities[egg.id]=model
      }
      guard let model=eggEntities[egg.id] else { continue }
      let shaking=egg.progress > 0.85
      model.position=egg.position
      model.orientation=simd_quatf(angle:shaking ? sin(Float(time)*19+Float(egg.id%31))*0.08 : 0,axis:[0,0,1])
      model.findEntity(named:"Cracks")?.isEnabled=shaking
    }
    for point in pendingHatches {
      let shell=Entity(); shell.position=point+[0,0.4,0]
      var burst=ParticleEmitterComponent.Presets.impact
      burst.burstCount=18; burst.mainEmitter.birthRate=0; burst.mainEmitter.lifeSpan=0.7
      burst.mainEmitter.size=0.07; burst.mainEmitter.color = .constant(.single(.init(red:0.98,green:0.91,blue:0.71,alpha:1)))
      burst.mainEmitter.acceleration=[0,-4,0]; burst.speed=1.3; burst.burst()
      shell.components.set(burst); root.addChild(shell); hatchEffects.append((shell,time+1))
    }
    hatchEffects.removeAll { effect in if time >= effect.1 { effect.0.removeFromParent(); return true }; return false }
  }
  func clear() {
    riddenID = nil
    eggEntities.values.forEach { $0.removeFromParent() }; eggEntities = [:]
    hatchEffects.forEach { $0.0.removeFromParent() }; hatchEffects = []; pendingHatches = []; hatches = []
    lastEggUpdate = -.infinity
    families.values.flatMap { $0 }.forEach { $0.root.removeFromParent() }
    giant?.root.removeFromParent(); giant = nil
    families.removeAll(); population = .init(); pendingBites.removeAll(); bites.removeAll(); encounterMessage = ""
  }
}
