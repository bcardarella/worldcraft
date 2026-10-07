import Foundation
import QuartzCore
import WorldCore
import simd

struct FaunaSnapshot: Sendable {
  let id: UInt64
  let species: String
  let kind: AnimalKind?
  let position: SIMD3<Float>
  let home: SIMD3<Float>
  var trusting = false
  var following = false
  var groupID: UInt64?
  var juvenile = false
  var distantOptions: [String: AnimalDecisionOption] = [:]
  var remoteWater = false
  var dinosaur: DinosaurKind? { species == "colossal_trex" ? .trex : DinosaurKind(rawValue: species) }
  var colossal: Bool { species == "colossal_trex" }
  var predator: Bool { dinosaur?.carnivore == true || !(kind?.prey.isEmpty ?? true) }
  var strength: Float { colossal ? 100 : (dinosaur?.strength ?? 1) * (juvenile ? 0.22 : 1) }
  var contactReach: Float { colossal ? 34 : 2.5 }
  var shelterClearance: Int { dinosaur.map { Int(ceil($0.clearance.height * (juvenile ? 0.45 : 1))) } ?? 3 }
  func preysOn(_ other: Self) -> Bool {
    guard predator, other.id != id, !other.colossal,
      !(groupID != nil && groupID == other.groupID) else { return false }
    if let dinosaur, let prey = other.dinosaur {
      return prey != dinosaur && !prey.carnivore && other.strength < strength * 0.8
    }
    let choices = dinosaur?.prey ?? kind?.prey ?? []
    return other.kind.map { choices.contains($0) && (!juvenile || $0.small || $0 == .pig) } ?? false
  }
}

@SimulationActor final class FaunaSimulation {
  private struct Mind: Sendable {
    var record: FaunaRecord
    var options: [String: AnimalDecisionOption] = [:]
    var chosen: AnimalDecisionOption?
    var revision = 0
    var nextSense: Double = 0
    var nextChoice: Double = 0
    var working: Float = 0
    var stuck: Float = 0
    var previous: SIMD3<Float>
  }
  private var minds: [UInt64: Mind] = [:]
  private var saved: [UInt64: FaunaRecord] = [:]
  private var client: JevNPCClient?
  private var task: Task<Void, Never>?
  private var epoch = UUID()
  private var budget = NPCRequestBudget()
  private var accumulator: Float = 0
  private var nextBatch: Double = 0
  private var pending: (JevNPCResponse, [UInt64: [String: AnimalDecisionOption]], [UInt64: Int], Double)?
  private var pendingPlans: [UInt64: (AgencyPlan, Double)] = [:]
  var planner: DeliberationService?
  var onEatPlant: ((BlockPosition, PlantKind) -> Bool)?
  var onHunt: ((UInt64) -> Bool)?
  private(set) var status = "Local animal instincts"
  var directives: [UInt64: AnimalDecisionOption] { minds.compactMapValues(\.chosen) }
  /// Network tasks/budgets are never rolled back. Only a speculative simulation
  /// step is restored when the live world changed before it could be committed.
  func checkpoint() -> @SimulationActor () -> Void {
    let minds = minds, saved = saved, accumulator = accumulator, pending = pending, plans = pendingPlans
    return {
      self.minds = minds; self.saved = saved; self.accumulator = accumulator
      if self.pending == nil { self.pending = pending }
      self.pendingPlans.merge(plans) { newest, _ in newest }
    }
  }
  var records: [FaunaRecord] {
    var records = saved
    for (id, mind) in minds { records[id] = mind.record }
    let ranked = records.values.map { record in
      (record, max(record.absentUntil, record.lastPlan, record.lastMigration, record.memory.experiences.map(\.time).max() ?? 0))
    }
    return ranked.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }.prefix(1_024).map(\.0)
  }
  func register(_ actors: [FaunaSnapshot]) {
    for actor in actors where minds[actor.id] == nil {
      minds[actor.id] = .init(record: saved[actor.id] ?? .init(id: actor.id, species: actor.species, home: actor.home), previous: actor.position)
    }
  }
  func restore(_ records: [FaunaRecord]) {
    suspend(); minds = [:]
    saved = Dictionary(records.filter(\.isValid).prefix(1_024).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    accumulator = 0
  }
  var nestingRecords: [FaunaRecord] {
    minds.values.map(\.record).filter { $0.brood != nil || $0.hatchedDinosaur != nil }
      + saved.values.filter { minds[$0.id] == nil && ($0.brood != nil || $0.hatchedDinosaur != nil) }
  }
  /// Reproduction is local biology on the simulation actor. Hatch state is
  /// checkpointed with memory and committed atomically with the new population.
  func updateNests(parents: [RexState], giant:ColossalRexState?=nil, seconds: Float, player: SIMD3<Float>,
    loaded: Set<ChunkCoordinate>, block: (BlockPosition) -> Block) {
    let parents=parents.compactMap(DinosaurNestParent.init)+(giant.map { $0.moving ? []:[DinosaurNestParent($0)] } ?? [])
    for parent in parents {
      guard var mind = minds[parent.id], mind.record.brood == nil else { continue }
      mind.record.brood = .init(parentID:parent.id); minds[parent.id] = mind
    }
    for var record in nestingRecords where record.brood != nil {
      guard let location = record.brood?.eggs.first?.position ?? Optional(record.home),
        loaded.contains(BlockPosition(location).chunk), simd_distance_squared(location,player) < 100*100 else { continue }
      var brood = record.brood!
      let healthy = record.hunger < 0.72 && record.thirst < 0.72 && record.fatigue < 0.85
      brood.advance(seconds:seconds,healthy:healthy)
      if healthy, brood.wait == 0, let parent = parents.first(where: { $0.id == record.id }),
        simd_distance_squared(parent.position,parent.home) < max(14,parent.radius)*max(14,parent.radius),
        (parent.radius>5 || simd_distance_squared(parent.position,player) > 10*10) {
        let points: [SIMD3<Float>] = [-2.0,2.0].compactMap { x in
          let heights:[Float] = parent.radius>5 ? [0]+(1...8).flatMap { [Float($0),-Float($0)] } : [0,1,-1]
          for y in heights {
            let p = parent.nestCenter+[Float(x),y,0]
            guard loaded.contains(BlockPosition(p).chunk), block(BlockPosition(p+[0,-0.1,0])).isSolid,
              RexState.clear(at:p,scale:0.45,block:block), !block(BlockPosition(p)).isLiquid else { continue }
            return p
          }
          return nil
        }
        _ = brood.lay(parent:parent,positions:points)
      }
      record.brood = brood
      if minds[record.id] != nil { minds[record.id]!.record = record } else { saved[record.id] = record }
    }
  }
  func hatchReadyEggs(capacity: Int, player: SIMD3<Float>, loaded: Set<ChunkCoordinate>,
    block: (BlockPosition) -> Block) -> [RexState] {
    var result: [RexState] = []
    let nests = nestingRecords
    guard nests.filter({ $0.hatchedDinosaur != nil }).count < 128 else { return [] }
    for var parent in nests where parent.brood != nil {
      for i in parent.brood!.eggs.indices {
        let egg = parent.brood!.eggs[i]
        guard result.count < capacity, !egg.hatched, egg.progress >= 1,
          loaded.contains(BlockPosition(egg.position).chunk), simd_distance_squared(egg.position,player) < 96*96,
          let color = RexColor(rawValue:egg.color),
          let point = [SIMD3<Float>.zero,[1,0,0],[-1,0,0],[0,0,1],[0,0,-1]].map({ egg.position+$0 }).first(where: {
            block(BlockPosition($0+[0,-0.1,0])).isSolid && RexState.clear(at:$0,scale:0.45,block:block) && !block(BlockPosition($0)).isLiquid
          }) else { continue }
        let group = parent.social?.groupID ?? parent.id
        var baby = FaunaRecord(id:egg.id,species:"trex",home:point)
        baby.hatchedDinosaur = .init(parentID:parent.id,groupID:group,color:egg.color)
        baby.social = .init(groupID:group,juvenile:true)
        saved[egg.id] = baby
        parent.brood!.eggs[i].hatched = true
        result.append(.init(id:egg.id,color:color,baby:true,position:point,groupID:group))
      }
      if minds[parent.id] != nil { minds[parent.id]!.record = parent } else { saved[parent.id] = parent }
    }
    return result
  }
  func restoredHatchlings(time: Double, player: SIMD3<Float>, loaded: Set<ChunkCoordinate>, block: (BlockPosition) -> Block) -> [RexState] {
    nestingRecords.compactMap { record in
      guard let origin = record.hatchedDinosaur, record.absentUntil <= time,
        loaded.contains(BlockPosition(record.position).chunk), simd_distance_squared(record.position,player) < 96*96,
        let color = RexColor(rawValue:origin.color), RexState.clear(at:record.position,scale:0.45,block:block) else { return nil }
      return .init(id:record.id,color:color,baby:true,position:record.position,groupID:origin.groupID)
    }
  }
  func configureJev(key: String?, enabled: Bool) {
    suspend(); client = enabled ? key.map { JevNPCClient(apiKey: $0) } : nil
    status = client == nil ? "Local animal instincts" : "Jev animals ready"
  }
  func suspend() { task?.cancel(); task = nil; pending = nil; pendingPlans = [:]; budget = .init(); epoch = UUID() }
  func canSpawn(id: UInt64, time: Double) -> Bool { (minds[id]?.record.absentUntil ?? saved[id]?.absentUntil ?? 0) <= time }
  func restoredPosition(id: UInt64) -> SIMD3<Float>? { minds[id]?.record.position ?? saved[id]?.position }
  func knownKind(id: UInt64) -> AnimalKind? {
    guard let species = minds[id]?.record.species ?? saved[id]?.species else { return nil }
    return AnimalKind.allCases.first { String(describing: $0) == species }
  }
  func knownDinosaur(id: UInt64) -> DinosaurKind? {
    (minds[id]?.record.species ?? saved[id]?.species).flatMap(DinosaurKind.init(rawValue:))
  }
  func directive(id: UInt64) -> AnimalDecisionOption? { minds[id]?.chosen }
  func goal(id: UInt64) -> String { minds[id]?.record.goal.label ?? "Exploring" }
  func fed(id: UInt64, at position: SIMD3<Float>, time: Double) {
    guard var mind = minds[id] else { return }
    mind.record.hunger = max(0, mind.record.hunger - 0.4)
    mind.record.memory.remember(.fedByPlayer, "The player gave me food", at: .init(position), time: time, importance: 0.85)
    if ["dog","hayHay"].contains(mind.record.species) { mind.chosen = nil; mind.nextSense = time }
    mind.nextChoice = time + 3; mind.working = 0; mind.revision += 1; minds[id] = mind
  }
  func petted(id: UInt64, at position: SIMD3<Float>, time: Double) {
    guard var mind = minds[id], ["dog","hayHay"].contains(mind.record.species) else { return }
    mind.record.memory.remember(.metPlayer, "The player petted me. I like this friendly person!", at: .init(position), time: time, importance: 0.8)
    mind.nextChoice = time; mind.nextSense = time; mind.chosen = nil; mind.revision += 1; minds[id] = mind
  }
  func update(actors: [FaunaSnapshot], deltaTime: Float, time: Double, player: SIMD3<Float>,
    offering: AnimalFood?, weather: WorldWeather, night: Bool, loaded: Set<ChunkCoordinate>,
    plants: (SIMD3<Float>) -> [PlantInstance], block: (BlockPosition) -> Block) {
    guard deltaTime > 0 else { if task != nil || pending != nil { suspend() }; return }
    accumulator += deltaTime
    guard accumulator >= 1 / 15 else { return }
    let dt = min(0.2, accumulator); accumulator = 0
    let ids = Set(actors.map(\.id))
    for id in Array(minds.keys) where !ids.contains(id) { saved[id] = minds.removeValue(forKey: id)?.record }
    // Register the whole visible group before delivering alarms or recording a
    // capture; behavior must not depend on which actor is iterated first.
    for actor in actors where minds[actor.id] == nil {
      minds[actor.id] = .init(record: saved[actor.id] ?? .init(id: actor.id, species: actor.species, home: actor.home), previous: actor.position)
    }
    var sensed = 0
    for actor in actors {
      var mind = minds[actor.id] ?? .init(record: saved[actor.id] ?? .init(id: actor.id, species: actor.species, home: actor.home), previous: actor.position)
      guard mind.record.absentUntil <= time else { minds[actor.id] = mind; continue }
      mind.record.position = actor.position
      if let group = actor.groupID, mind.record.social == nil {
        mind.record.social = .init(groupID: group, juvenile: actor.juvenile)
      }
      mind.record.advance(seconds: actor.colossal ? dt * 0.2 : dt, aquatic: actor.kind?.aquatic == true)
      if sensed < 2 && time >= mind.nextSense {
        sensed += 1; mind.nextSense = time + 2
        if actor.groupID != nil {
          let mates = actors.filter { $0.id != actor.id && $0.groupID == actor.groupID }
          for mate in mates {
            mind.record.social?.bond(with: mate.id, family: actor.juvenile || mate.juvenile, time: time, reward: 0)
          }
          if time - (mind.record.social?.lastAlarm ?? 0) > 8,
            let threat = actors.first(where: { hunter in
              (hunter.preysOn(actor) || mates.contains { $0.juvenile && hunter.preysOn($0) })
                && simd_distance_squared(hunter.position, actor.position) < 14 * 14
            }) {
            mind.record.social?.lastAlarm = time
            mind.record.memory.remember(.danger, "Spotted a predator and warned my group", at: .init(threat.position), other: threat.id, time: time, importance: 0.9)
            for mate in mates where simd_distance_squared(mate.position, actor.position) < 30 * 30 {
              if var other = minds[mate.id] {
                other.record.memory.remember(.danger, "A group mate warned me about a nearby predator", at: .init(threat.position), other: threat.id, time: time, importance: 0.9)
                other.nextSense = 0; other.nextChoice = time; minds[mate.id] = other
              }
            }
          }
        }
        let previouslyOfferedFood = mind.options["beg"] != nil
        let previouslyDistracted = mind.options["sniff"] != nil
        mind.options = perceive(actor: actor, mind: mind, others: actors, player: player, offering: offering,
          weather: weather, night: night, time: time, loaded: loaded, plants: plants(actor.position), block: block)
        if actor.kind == .dog {
          let snackAppeared = !previouslyOfferedFood && mind.options["beg"] != nil
          let smellAppeared = !previouslyDistracted && mind.options["sniff"] != nil && mind.chosen?.goal == .follow
          if (snackAppeared || smellAppeared) && mind.record.thirst < 0.8 && mind.record.fatigue < 0.95
            && mind.chosen?.goal != .flee {
            // A small attention span is visible in play. Invalidate an old
            // async answer as well as the errand the new smell interrupted.
            finish(&mind, time: time)
          }
        }
        if let chosen = mind.chosen {
          if let current = mind.options.values.first(where: { sameIntent($0, chosen) }) { mind.chosen = current }
          else { mind.chosen = nil; mind.nextChoice = time; mind.revision += 1 }
        }
      }
      // Immediate escape is a motor safety reaction; deliberate goals remain Jev choices.
      if let flee = mind.options["flee"], mind.record.goal != .flee {
        mind.chosen = flee; mind.record.goal = .flee; mind.nextChoice = time + 3; mind.revision += 1
      }
      if let chosen = mind.chosen, let preyID = chosen.preyID {
        if let prey = actors.first(where: { $0.id == preyID }), canSpawn(id: preyID, time: time),
          !protected(prey, against: actor, among: actors) {
          let flank: SIMD3<Float> = chosen.goal == .joinHunt ? [actor.id % 2 == 0 ? -1.3 : 1.3, 0, 0] : .zero
          mind.chosen = .init(chosen.goal, at: .init(prey.position + flank), preyID: preyID,
            partnerID: chosen.partnerID, description: chosen.description)
        } else { finish(&mind, time: time) }
      }
      if let chosen = mind.chosen {
        let distance = simd_distance(actor.position, chosen.point.center)
        let precise = [.drink, .shelter, .sleep, .returnHome, .migrate].contains(chosen.goal)
        let moved = simd_distance_squared(actor.position, mind.previous) > 0.0004
        let arrivalRange: Float = precise ? (actor.colossal ? 8 : 0.8)
          : [.hunt, .joinHunt].contains(chosen.goal) ? actor.contactReach : 2.2
        mind.stuck = distance > max(2.5, arrivalRange) && !moved ? mind.stuck + dt : 0
        if mind.stuck > 6 {
          mind.record.memory.remember(.failedRoute, "This destination was blocked", at: chosen.point, other: chosen.preyID, time: time, importance: 0.65)
          mind.chosen = nil; mind.nextChoice = time; mind.nextSense = time; mind.stuck = 0; mind.revision += 1
        } else if distance < arrivalRange {
          mind.working += dt
          switch chosen.goal {
          case .forage:
            if mind.working >= 1.5, let plant = chosen.plant,
              VoxelRaycast.cast(origin: actor.position + [0, 0.8, 0], direction: chosen.point.center - (actor.position + [0, 0.8, 0]),
                reach: max(0, simd_distance(chosen.point.center, actor.position + [0, 0.8, 0]) - 0.5), block: block) == nil,
              onEatPlant?(chosen.point, plant) == true {
              mind.record.eat(at: chosen.point, time: time)
              finish(&mind, time: time)
            } else if chosen.plant == nil && actor.kind == .frog && mind.working >= 2 {
              // Small wetland insects are ambient prey, not plant blocks.
              mind.record.eat(at: chosen.point, time: time, hunted: true); finish(&mind, time: time)
            }
          case .hunt, .joinHunt:
            if mind.working >= 1.0, let prey = chosen.preyID,
              let current = actors.first(where: { $0.id == prey }),
              simd_distance(current.position, actor.position) < actor.contactReach,
              VoxelRaycast.cast(origin: actor.position + [0, 1, 0], direction: current.position - actor.position,
                reach: max(0, simd_distance(current.position, actor.position) - 0.4), block: block) == nil,
              onHunt?(prey) == true {
              if var victim = minds[prey]?.record ?? saved[prey] {
                victim.absentUntil = time + WorldEnvironment.dayDuration
                victim.memory.remember(.danger, "A predator caught me here", at: .init(current.position), other: actor.id, time: time, importance: 1)
                saved[prey] = victim
                if minds[prey] != nil { minds[prey]!.record = victim }
              }
              // A single real capture can be shared with nearby participating
              // group mates. They get a smaller meal, not a second prey kill.
              for ally in actors where ally.id != actor.id && actor.groupID != nil && ally.groupID == actor.groupID
                && simd_distance_squared(ally.position, current.position) < 8 * 8 {
                if var companion = minds[ally.id], companion.chosen?.preyID == prey {
                  companion.record.hunger = max(0, companion.record.hunger - 0.22)
                  companion.record.memory.remember(.hunted, "Shared prey from our cooperative hunt", at: .init(current.position), other: actor.id, time: time, importance: 0.8)
                  companion.record.social?.bond(with: actor.id, family: false, time: time, reward: 0.1)
                  mind.record.social?.bond(with: ally.id, family: false, time: time, reward: 0.1)
                  finish(&companion, time: time); minds[ally.id] = companion
                }
              }
              mind.record.eat(at: chosen.point, time: time, hunted: true); finish(&mind, time: time)
            }
          case .drink:
            if actor.remoteWater || nearWater(.init(actor.position), block: block) { mind.record.drink(seconds: dt, at: chosen.point, time: time) }
            else { finish(&mind, time: time) }
            if mind.record.thirst <= 0.1 { finish(&mind, time: time) }
          case .sleep, .returnHome:
            if actor.colossal || !weather.wet || covered(at: .init(actor.position), clearance: actor.shelterClearance, block: block) {
              mind.record.sleep(seconds: dt)
              if chosen.goal == .returnHome { mind.record.goal = .sleep }
            }
            if !night && mind.record.fatigue < 0.1 { finish(&mind, time: time) }
          case .shelter:
            if covered(at: .init(actor.position), clearance: actor.shelterClearance, block: block) {
              mind.record.memory.remember(.foundShelter, "Safe cover from precipitation", at: chosen.point, time: time, importance: 0.8)
              mind.record.sleep(seconds: dt * 0.5)
            } else { finish(&mind, time: time) }
            if !weather.wet { finish(&mind, time: time) }
          case .migrate:
            mind.record.home = actor.position; mind.record.lastMigration = time
            mind.record.memory.remember(.migrated, "Moved my habitual resting place toward resources", at: chosen.point, time: time, importance: 0.9)
            finish(&mind, time: time)
          case .socialize:
            if mind.working >= 2, let partner = chosen.partnerID,
              let other = actors.first(where: { $0.id == partner }), simd_distance(other.position, actor.position) < 5 {
              let remainingNeed = max(0, (mind.record.social?.need ?? 0) - 0.55)
              mind.record.social?.need = remainingNeed
              mind.record.social?.bond(with: partner, family: actor.juvenile || other.juvenile, time: time, reward: 0.08)
              mind.record.memory.remember(.socialized, "Spent time with a familiar group companion", other: partner, time: time, importance: 0.6)
              if var companion = minds[partner] {
                let remainingNeed = max(0, (companion.record.social?.need ?? 0) - 0.3)
                companion.record.social?.need = remainingNeed
                companion.record.social?.bond(with: actor.id, family: actor.juvenile || other.juvenile, time: time, reward: 0.08)
                companion.record.memory.remember(.socialized, "A group companion kept me company", other: actor.id, time: time, importance: 0.6)
                minds[partner] = companion
              }
              finish(&mind, time: time)
            }
          case .protectYoung:
            if mind.working >= 2, let young = chosen.partnerID {
              mind.record.memory.remember(.helped, "Stood between danger and a dependent youngster", other: young, time: time, importance: 0.8)
              mind.record.social?.bond(with: young, family: true, time: time, reward: 0.05)
              finish(&mind, time: time)
            }
          case .greetPlayer:
            if mind.working >= 2 {
              mind.record.memory.remember(.metPlayer, "Greeted the player with a wagging tail", at: .init(player), time: time, importance: 0.5)
              finish(&mind, time: time)
            }
          case .explore, .patrol, .rejoinGroup, .sniff: if mind.working > 2 { finish(&mind, time: time) }
          // Begging earns attention, not food. Only inventory feeding or an
          // actual forage callback can satisfy hunger or build a feeding bond.
          case .beg: break
          default: break
          }
        } else { mind.working = 0 }
      }
      mind.previous = actor.position
      if mind.chosen == nil && !mind.options.isEmpty {
        let goal = mind.record.localChoice(available: Set(mind.options.values.map(\.goal)), night: night,
          raining: weather.wet, hungryPredator: actor.predator)
        // One initial/local action while Jev is unavailable; Jev may replace it
        // as soon as its bounded, asynchronous decision is ready.
        mind.chosen = mind.options.values.first { $0.goal == goal }; mind.record.goal = goal
      }
      if (mind.stuck > 3 || (mind.record.hunger > 0.85 && !mind.options.values.contains(where: { [.forage, .hunt].contains($0.goal) }))
        || (weather.wet && mind.options["shelter"] == nil)), time - mind.record.lastPlan > 180 {
        considerPlan(actor: actor, mind: mind, weather: weather, time: time)
      }
      minds[actor.id] = mind
    }
    // Provider completions only enqueue plans. Applying them inside the step
    // makes rejection/rollback safe even if a response arrives before its ack.
    for (id, (plan, submitted)) in pendingPlans {
      guard var latest = minds[id] else { continue }
      latest.record.plan = plan; latest.record.lastPlan = submitted
      latest.nextChoice = time; latest.revision += 1; minds[id] = latest
    }
    pendingPlans.removeAll(keepingCapacity: true)
    applyPending(time: time)
    decide(time: time, night: night, raining: weather.wet)
    if saved.count > 1_024 { saved = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }) }
  }
  private func finish(_ mind: inout Mind, time: Double) {
    mind.chosen = nil; mind.working = 0; mind.nextChoice = time; mind.nextSense = time; mind.revision += 1
  }
  private func sameIntent(_ a: AnimalDecisionOption, _ b: AnimalDecisionOption) -> Bool {
    guard a.goal == b.goal, a.preyID == b.preyID, a.plant == b.plant, a.partnerID == b.partnerID else { return false }
    return [.hunt, .joinHunt, .follow, .beg, .greetPlayer, .flee, .rejoinGroup, .socialize, .protectYoung].contains(a.goal) || a.point == b.point
  }
  private func nearWater(_ p: BlockPosition, block: (BlockPosition) -> Block) -> Bool {
    for d in VoxelMesher.offsets + [.init(0, 0, 0)] where block(p + d) == .water { return true }
    return false
  }
  private func covered(at p: BlockPosition, clearance: Int = 3, block: (BlockPosition) -> Block) -> Bool {
    (clearance...(clearance + 11)).contains { block(p + .init(0, $0, 0)).isSolid }
  }
  /// Guarding has a physical consequence: a predator abandons a meal when
  /// sufficiently strong defenders have actually reached that youngster.
  private func protected(_ prey: FaunaSnapshot, against hunter: FaunaSnapshot, among actors: [FaunaSnapshot]) -> Bool {
    guard let group = prey.groupID else { return false }
    let strength = actors.filter { $0.groupID == group && !$0.juvenile && $0.dinosaur?.defensive == true
      && minds[$0.id]?.chosen?.goal == .protectYoung
      && simd_distance_squared($0.position, prey.position) < 8 * 8
    }.reduce(Float(0)) { $0 + $1.strength }
    return strength >= hunter.strength * 0.75
  }
  private func perceive(actor: FaunaSnapshot, mind: Mind, others: [FaunaSnapshot], player: SIMD3<Float>,
    offering: AnimalFood?, weather: WorldWeather, night: Bool, time: Double, loaded: Set<ChunkCoordinate>,
    plants: [PlantInstance], block: (BlockPosition) -> Block) -> [String: AnimalDecisionOption] {
    var result = actor.distantOptions
    let kind = actor.kind
    if kind == .hayHay && !actor.following {
      return ["home": .init(.returnHome,at:.init(actor.home),description:"Wait peacefully in my castle sanctuary for someone to find and befriend me.")]
    }
    func safe(_ p: BlockPosition) -> Block { loaded.contains(p.chunk) ? block(p) : .stone }
    func walkable(_ p: BlockPosition) -> Bool {
      if kind?.aquatic == true { return safe(p) == .water }
      if (kind?.canSwim == true || actor.dinosaur?.canSwim == true) && safe(p) == .water { return true }
      // Candidate search is coarse; the motor checks full body clearance before moving.
      let height = actor.dinosaur == nil ? 2 : actor.shelterClearance
      return safe(p + .init(0, -1, 0)).isSolid && (0..<height).allSatisfy { safe(p + .init(0, $0, 0)) == .air }
    }
    func failed(_ p: BlockPosition) -> Bool {
      mind.record.memory.experiences.contains { $0.kind == .failedRoute && $0.point == p && time - $0.time < 120 }
    }
    let interest = actor.following || offering.map { kind?.foods.contains($0) == true } == true
    let mates = actor.groupID.map { group in others.filter { $0.id != actor.id && $0.groupID == group } } ?? []
    let warning = mind.record.memory.experiences.first { $0.kind == .danger && time - $0.time < 10 }
    let predator = others.first { hunter in
      (hunter.preysOn(actor) || mates.contains { $0.juvenile && hunter.preysOn($0) })
        && (simd_distance_squared(hunter.position, actor.position) < 14 * 14 || hunter.id == warning?.other)
    }
    let afraidOfPlayer = kind?.pet != true && !actor.predator && actor.strength < 6 && !actor.trusting && !interest
      && simd_distance_squared(player, actor.position) < (kind?.shy == true ? 30 : 7)
    let young = mates.filter { $0.juvenile }.min { simd_distance_squared($0.position, actor.position) < simd_distance_squared($1.position, actor.position) }
    let alliedStrength = mates.filter { !$0.juvenile && simd_distance_squared($0.position, actor.position) < 12 * 12 }.reduce(actor.strength) { $0 + $1.strength * 0.4 }
    let visitorNearYoung = actor.dinosaur?.defensive == true && young.map {
      simd_distance_squared($0.position, player) < 6 * 6 && simd_distance_squared($0.position, actor.position) < 20 * 20
    } == true
    let canGuard = !actor.juvenile && actor.dinosaur?.defensive == true && young != nil
      && (predator.map { alliedStrength >= $0.strength * 0.75 } ?? visitorNearYoung)
    if let threat = predator?.position ?? (afraidOfPlayer || visitorNearYoung ? player : nil) {
      let away = actor.position - threat + [0.01, 0, 0.01]
      let p = BlockPosition(actor.position + simd_normalize(away) * 8)
      if canGuard, let young {
        let direction = simd_normalize(threat - young.position + [0.01, 0, 0.01])
        let p = BlockPosition(young.position + direction * 3)
        if loaded.contains(p.chunk), walkable(p) {
          result["protect_young"] = .init(.protectYoung, at: p, partnerID: young.id,
            description: "My strength plus nearby allies can deter the threat. Stand between it and youngster \(young.id), remember helping, and reassess instead of pursuing far away.")
        }
      }
      if loaded.contains(p.chunk), result["protect_young"] == nil {
        result["flee"] = .init(.flee, at: p, description: "Escape a nearby threat; warn group mates and prioritize safety over food.")
      }
    }
    if let dino = actor.dinosaur, !actor.colossal {
      let adult = mates.filter { !$0.juvenile }.min { $0.id < $1.id }
      let companion = adult ?? mates.min { $0.id < $1.id }
      if let companion, actor.juvenile || dino.socialStyle != .solitary {
        let distance = simd_distance(companion.position, actor.position)
        let side: Float = actor.id < companion.id ? -1 : 1
        let offset: SIMD3<Float> = [side * 2, 0, side * 1.2]
        let destination = BlockPosition(companion.position + offset)
        if distance > (actor.juvenile ? 5 : 11), loaded.contains(destination.chunk), walkable(destination) {
          result["rejoin_group"] = .init(.rejoinGroup, at: destination, partnerID: companion.id,
            description: "Rejoin my familiar group or parent, leaving room around them. Follow their movement, but urgent thirst, hunger or danger comes first.")
        } else if distance < 10 && (mind.record.social?.need ?? 0) > 0.2 && walkable(destination) {
          result["socialize"] = .init(.socialize, at: destination, partnerID: companion.id,
            description: "Spend time beside familiar companion \(companion.id); ease social need, strengthen our bond and remember the encounter.")
        }
      }
      if dino.socialStyle == .looseHuntingGroup && !actor.juvenile {
        if let mate = mates.first(where: { minds[$0.id]?.chosen?.goal == .hunt }),
          let preyID = minds[mate.id]?.chosen?.preyID,
          let prey = others.first(where: { $0.id == preyID && actor.preysOn($0)
            && canSpawn(id: $0.id, time: time) && !protected($0, against: actor, among: others) }) {
          let approach = BlockPosition(prey.position + [actor.id % 2 == 0 ? -1.3 : 1.3, 0, 0])
          if loaded.contains(approach.chunk), walkable(approach) {
            result["join_hunt"] = .init(.joinHunt, at: approach, preyID: prey.id, partnerID: mate.id,
              description: "Opportunistically join companion \(mate.id)'s live hunt from a different approach. Contact is required; pursue small suitable prey, never a family member.")
          }
        }
      }
    }
    if kind?.pet == true {
      let point = BlockPosition(player)
      if simd_distance_squared(player, actor.position) < 24 * 24 && abs(player.y - actor.position.y) < 4,
        walkable(point), !failed(point) {
        if offering.map({ kind?.foods.contains($0) == true }) == true {
          result["beg"] = .init(.beg, at: point, description: kind == .hayHay ? "A favorite plant! Gently approach my friend and tilt my ears. Wait for actual feeding." : "A snack! Forget a minor errand, eagerly approach the player's berries, look up and wag. Wait for real feeding; begging itself gives no food.")
        }
        if actor.following {
          result["follow"] = .init(.follow, at: point, description: "Keep my food-giving friend company nearby. Remember our friendship, leave personal space, and still take care of water, shelter and sleep.")
        } else if !mind.record.memory.experiences.contains(where: { $0.kind == .metPlayer && time - $0.time < 45 }) {
          result["greet"] = .init(.greetPlayer, at: point, description: "A person! Happily approach this stranger and wag; I am friendly even before they feed me.")
        }
      }
    } else if interest && simd_distance_squared(player, actor.position) < 24 * 24 {
      result["follow"] = .init(.follow, at: .init(player), description: "Follow the friendly player offering suitable food; keep a comfortable distance.")
    }
    if let food = plants.filter({ (actor.dinosaur?.forages($0.kind) ?? kind?.forages($0.kind) ?? false) && !failed($0.position) })
      .min(by: { simd_distance_squared($0.center, actor.position) < simd_distance_squared($1.center, actor.position) }) {
      result["forage"] = .init(.forage, at: food.position, plant: food.kind, description: "Eat nearby \(food.kind.name) to satisfy hunger; this plant is actually consumed.")
    }
    func preyDistance(_ prey: FaunaSnapshot) -> Float {
      simd_distance_squared(prey.position, actor.position) * (actor.dinosaur == .spinosaurus && prey.kind == .fish ? 0.35 : 1)
    }
    if let target = others.filter({ candidate in actor.preysOn(candidate) && canSpawn(id: candidate.id, time: time)
      && !protected(candidate, against: actor, among: others)
      && !mind.record.memory.experiences.contains(where: { $0.kind == .failedRoute && $0.other == candidate.id && time - $0.time < 120 })
      && simd_distance_squared(candidate.position, actor.position) < (actor.colossal ? 100 * 100 : 24 * 24) })
      .min(by: { preyDistance($0) < preyDistance($1) }) {
      result["hunt"] = .init(.hunt, at: .init(target.position), preyID: target.id,
        description: "Hunt a nearby \(target.species) suited to my size and diet. Reach actual contact for a meal; prey can flee, defend or call companions.")
    }
    // The giant supplies a bounded, verified terrain survey instead of making
    // ordinary animal sensors scan its skyscraper-sized footprint every frame.
    if actor.colossal { return result }
    let center = BlockPosition(actor.position)
    var water: BlockPosition?, shelter: BlockPosition?, explore: BlockPosition?
    // Recalled locations are tested first, then a bounded local search.
    var points = mind.record.memory.recall(time: time, relevant: [.foundWater, .foundShelter], limit: 8).compactMap(\.point)
    for radius in [3, 7, 12] { for step in 0..<12 {
      let angle = Float(step) * .pi / 6
      let x = center.x + Int(cos(angle) * Float(radius)), z = center.z + Int(sin(angle) * Float(radius))
      for y in stride(from: center.y + 2, through: center.y - 3, by: -1) {
        let p = BlockPosition(x, y, z)
        if loaded.contains(p.chunk) && walkable(p) { points.append(p); break }
      }
    } }
    for p in points where loaded.contains(p.chunk) && !failed(p) && walkable(p) {
      if water == nil && nearWater(p, block: safe) { water = p }
      if shelter == nil && covered(at: p, clearance: actor.shelterClearance, block: safe) { shelter = p }
      if explore == nil || simd_distance_squared(p.center, actor.position) > simd_distance_squared(explore!.center, actor.position) { explore = p }
    }
    if kind == .dog {
      // A nearby smell occasionally distracts a companion. Unbefriended dogs
      // investigate close to their town home instead of wandering indefinitely.
      let distracted = !actor.following || (Int(time / 4) + Int(actor.id % 8)) % 8 == 0
      if distracted, let smell = points.first(where: {
        simd_distance_squared($0.center, actor.position) < 5 * 5 && loaded.contains($0.chunk) && walkable($0) && !failed($0)
          && (actor.following || simd_distance_squared($0.center, actor.home) < 20 * 20)
      }) {
        result["sniff"] = .init(.sniff, at: smell, description: "Ooh, an interesting smell! Take a short sniffing detour, nose down, then look around with a puzzled head tilt. No food unless an actual edible plant is found.")
      }
      if !actor.following, let destination = explore, simd_distance_squared(destination.center, actor.home) > 20 * 20 { explore = nil }
    }
    if let water, kind?.aquatic != true { result["drink"] = .init(.drink, at: water, description: "Reach a verified water edge and drink to relieve thirst.") }
    if kind == .frog, let water { result["forage"] = .init(.forage, at: water, description: "Catch small ambient insects beside wetland plants and water.") }
    if let shelter, kind?.aquatic != true { result["shelter"] = .init(.shelter, at: shelter, description: "Seek verified overhead cover from rain or snow. Rest until it clears.") }
    let home = BlockPosition(mind.record.home)
    if loaded.contains(home.chunk) && walkable(home) && !failed(home) {
      let atHome = simd_distance_squared(actor.position, mind.record.home) < 5
      result["home"] = .init(atHome ? .sleep : .returnHome, at: home, description: "Return to the same habitual den or sleeping place and rest, especially at night.")
    }
    if let dino = actor.dinosaur, dino.socialStyle == .solitary || dino == .trex,
      let stranger = others.filter({ $0.id != actor.id && $0.dinosaur == dino && !$0.juvenile
        && $0.groupID != actor.groupID && simd_distance_squared($0.position, actor.position) < 12 * 12 })
        .min(by: { simd_distance_squared($0.position, actor.position) < simd_distance_squared($1.position, actor.position) }) {
      // Choose a real traversable point that opens distance from an unrelated
      // adult instead of advertising territoriality only in the model prompt.
      if let space = points.filter({ walkable($0) && !failed($0)
        && simd_distance_squared($0.center, stranger.position) > simd_distance_squared(actor.position, stranger.position) + 16 })
        .max(by: { simd_distance_squared($0.center, stranger.position) < simd_distance_squared($1.center, stranger.position) }) {
        explore = space
      }
    }
    if let explore {
      if actor.dinosaur?.socialStyle == .solitary || actor.dinosaur == .trex {
        result["patrol"] = .init(.patrol, at: explore, description: "Patrol a nearby part of my territory and check resources; maintain personal space and return to my familiar resting site.")
      }
      result["explore"] = .init(.explore, at: explore, description: "Search nearby loaded habitat for food, drinking water and shelter. Remember successful places.")
      if (kind?.migratory == true || actor.dinosaur?.socialStyle == .herd) && time - mind.record.lastMigration > WorldEnvironment.dayDuration / 2,
        (mind.record.hunger > 0.65 || Int(time / WorldEnvironment.dayDuration) % 3 == 2),
        simd_distance_squared(explore.center, mind.record.home) > 12 * 12 {
        result["migrate"] = .init(.migrate, at: explore, description: "Migrate toward a new feeding range and establish a new resting place after arrival.")
      }
    }
    if mind.record.hunger > 0.65,
      let remembered = mind.record.memory.recall(time: time, relevant: [.foundFood, .hunted]).first(where: {
        [.foundFood, .hunted].contains($0.kind) && time - $0.time < WorldEnvironment.dayDuration
          && $0.point.map { loaded.contains($0.chunk) && walkable($0) && !failed($0)
            && simd_distance_squared($0.center, actor.position) > 8 * 8 } == true
      })?.point {
      result["explore"] = .init(.explore, at: remembered, description: "Revisit a remembered feeding ground to check for nearby food. The old memory does not guarantee food is still there.")
    }
    return result
  }
  private func applyPending(time: Double) {
    guard let (response, choices, revisions, submitted) = pending else { return }
    pending = nil
    guard CACurrentMediaTime() - submitted < 8 else { return }
    for (id, options) in choices {
      guard var mind = minds[id], mind.revision == revisions[id], let answer = response.answers["action_\(id)"],
        answer.accepts(options: Set(options.keys)), let selected = options[answer.choice],
        let current = mind.options.values.first(where: { sameIntent($0, selected) }) else { continue }
      if mind.chosen.map({ !sameIntent($0, current) }) ?? true { mind.working = 0 }
      mind.chosen = current; mind.record.goal = current.goal
      mind.nextChoice = time + 15; mind.revision += 1; minds[id] = mind
    }
    status = "Jev choosing animal goals"
  }
  private func decide(time: Double, night: Bool, raining: Bool) {
    let now = CACurrentMediaTime()
    guard now >= nextBatch, task == nil else { return }
    let due = minds.values.filter { $0.nextChoice <= time && !$0.options.isEmpty && $0.record.absentUntil <= time }
      .sorted { $0.nextChoice < $1.nextChoice }.prefix(5)
    guard !due.isEmpty else { return }
    nextBatch = now + 5
    guard let client, budget.begin(at: now) else {
      for var mind in due {
        let goal = mind.record.localChoice(available: Set(mind.options.values.map(\.goal)), night: night, raining: raining,
          hungryPredator: mind.options["hunt"] != nil)
        mind.chosen = mind.options.values.first { $0.goal == goal }; mind.record.goal = goal
        mind.nextChoice = time + 5; minds[mind.record.id] = mind
      }
      return
    }
    let choices = Dictionary(uniqueKeysWithValues: due.map { ($0.record.id, $0.options) })
    let revisions = Dictionary(uniqueKeysWithValues: due.map { ($0.record.id, $0.revision) })
    let request = JevAnimalRequest(records: due.map(\.record), options: choices, night: night, raining: raining, time: time)
    let generation = epoch
    task = Task { [weak self] in
      do {
        let response = try await client.decide(request)
        guard let self, self.epoch == generation, !Task.isCancelled else { return }
        self.budget.complete(at: CACurrentMediaTime()); self.task = nil
        self.pending = (response, choices, revisions, now)
      } catch {
        guard let self, self.epoch == generation else { return }
        self.budget.fail(at: CACurrentMediaTime()); self.task = nil
        self.status = "Local animal instincts · Jev unavailable"
      }
    }
  }
  private func considerPlan(actor: FaunaSnapshot, mind: Mind, weather: WorldWeather, time: Double) {
    let context = ReasoningSituation(actor: actor.dinosaur?.name ?? actor.species, kind: "animal",
      problem: "Usual habitat or resources are not meeting my needs", facts: ["Hunger \(mind.record.hunger), thirst \(mind.record.thirst), fatigue \(mind.record.fatigue)",
        "Precipitation \(weather.precipitation); migratory \(actor.kind?.migratory == true)",
        "Species behavior: \(mind.record.behaviorDescription ?? "Natural wildlife")",
        actor.kind == .hayHay ? HayHay.personality : actor.kind == .dog ? "Simple, friendly, food obsessed. Never hunt, fight, speak or craft. Only short immediate goals; accept petting and follow a food-giving friend." : "Use natural species goals.",
        "Group need: \(mind.record.social?.need ?? 0)", "Available goals: \(mind.options.keys.sorted().joined(separator: ", "))"],
      memories: mind.record.memory.recall(time: time).map(\.detail), availableActions: mind.options.values.map(\.description))
    let generation = epoch
    planner?.request(context) { [weak self] plan in
      let allowed: Set<AgencyPriority> = [.safety, .food, .water, .shelter, .sleep, .migrate, .socialize]
      guard let self, self.epoch == generation, self.minds[actor.id] != nil, plan.priorities.allSatisfy(allowed.contains) else { return }
      self.pendingPlans[actor.id] = (plan, time)
    }
  }
}
