import RealityKit
import UIKit
import WorldCore

@MainActor
final class WildlifeRenderer {
  @MainActor private struct Animal {
    var state: AnimalState
    let rig: ActorRig
    var entity: Entity { rig.root }
    var head: Entity { rig[.head] }
    let legs: [Entity]
    var renderGait: Float = 0
    var seated = false
  }
  private var targets: [AnimalState] = []
  private(set) var companionCarrier: CompanionCarrier?
  private var companionIDs: [UInt64] = []
  private var companionOrdinals: [UInt64:Int] = [:]
  private var companionJourney: UInt64 = 0
  func setCompanionCarrier(_ next: CompanionCarrier?, ids: [UInt64],
    parkedCarrier: (CompanionCarrier)->CompanionCarrier?) {
    if ids != companionIDs {
      companionIDs=ids
      companionOrdinals=Dictionary(ids.enumerated().map { ($0.element,$0.offset) },uniquingKeysWith:{ first,_ in first })
    }
    if next != nil && (next?.id != companionCarrier?.id || next?.kind != companionCarrier?.kind) {
      companionJourney &+= 1
    }
    companionCarrier=next; companionCarrier?.journey=companionJourney
    for i in targets.indices {
      guard let ordinal=companionOrdinals[targets[i].id] else {continue}
      let current=animals[targets[i].id]?.state ?? targets[i]
      var carrier=companionCarrier
      if carrier == nil,let waiting=current.passenger, var parked=parkedCarrier(waiting.carrier) {
        parked.journey=waiting.carrier.journey;carrier=parked
      }
      if let carrier {
        targets[i].board(carrier,ordinal:ordinal)
        if animals[targets[i].id] != nil { animals[targets[i].id]!.state.board(carrier,ordinal:ordinal) }
      }
    }
  }
  var riddenID: UInt64?
  var mounts: [MountCandidate] {
    animals.values.compactMap { animal in
      let state=animal.state
      guard let profile=MountProfile.animal(state.kind,baby:state.baby) else { return nil }
      return .init(id:state.id,name:state.kind.name,position:state.position,heading:state.heading,profile:profile)
    }
  }
  func applyRider(_ ride: MountedRide, seconds: Float) {
    if let i=targets.firstIndex(where:{$0.id == ride.id}) { targets[i].applyRider(ride,seconds:seconds) }
    if animals[ride.id] != nil {
      animals[ride.id]!.state.applyRider(ride,seconds:seconds)
      animals[ride.id]!.entity.position=ride.position
      animals[ride.id]!.entity.orientation=simd_quatf(angle:ride.heading,axis:[0,1,0])
    }
  }
  private var animals: [UInt64: Animal] = [:]
  private var terrain = TerrainGenerator(seed: 0)
  private var bonds: [UInt64: AnimalBond] = [:]
  private var focused: UInt64?
  private var hearts: [UInt64: Entity] = [:]
  var offering: AnimalFood?
  weak var life: FaunaLife?
  var simulationStates: [AnimalState] { targets.map { animals[$0.id]?.state ?? $0 } }
  func contains(id: UInt64) -> Bool { targets.contains { $0.id == id } }
  func applySimulation(_ states: [AnimalState]) {
    let ids = Set(states.map(\.id))
    for id in Array(animals.keys) where !ids.contains(id) { _ = removePrey(id: id) }
    let previous=Dictionary(uniqueKeysWithValues:targets.map { ($0.id,animals[$0.id]?.state ?? $0) })
    targets = states.map { incoming in
      var state=incoming
      // An older walking proposal must not undo a boarding that happened
      // while the life actor was busy, even if the player already got out.
      if let current=previous[state.id],current.companionJourney>state.companionJourney {state=current}
      if let carrier=companionCarrier,let ordinal=companionOrdinals[state.id] {state.board(carrier,ordinal:ordinal)}
      return state
    }
    for state in targets where animals[state.id] != nil {
      // Feeding/petting can occur after the worker captured its input.
      // Those immediate interactions retain the latest local bond and feedback.
      let current = animals[state.id]!.state
      if state.id != riddenID { animals[state.id]!.state = state }
      animals[state.id]!.state.bond = current.bond
      animals[state.id]!.state.pettedUntil = current.pettedUntil
    }
  }
  func snapshots(time: Double) -> [FaunaSnapshot] {
    simulationStates.filter { $0.passenger == nil }.map { .init(id: $0.id, species: String(describing: $0.kind), kind: $0.kind,
      position: $0.position, home: $0.home, trusting: $0.kind.pet || $0.bond.trusting,
      following: $0.followsPlayer(at: time)) }
  }
  func removePrey(id: UInt64) -> Bool {
    let existed = contains(id: id)
    targets.removeAll { $0.id == id }
    guard let animal = animals.removeValue(forKey: id) else { return existed }
    let key = id
    if animal.state.bond.meals > 0 || animal.state.bond.befriended == true { bonds[id] = animal.state.bond }
    animal.entity.removeFromParent(); hearts.removeValue(forKey: id)?.removeFromParent()
    if focused == key { clearFocus() }
    return true
  }
  private(set) var prompt = ""
  var hasFocus: Bool { focused != nil }
  var focusedKind: AnimalKind? { focused.flatMap { animals[$0]?.state.kind } }
  var focusedDog: Bool { focusedKind == .dog }
  var focusedPet: Bool { focusedKind?.pet == true }
  var focusedBond: AnimalBond? { focused.flatMap { animals[$0]?.state.bond } }
  var focusedPosition: SIMD3<Float>? { focused.flatMap { animals[$0]?.state.position } }
  var dogPositions: [SIMD3<Float>] { animals.values.filter { $0.state.kind.pet && $0.state.passenger == nil }.map { $0.state.position } }
  func clearFocus() { focused = nil; prompt = "" }
  var records: [AnimalBond] {
    var records = bonds
    for animal in animals.values where animal.state.bond.meals > 0 || animal.state.bond.befriended == true { records[animal.state.id] = animal.state.bond }
    return records.values.sorted { ($0.lastFed ?? 0) > ($1.lastFed ?? 0) }.prefix(512).map { $0 }
  }
  func restore(_ records: [AnimalBond]) {
    bonds = Dictionary(records.filter(\.isValid).prefix(512).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
  }
  var count: Int { animals.count }
  var audibleAnimals: [(AnimalKind, SIMD3<Float>)] {
    animals.values.filter { $0.entity.isEnabled }.map { ($0.state.kind, $0.state.position) }
  }
  func configure(terrain: TerrainGenerator) {
    clear()
    self.terrain = terrain
  }

  func update(
    deltaTime: Float, time: Double, player: SIMD3<Float>, root: Entity,
    loaded: Set<ChunkCoordinate>, site: Settlement?, block: (BlockPosition) -> Block
  ) {
    guard deltaTime > 0 else { return }
    // The actor delivers value states; publish at most one detailed rig per frame.
    if let state = targets.first(where: { animals[$0.id] == nil && $0.passenger?.visible != false }) { add(state, root: root) }
    for coordinate in Array(animals.keys) {
      guard var animal = animals[coordinate] else { continue }
      if let passenger=animal.state.passenger {
        animal.seated=true
        animal.entity.isEnabled=passenger.visible
        if !passenger.visible {animals[coordinate]=animal;continue}
        // Use the current car/boat pose at input cadence, with no interpolation
        // toward delayed AI positions. Hull pitch/heel come from the same pose.
        animal.entity.transform = .init(scale:.init(repeating:WorldScale.blocks(passenger.scale)),
          rotation:passenger.rotation,translation:passenger.position)
      } else {
        animal.entity.isEnabled=true
        animal.entity.scale = .init(repeating:WorldScale.blocks(animal.state.baby ? 0.62:1))
        if animal.seated {animal.entity.position=animal.state.position;animal.renderGait=0;animal.seated=false}
        animal.entity.position += (animal.state.position - animal.entity.position) * min(1, deltaTime * 30)
        animal.entity.orientation = simd_slerp(animal.entity.orientation,
          simd_quatf(angle: animal.state.heading, axis: [0, 1, 0]), min(1, deltaTime * 30))
      }
      animal.renderGait += (animal.state.gait - animal.renderGait) * min(1, deltaTime * 30)
      if animal.rig.updateDetail(distanceSquared: simd_distance_squared(animal.state.position, player)) {
        let state = animal.state, kind = state.kind
        let phase = Float(time.truncatingRemainder(dividingBy: 1_000)) + Float(state.id % 31)
        animal.rig.face(time: time, id: state.id, asleep: state.resting, talking: false)
        animal.rig[.mouth].orientation = simd_quatf(angle: state.grazing ? sin(phase * 9) * 0.1 : 0, axis: [1, 0, 0])
        animal.head.orientation = simd_quatf(angle: state.grazing ? 0.5 : state.resting ? 0.20 : sin(phase * 0.65) * 0.035, axis: [1, 0, 0])
          * simd_quatf(angle: state.moving ? 0 : sin(phase * 0.37) * 0.08, axis: [0, 1, 0])
        animal.rig[.tail].orientation = simd_quatf(angle: sin(animal.renderGait + phase * 1.3) * (kind == .fish || kind == .otter ? 0.35 : 0.16), axis: [0, 1, 0])
        if kind == .dog {
          let goal = life?.directive(id: state.id)?.goal
          let nearPlayer = simd_distance_squared(state.position, player) < 10 * 10
          let delighted = !state.resting && (state.pettedUntil > time || state.bond.chewing(at: time)
            || (nearPlayer && (state.followsPlayer(at: time) || goal == .beg || goal == .greetPlayer)))
          let sniffing = goal == .sniff && !state.moving
          let pitch: Float = state.grazing || sniffing ? -0.45 : state.resting ? -0.25 : delighted ? 0.18 : 0.02
          let tilt: Float = !state.moving && !state.resting && !state.grazing && !sniffing ? sin(phase * 0.9) * 0.16 : 0
          animal.head.orientation = simd_quatf(angle: pitch, axis: [1, 0, 0]) * simd_quatf(angle: tilt, axis: [0, 0, 1])
          animal.rig[.tail].orientation = simd_quatf(angle: sin(phase * (delighted ? 12 : 2.4)) * (state.resting ? 0 : delighted ? 0.65 : 0.18), axis: [0, 1, 0])
          animal.rig[.mouth].orientation = simd_quatf(angle: state.resting ? 0.22 : state.grazing ? sin(phase * 9) * 0.10 : 0.04 + sin(phase * 7) * 0.035, axis: [1, 0, 0])
        }
        if kind == .hayHay {
          let happy = state.pettedUntil > time || state.followsPlayer(at:time)
          animal.head.orientation = simd_quatf(angle:sin(phase*1.8)*(happy ? 0.12 : 0.045),axis:[0,0,1])
          animal.rig[.tail].orientation = simd_quatf(angle:sin(phase*5)*(happy ? 0.30 : 0.08),axis:[0,1,0])
        }
        if kind == .elephant { animal.rig[.mouth].orientation = simd_quatf(angle: sin(phase * 1.4) * 0.12 + (state.grazing ? -0.3 : 0), axis: [1, 0, 0]) }
        for (i, leg) in animal.legs.enumerated() {
          if let passenger=state.passenger {
            let angle:Float=i>=2 ? (passenger.clinging ? 1.15:0.18):0.35
            leg.orientation=simd_quatf(angle:angle,axis:[1,0,0])
            continue
          }
          let bird = [.chicken, .duck, .parrot, .penguin].contains(kind)
          let wing = bird && i >= 2
          let angle: Float = wing ? sin(phase * 4) * (state.moving ? 0.15 : 0.035) * (i == 2 ? -1 : 1)
            : kind == .fish ? sin(phase * 5 + Float(i)) * 0.25
            : state.moving ? sin(animal.renderGait + Float((i == 0 || i == 3) ? 0 : 1) * .pi) * (kind == .tortoise ? 0.18 : 0.36)
            : state.resting ? 0.65 : 0
          leg.orientation = simd_quatf(angle: angle, axis: kind == .fish ? [0, 1, 0] : wing ? [0, 0, 1] : [1, 0, 0])
        }
        if kind == .dog && state.doorVisit.scratching != nil, let paw=animal.legs.first {
          paw.orientation=simd_quatf(angle:0.65+max(0,sin(phase*16))*0.55,axis:[1,0,0])
        }
        if (kind == .rabbit || kind == .frog) && state.moving {
          animal.entity.position.y = state.position.y + abs(sin(animal.renderGait)) * (kind == .frog ? 0.12 : 0.20)
        }
      }
      if animal.state.bond.chewing(at: time) || animal.state.pettedUntil > time {
        if hearts[animal.state.id] == nil {
          let heart = Entity()
          let builder = SculptureBuilder(materials: [UnlitMaterial(color: .systemPink)])
          for (y, xs) in [(0, [0]), (1, [-1, 0, 1]), (2, [-2, -1, 0, 1, 2]), (3, [-2, -1, 1, 2])] {
            for x in xs { builder.box([0.055, 0.055, 0.045], [Float(x) * 0.055, Float(y) * 0.055, 0], 0, parent: heart) }
          }
          builder.finish(); animal.entity.addChild(heart); hearts[animal.state.id] = heart
        }
        hearts[animal.state.id]?.isEnabled = true
        hearts[animal.state.id]?.position = [0, (animal.rig.height + 0.22) + Float(sin(time * 3)) * 0.04, 0]
      } else { hearts[animal.state.id]?.isEnabled = false }
      animals[coordinate] = animal
    }
    if bonds.count > 512 { bonds = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }) }
  }

  func focus(eye: SIMD3<Float>, direction: SIMD3<Float>, item: InventoryItem?, time: Double,
    block: (BlockPosition) -> Block) {
    focused = nil; prompt = ""
    var closest: Float = WorldScale.blocks(2)
    let length = simd_length(direction)
    guard length > 0.001 else { return }
    for (key, animal) in animals where animal.entity.isEnabled {
      let target = animal.entity.position
        + animal.entity.orientation.act(animal.head.position * animal.entity.scale)
      let delta = target - eye, distance = simd_length(delta)
      guard distance < closest, distance > 0.001, simd_dot(delta / distance, direction / length) > 0.88,
        VoxelRaycast.cast(origin: eye, direction: delta, reach: max(0, distance - 0.4), block: block) == nil else { continue }
      focused = key; closest = distance
    }
    guard let key = focused, let animal = animals[key] else { return }
    let kind = animal.state.kind
    if let food = item?.food, kind.foods.contains(food) {
      prompt = animal.state.bond.ready(at: time) ? "\(kind.name) · Feed \(item!.name) · LT / R / right-click" : "\(kind.name) is still enjoying its meal"
    } else {
      let goal = life?.goal(id: animal.state.id) ?? "Exploring"
      if kind == .hayHay {
        prompt = "Hay Hay · \(animal.state.bond.trusting ? "Your friend" : "You found me!") · Pet: R / LT · Loves flowers and grass"
      } else if kind == .dog {
        prompt = "Boomer · \(animal.state.bond.trusting ? "Your friend" : goal) · Pet: R / LT · Loves berry bushes"
      } else {
        prompt = "\(kind.name) · \(goal) · " + (kind.foods.isEmpty ? "Hunts for food" : "Likes \(kind.foodHint)")
      }
    }
  }
  func feedSelected(_ item: InventoryItem, time: Double) -> FeedingResult? {
    guard let key = focused, var animal = animals[key] else { return nil }
    let result = animal.state.feed(item.food, time: time)
    animals[key] = animal
    if result == .fed {
      bonds[animal.state.id] = animal.state.bond
      life?.fed(id: animal.state.id, at: animal.state.position, time: time)
    }
    return result
  }
  func petSelected(time: Double) -> Bool {
    guard let key = focused, var animal = animals[key], animal.state.kind.pet,
      time.isFinite, time >= animal.state.pettedUntil else { return false }
    animal.state.pettedUntil = time + 3
    if animal.state.kind == .hayHay {
      animal.state.bond.befriended = true
      bonds[animal.state.id] = animal.state.bond
    }
    animals[key] = animal
    life?.petted(id: animal.state.id, at: animal.state.position, time: time)
    return true
  }

  private func add(_ initial: AnimalState, root: Entity) {
    var state = initial
    state.bond = bonds[state.id] ?? state.bond
    guard let animal = build(state) else { return }
    root.addChild(animal.entity); animals[state.id] = animal
  }

  private func build(_ state: AnimalState) -> Animal? {
    let look = AnimalAppearance(kind: state.kind, id: state.id, juvenile: state.baby)
    guard let geometry = ActorModelLibrary.shared.geometry(for: .animal(look)) else { return nil }
    let rig = ActorRig(geometry, library: .shared)
    if state.baby { rig.root.scale *= 0.62 }
    rig.root.position = state.position
    rig.root.orientation = simd_quatf(angle: state.heading, axis: [0, 1, 0])
    return .init(state: state, rig: rig, legs: [rig[.limb0], rig[.limb1], rig[.limb2], rig[.limb3]])
  }
  func clear() {
    riddenID = nil
    companionCarrier=nil;companionIDs=[];companionOrdinals=[:];companionJourney=0
    animals.values.forEach { $0.entity.removeFromParent() }
    animals.removeAll()
    targets.removeAll()
    bonds.removeAll(); hearts.removeAll(); focused = nil; prompt = ""; offering = nil
  }
}
