import Foundation
import simd
import WorldCore

struct ColossalAgent: Sendable {
  var state: ColossalRexState
  var options: [String: AnimalDecisionOption] = [:]
  var remoteWater = false
  var surveyed: Double = -.infinity
  var trample = ColossalTrample()
  var lastTrampledPosition:SIMD3<Float>?
}
struct DinosaurPopulation: Sendable {
  var families: [ChunkCoordinate: [RexState]] = [:]
  var giant: ColossalAgent?
  var eggs: [DinosaurEgg] = []
  var snapshots: [FaunaSnapshot] {
    var result = families.values.flatMap { $0 }.map {
      FaunaSnapshot(id: $0.id, species: $0.kind.rawValue, kind: nil, position: $0.position,
        home: $0.home, groupID: $0.groupID, juvenile: $0.baby)
    }
    if let giant {
      result.append(.init(id: giant.state.site.id, species: "colossal_trex", kind: nil,
        position: giant.state.position, home: giant.state.site.position,
        groupID:giant.state.site.id,distantOptions: giant.options, remoteWater: giant.remoteWater))
    }
    return result
  }
}
struct CreatureStep: Sendable {
  var wildlife: [AnimalState] = []
  var dinosaurs = DinosaurPopulation()
  var bites: [(SIMD3<Float>, String)] = []
}

/// Population discovery, collision probes, dog paths and giant terrain surveys
/// share the simulation executor. Renderers only create rigs and interpolate.
@SimulationActor final class CreatureSimulation {
  private var attemptedAnimals = Set<ChunkCoordinate>()
  private var attemptedDinosaurs = Set<ChunkCoordinate>()
  private var checkedRegions = Set<ChunkCoordinate>()
  private var giantSites: [ChunkCoordinate: ColossalRexSite] = [:]
  private var lastAnimalStream: Double = -.infinity
  private var lastDinosaurStream: Double = -.infinity
  private var lastGiantStream: Double = -.infinity
  func checkpoint() -> @SimulationActor () -> Void {
    let a = attemptedAnimals, d = attemptedDinosaurs, r = checkedRegions, sites = giantSites
    let ta = lastAnimalStream, td = lastDinosaurStream, tg = lastGiantStream
    return {
      self.attemptedAnimals = a; self.attemptedDinosaurs = d; self.checkedRegions = r; self.giantSites = sites
      self.lastAnimalStream = ta; self.lastDinosaurStream = td; self.lastGiantStream = tg
    }
  }
  func clear() {
    attemptedAnimals = []; attemptedDinosaurs = []; checkedRegions = []; giantSites = [:]
    lastAnimalStream = -.infinity; lastDinosaurStream = -.infinity; lastGiantStream = -.infinity
  }
  func step(_ frame: LifeFrame, world: LifeStagingWorld, site: Settlement?, life: FaunaSimulation) -> CreatureStep {
    let time = frame.environment.elapsed, player = frame.player, terrain = frame.world.terrain
    let loaded = frame.world.loaded, center = BlockPosition(player).chunk
    var result = CreatureStep(wildlife: frame.wildlife.filter { life.canSpawn(id: $0.id, time: time) }, dinosaurs: frame.dinosaurs)
    let companions=Set(frame.hayHayIDs)
    result.wildlife.removeAll { $0.id == frame.hiddenCastleHayHay || ($0.collectedCompanion && !companions.contains($0.id)) }
    var occupied=result.wildlife.filter { companions.contains($0.id) }.map(\.position)
    for (index,id) in frame.hayHayIDs.enumerated() where !result.wildlife.contains(where:{$0.id == id}) {
      let point=frame.companionCarrier?.passenger(ordinal:index).position
        ?? HayHayCollection.landing(near:player,ordinal:index,occupied:occupied,block:world.block)
      if let point {
        var pet=HayHayCollection.companion(id:id,at:point)
        if let carrier=frame.companionCarrier { pet.board(carrier,ordinal:index) }
        result.wildlife.append(pet); occupied.append(point)
      }
      break // Bound failed searches too, even when the player is airborne.
    }
    let nearby = loaded.filter { $0.distanceSquared(to: center) <= 20 }
      .sorted { $0.distanceSquared(to: center) < $1.distanceSquared(to: center) }
    if time - lastAnimalStream > 0.15 {
      lastAnimalStream = time
      attemptedAnimals = attemptedAnimals.filter { loaded.contains($0) && $0.distanceSquared(to: center) <= 16 }
      result.wildlife.removeAll { !companions.contains($0.id) && (!loaded.contains(BlockPosition($0.position).chunk) || simd_distance_squared($0.position, player) > 72 * 72) }
      if result.wildlife.count < 28 {
        var spawned: AnimalState?
        if let castle = terrain.landmarks.first(where: { $0.kind == .castle }),
          HayHay.id(in:castle) != frame.hiddenCastleHayHay,
          !result.wildlife.contains(where: { $0.id == HayHay.id(in:castle) }),
          simd_distance_squared(life.restoredPosition(id:HayHay.id(in:castle)) ?? castle.petHome,player) < 72*72,
          life.canSpawn(id:HayHay.id(in:castle),time:time) {
          if let restored = life.restoredPosition(id:HayHay.id(in:castle)), loaded.contains(BlockPosition(restored).chunk),
            AnimalKind.hayHay.canStand(at:restored,juvenile:false,block:world.block) {
            spawned = HayHay.spawn(in:castle,position:restored,block:world.block)
          } else { spawned = HayHay.spawn(in:castle,block:world.block) }
        }
        if spawned == nil, let site, !result.wildlife.contains(where: { $0.id == TownDog.id(in: site) }),
          let dog = TownDog.spawn(in: site, block: world.block), simd_distance_squared(dog.position, player) < 72 * 72,
          life.canSpawn(id: dog.id, time: time) { spawned = dog }
        if spawned == nil {
          for coordinate in nearby where coordinate.distanceSquared(to: center) <= 10 && !attemptedAnimals.contains(coordinate) {
            attemptedAnimals.insert(coordinate)
            if let state = AnimalState.spawn(in: coordinate, generator: terrain, knownKind: life.knownKind, block: world.block),
              !result.wildlife.contains(where: { $0.id == state.id }), life.canSpawn(id: state.id, time: time) { spawned = state; break }
          }
        }
        if var state = spawned {
          if let point = life.restoredPosition(id: state.id), loaded.contains(BlockPosition(point).chunk),
            simd_distance_squared(point, player) < 72 * 72,
            state.kind.aquatic ? world.block(.init(point)) == .water : state.kind.canStand(at: point, juvenile: state.baby, block: world.block) {
            state.position = point
          }
          result.wildlife.append(state)
        }
      }
    }
    for key in Array(result.dinosaurs.families.keys) {
      result.dinosaurs.families[key]?.removeAll { !life.canSpawn(id: $0.id, time: time) }
      if result.dinosaurs.families[key]?.isEmpty == true { result.dinosaurs.families[key] = nil }
    }
    if time - lastDinosaurStream > 0.75 {
      lastDinosaurStream = time
      attemptedDinosaurs = attemptedDinosaurs.filter { loaded.contains($0) && $0.distanceSquared(to: center) <= 49 }
      result.dinosaurs.families = result.dinosaurs.families.filter { _, family in
        family.contains { loaded.contains(BlockPosition($0.position).chunk) && simd_distance_squared($0.position, player) <= 96 * 96 }
      }
      if result.dinosaurs.families.count < 4 {
        for coordinate in nearby where result.dinosaurs.families[coordinate] == nil && !attemptedDinosaurs.contains(coordinate) {
          attemptedDinosaurs.insert(coordinate)
          let states = RexState.herd(in: coordinate, terrain: terrain, knownKind: life.knownDinosaur, block: world.block)
            .filter { life.canSpawn(id: $0.id, time: time) }
          if !states.isEmpty {
            let capacity = max(0, 16 - result.dinosaurs.families.values.reduce(0) { $0 + $1.count })
            result.dinosaurs.families[coordinate] = states.prefix(capacity).map { initial in
              var state = initial
              if let point = life.restoredPosition(id: state.id), loaded.contains(BlockPosition(point).chunk),
                simd_distance_squared(point, player) < 96 * 96 {
                let cell = BlockPosition(point)
                if (state.kind.canSwim && world.block(cell) == .water) || (world.block(cell + .init(0,-1,0)).isSolid
                  && RexState.clear(at: point, scale: state.scale, kind: state.kind, block: world.block)) { state.position = point }
              }
              return state
            }
            break
          }
        }
      }
    }
    let dt = min(0.1, frame.seconds)
    var relocations = 0
    for i in result.wildlife.indices {
      if let ordinal=frame.hayHayIDs.firstIndex(of:result.wildlife[i].id) {
        var pet=result.wildlife[i]
        if let carrier=frame.companionCarrier {
          pet.board(carrier,ordinal:ordinal)
          result.wildlife[i]=pet
          continue // No walking, pathfinding or shore teleport probes aboard.
        }
        if let passenger=pet.passenger {
          // Keep a companion aboard if the player exits into deep water or
          // blocked terrain. Disembark only onto a clear, separated dry spot.
          guard relocations<2 else { continue }
          relocations += 1
          let others=result.wildlife.filter { $0.id != pet.id && companions.contains($0.id) && $0.passenger == nil }.map(\.position)
          guard let landing=HayHayCollection.landing(near:player,ordinal:ordinal,occupied:others,
            occupiedSpace:{ point in
              passenger.carrier.obstructsCompanion(at:point) || frame.traffic.contains { car in
                CompanionCarrier(id:car.id,kind:.car(car.kind),position:car.position,heading:car.heading).obstructsCompanion(at:point)
              }
            },block:world.block) else { continue }
          pet.passenger=nil; pet.position=landing; pet.dogMovement = .init()
        }
        let distance=simd_distance_squared(pet.position,player)
        if relocations < 2 && (distance > 32*32 || abs(pet.position.y-player.y)>10 || !loaded.contains(BlockPosition(pet.position).chunk)) {
          relocations += 1
          let others=result.wildlife.filter { $0.id != pet.id && companions.contains($0.id) }.map(\.position)
          if let landing=HayHayCollection.landing(near:player,ordinal:ordinal,occupied:others,block:world.block) {
            pet.position=landing; pet.dogMovement = .init()
          }
        }
        let angle=Float(ordinal)*2.4
        let target=player+[cos(angle)*(3+Float(ordinal/6)),0,sin(angle)*(3+Float(ordinal/6))]
        let goal=AnimalDecisionOption(.follow,at:.init(target),description:"Stay beside my player friend")
        pet.bond.befriended=true
        pet.update(deltaTime:dt,time:time,player:player,directive:goal,block:world.block)
        result.wildlife[i]=pet
        continue
      }
      if let ride=frame.mount,ride.id == result.wildlife[i].id { result.wildlife[i].applyRider(ride,seconds:dt); continue }
      var pet=result.wildlife[i]
      var directive=life.directive(id:pet.id)
      if pet.kind == .dog && directive?.goal != .flee && directive?.goal != .drink {
        let weather=WorldWeather.sample(seed:terrain.seed,time:time,style:terrain.style)
        directive=pet.doorVisit.directive(position:pet.position,player:player,time:time,
          shelter:weather.precipitation>0.25 || frame.environment.daylight<0.1,
          offeredFood:frame.offering != nil && simd_distance_squared(player,pet.position)<24*24,
          doors:frame.world.doors,id:pet.id) ?? directive
      }
      let isDog=pet.kind == .dog
      pet.update(deltaTime:dt,time:time,player:player,offering:frame.offering,directive:directive,block: { p in
        if isDog && frame.world.doors.contains(where:{$0.blocks(p)}) { return .wood }
        return world.block(p)
      })
      result.wildlife[i]=pet
      if world.block(.init(result.wildlife[i].position)) == .water {
        result.wildlife[i].position = FluidMotion.advected(result.wildlife[i].position,
          current:terrain.waterCurrent(at:result.wildlife[i].position,time:time),seconds:dt,block:world.block)
      }
    }
    for key in Array(result.dinosaurs.families.keys) {
      guard var family = result.dinosaurs.families[key] else { continue }
      for i in family.indices {
        if let ride=frame.mount,ride.id == family[i].id { family[i].applyRider(ride,seconds:dt); continue }
        if world.block(.init(family[i].position)) == .water {
          family[i].position = FluidMotion.advected(family[i].position,
            current:terrain.waterCurrent(at:family[i].position,time:time),seconds:dt,clearance:family[i].kind.clearance.radius,block:world.block)
        }
        if family[i].update(deltaTime: min(0.05, dt), time: time, player: player,
          directive: life.directive(id: family[i].id), block: world.block) {
          result.bites.append((family[i].position + [0, family[i].kind.attackHeight * family[i].scale, 0], family[i].kind.name))
        }
      }
      result.dinosaurs.families[key] = family
    }
    let nestObserver=frame.mount?.profile.isColossal == true ? frame.mount!.position:player
    life.updateNests(parents:result.dinosaurs.families.values.flatMap { $0 },giant:result.dinosaurs.giant?.state,seconds:dt,
      player:nestObserver,loaded:loaded,block:world.block)
    let capacity = max(0,20-result.dinosaurs.families.values.reduce(0) { $0+$1.count })
    let hatched = life.hatchReadyEggs(capacity:capacity,player:nestObserver,loaded:loaded,block:world.block)
    let hatchlings = hatched + life.restoredHatchlings(time:time,player:nestObserver,loaded:loaded,block:world.block)
    var existing = Set(result.dinosaurs.families.values.flatMap { $0 }.map(\.id))
    for baby in hatchlings where existing.count < 20 && !existing.contains(baby.id) {
      existing.insert(baby.id)
      result.dinosaurs.families[BlockPosition(baby.home).chunk,default:[]].append(baby)
    }
    result.dinosaurs.eggs = life.nestingRecords.flatMap { $0.brood?.eggs ?? [] }.filter {
      !$0.hatched && loaded.contains(BlockPosition($0.position).chunk) && simd_distance_squared($0.position,nestObserver) < 96*96
    }
    // Cache repeated settlement and terrain queries within this step; giant
    // probes overlap frequently and must never generate chunks on the UI actor.
    var groundCache: [SIMD2<Int>: ColossalGround] = [:]
    func ground(_ x: Float, _ z: Float) -> ColossalGround {
      let key = SIMD2(Int(floor(x)), Int(floor(z)))
      if let cached = groundCache[key] { return cached }
      let column = terrain.column(atX: key.x, z: key.y)
      let p = BlockPosition(key.x, column.height + 1, key.y)
      let depth = max(0, (column.water?.level ?? Float(column.height)) - Float(column.height))
      let sample = ColossalGround(height:Float(p.y),waterDepth:depth)
      groundCache[key] = sample; return sample
    }
    let range = Float(max(1, frame.drawRadius) * 16)
    if time - lastGiantStream > 2 {
      lastGiantStream = time
      let region = ChunkCoordinate(floorDivide(Int(floor(player.x)), by: ColossalRexSite.regionSize), floorDivide(Int(floor(player.z)), by: ColossalRexSite.regionSize))
      checkedRegions = checkedRegions.filter { $0.distanceSquared(to: region) <= 8 }
      giantSites = giantSites.filter { $0.key.distanceSquared(to: region) <= 8 }
      for dx in -1...1 { for dz in -1...1 {
        let key = ChunkCoordinate(region.x + dx, region.z + dz)
        if checkedRegions.insert(key).inserted, let site = ColossalRexSite.candidate(in: key, terrain: terrain) { giantSites[key] = site }
      } }
      // A ridden giant may be far from its seeded birthplace on reload.
      for saved in life.records where saved.species == "colossal_trex"
        && simd_distance_squared(saved.position,player)<range*range {
        let home=BlockPosition(saved.home)
        let birthRegion=ChunkCoordinate(floorDivide(home.x,by:ColossalRexSite.regionSize),floorDivide(home.z,by:ColossalRexSite.regionSize))
        if let site=ColossalRexSite.candidate(in:birthRegion,terrain:terrain),site.id == saved.id { giantSites[birthRegion]=site }
      }
      if let giant = result.dinosaurs.giant,frame.mount?.id != giant.state.site.id,
        simd_distance_squared(giant.state.position, player) > (range + 128) * (range + 128) { result.dinosaurs.giant = nil }
      if result.dinosaurs.giant == nil, let site = giantSites.values.filter({ simd_distance_squared(life.restoredPosition(id:$0.id) ?? $0.position, player) < range * range })
        .min(by: { simd_distance_squared(life.restoredPosition(id:$0.id) ?? $0.position, player) < simd_distance_squared(life.restoredPosition(id:$1.id) ?? $1.position, player) }) {
        var state = ColossalRexState(site: site)
        if let saved = life.restoredPosition(id: site.id),
          ground(saved.x, saved.z).walkable { state.position = saved }
        result.dinosaurs.giant = .init(state: state)
      }
    }
    if var giant = result.dinosaurs.giant {
      let before=giant.lastTrampledPosition ?? giant.state.position
      if let ride=frame.mount,ride.id == giant.state.site.id { giant.state.applyRider(ride,seconds:dt) }
      else { giant.state.update(deltaTime: dt, time: time, player: player, directive: life.directive(id: giant.state.site.id), ground: ground) }
      if giant.state.moving {
        giant.trample.walked(from:before,to:giant.state.position,radius:giant.state.footprint)
      }
      giant.lastTrampledPosition=giant.state.position
      let crushed=giant.trample.next(loaded:loaded,block:world.block)
      world.trample(crushed)
      if time - giant.surveyed >= 4 {
        giant.surveyed = time; giant.options = giant.state.options(time: time, ground: ground)
        let position = giant.state.position, radius = giant.state.footprint
        giant.remoteWater = [[Float(0),0],[-radius,0],[radius,0],[0,-radius],[0,radius]].contains {
          ground(position.x + $0[0], position.z + $0[1]).waterDepth > 0
        }
        if giant.remoteWater { giant.options["drink_here"] = .init(.drink, at: .init(position), description: "Drink the verified water at my feet.") }
      }
      result.dinosaurs.giant = giant
    }
    return result
  }
}
