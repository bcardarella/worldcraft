import QuartzCore
import Foundation
import simd
import WorldCore

@SimulationActor
final class SettlementSimulation {
  private struct Person: Sendable {
    var state: ResidentState
    var target: SIMD3<Float>
    var job: ResidentJob? = nil
    var route: [SIMD3<Float>] = []
    var waypoint = 0
    var nextPath: Double = 0
    var nextEncounter: Double = 0
    var blocked = false
    var waitingForPassage = false
    var socialAccepted = false
    var stalledSeconds: Float = 0
    var bestWaypointDistance: Float = .infinity
    var yieldUntil: Double = 0
    var yieldTarget: SIMD3<Float>?
    var lastBump: Double = -.infinity
  }
  private struct PendingDecisions {
    let response: JevNPCResponse
    let choices: [UInt64: [String: NPCDecisionOption]]
    let revisions: [UInt64: Int]
    let submitted: Double
  }
  private var residents: [Person] = []
  private var passageQueue = ResidentPassageQueue()
  private var doors: [BuildingDoorState] = []
  private var passageCache:[ResidentPassage]=[]
  private var passageLots=Set<SIMD2<Int>>()
  private var residentHomes: [SIMD3<Float>] = []
  private var nearbyResidentIndices: [Int] = []
  private var nextPopulationRefresh: Double = 0
  var states: [ResidentState] { residents.map(\.state) }
  var isCelebrating: Bool { celebratingArrival }
  let homesteads = HomesteadSimulation()
  private var site: Settlement?
  private var region: ChunkCoordinate?
  private var candidate: Settlement?
  private var saved: [UInt64: ResidentRecord] = [:]
  private var client: JevNPCClient?
  private var decisionTask: Task<Void, Never>?
  private var pendingDecisions: PendingDecisions?
  private var epoch = UUID()
  private var requestBudget = NPCRequestBudget()
  private var simulationAccumulator: Float = 0
  private var pendingTraffic: [UInt64: VehicleTraffic] = [:]
  private var latestTime: Double = 0
  private var lastLocalDecision: Double = -.infinity
  private var conversationUntil: Double = 0
  private var selectedResident: UInt64?
  private var welcomePort: RocketPort?
  private var welcomeUntil = Double.infinity
  private var celebratingArrival = false
  var welcomeReady: Bool { welcomePort != nil && residents.count >= 8 }
  private(set) var conversation = ""
  private(set) var prompt = ""
  private(set) var decisionStatus = "Local life · add a TypeSafe key for Jev"
  private(set) var decisionLatencyMilliseconds: Double = 0
  private(set) var acceptedDecisions = 0
  private(set) var rejectedDecisions = 0
  var logsDecisions = false
  var currentSite: Settlement? { site }
  var positions: [SIMD3<Float>] { residents.map(\.state.position) }
  var settlementName: String { site?.name ?? "" }
  var count: Int { residents.count }
  func checkpoint() -> @SimulationActor () -> Void {
    let residents = residents, saved = saved, site = site, region = region, candidate = candidate
    let residentHomes = residentHomes, nearbyResidentIndices = nearbyResidentIndices, nextPopulationRefresh = nextPopulationRefresh
    let simulationAccumulator = simulationAccumulator, latestTime = latestTime, lastLocalDecision = lastLocalDecision
    let conversation = conversation, conversationUntil = conversationUntil, selectedResident = selectedResident
    let welcomePort = welcomePort, welcomeUntil = welcomeUntil, celebratingArrival = celebratingArrival
    let acceptedDecisions = acceptedDecisions, rejectedDecisions = rejectedDecisions, pending = pendingDecisions
    let restoreHomes = homesteads.checkpoint()
    let passageQueue = passageQueue, passageCache=passageCache, passageLots=passageLots
    let pendingTraffic = pendingTraffic
    return {
      self.passageQueue = passageQueue;self.passageCache=passageCache;self.passageLots=passageLots
      self.pendingTraffic = pendingTraffic
      self.residents = residents; self.saved = saved; self.site = site; self.region = region; self.candidate = candidate
      self.residentHomes = residentHomes; self.nearbyResidentIndices = nearbyResidentIndices; self.nextPopulationRefresh = nextPopulationRefresh
      self.simulationAccumulator = simulationAccumulator; self.latestTime = latestTime; self.lastLocalDecision = lastLocalDecision
      self.conversation = conversation; self.conversationUntil = conversationUntil; self.selectedResident = selectedResident
      self.welcomePort = welcomePort; self.welcomeUntil = welcomeUntil; self.celebratingArrival = celebratingArrival
      self.acceptedDecisions = acceptedDecisions; self.rejectedDecisions = rejectedDecisions
      if self.pendingDecisions == nil { self.pendingDecisions = pending }
      restoreHomes()
    }
  }
  var records: [ResidentRecord] {
    var result = saved
    for person in residents { result[person.state.id] = person.state.record }
    return result.values.sorted { $0.id < $1.id }.prefix(2_048).map { $0 }
  }

  func restore(_ records: [ResidentRecord], homes: [HomeRecord] = []) {
    saved = Dictionary(records.filter(\.isValid).prefix(2_048).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    homesteads.restore(homes)
  }
  func configureJev(key: String?, enabled: Bool) {
    cancelDecisions()
    client = enabled ? key.flatMap { $0.isEmpty ? nil : JevNPCClient(apiKey: $0) } : nil
    decisionStatus = client != nil ? "Jev ready" : enabled ? "Local life · add a TypeSafe key for Jev" : "Local life · Jev disabled"
  }
  private func cancelDecisions() {
    epoch = UUID(); decisionTask?.cancel(); decisionTask = nil; pendingDecisions = nil; requestBudget = .init()
  }
  func suspend() {
    if decisionTask != nil || pendingDecisions != nil { cancelDecisions() }
  }

  /// Stage existing town residents before the ship descends into view. The party
  /// uses the normal resident models, identities and memories, then resumes life.
  func prepareRocketWelcome(port: RocketPort, terrain: TerrainGenerator, time: Double) -> Bool {
    let region = ChunkCoordinate(floorDivide(port.x, by: SettlementGenerator.regionSize),
      floorDivide(port.z, by: SettlementGenerator.regionSize))
    guard let town = SettlementGenerator.site(in: region, terrain: terrain), town.id == port.settlementID else { return false }
    clearActors()
    self.region = region; site = town; candidate = town
    welcomePort = port; welcomeUntil = .infinity; celebratingArrival = false; latestTime = time
    return true
  }
  func celebrateRocketArrival(planet: String, time: Double) {
    guard let port = welcomePort else { return }
    celebratingArrival = true; welcomeUntil = time + 24
    conversation = "Welcome to \(port.town), traveler! You've arrived on \(planet)!"
    conversationUntil = time + 10
    for i in residents.indices.prefix(8) {
      residents[i].state.remember("Welcomed the player arriving by rocket from another world", time: time)
      residents[i].state.record.playerTrust = min(1, residents[i].state.record.playerTrust + 0.03)
    }
  }

  func update(
    terrain: TerrainGenerator, player: SIMD3<Float>, deltaTime: Float,
    environment: WorldEnvironment, threats: [SIMD3<Float>], traffic: [VehicleTraffic] = [],
    loaded: Set<ChunkCoordinate>, doors: [BuildingDoorState] = [], block: (BlockPosition) -> Block
  ) {
    self.doors = doors
    guard deltaTime > 0 else { if decisionTask != nil || pendingDecisions != nil { suspend() }; return }
    latestTime = environment.elapsed
    if latestTime >= welcomeUntil { welcomePort = nil; celebratingArrival = false; welcomeUntil = .infinity }
    if latestTime > conversationUntil { conversation = "" }
    let region = ChunkCoordinate(
      floorDivide(BlockPosition(player).x, by: SettlementGenerator.regionSize),
      floorDivide(BlockPosition(player).z, by: SettlementGenerator.regionSize))
    if self.region != region {
      self.region = region
      candidate = SettlementGenerator.site(in: region, terrain: terrain)
    }
    let nearby = welcomePort == nil ? candidate.flatMap { $0.distanceSquared(to:player) < 45*45 ? $0 : nil } : site
    if nearby?.id != site?.id { clearActors(); site = nearby }
    guard let site else { return }
    homesteads.configure(site: site, terrain: terrain)
    if residentHomes.isEmpty {
      residentHomes = (0..<site.population).map { homesteads.homePosition(index:$0) ?? site.meetingPoint(index:$0,purpose:.home) }
    }
    if latestTime >= nextPopulationRefresh || nearbyResidentIndices.isEmpty {
      nextPopulationRefresh = latestTime + 1
      if welcomePort == nil && site.kind != .village {
        // Hysteresis is outside the 110-block presentation distance, so moving
        // across districts never removes a resident still visible nearby.
        for person in residents where simd_distance_squared(person.state.position,player) > 160*160 {
          saved[person.state.id] = person.state.record
        }
        residents.removeAll { simd_distance_squared($0.state.position,player) > 160*160 }
      }
      nearbyResidentIndices = residentHomes.indices.filter {
        site.kind == .village || (welcomePort != nil && $0 < 8)
          || (loaded.contains(BlockPosition(residentHomes[$0]).chunk) && simd_distance_squared(residentHomes[$0],player) < 145*145)
      }.sorted {
        if welcomePort != nil && ($0 < 8 || $1 < 8) { return $0 < $1 }
        if site.kind == .village { return $0 < $1 }
        let a = simd_distance_squared(residentHomes[$0],player), b = simd_distance_squared(residentHomes[$1],player)
        return a == b ? $0 < $1 : a < b
      }
    }
    if residents.count < site.activePopulationLimit {
      let active = Set(residents.map { $0.state.index })
      for i in nearbyResidentIndices.filter({ !active.contains($0) }).prefix(min(2,site.activePopulationLimit-residents.count)) {
        var state = ResidentState(index: i, site: site, saved: saved[ResidentState.id(index: i, site: site)],
          homeOverride: residentHomes[i],workplaceOverride:homesteads.workplace(index:i,site:site))
        if state.record.agency == nil { state.record.agency = .init() }
        if homesteads.damagedHome(for: state) != nil,
          !state.record.agency!.memory.experiences.contains(where: { $0.kind == .homeDamaged }) {
          let homePoint = BlockPosition(state.home)
          state.record.agency?.memory.remember(.homeDamaged, "Returned to find damage to my home", at: homePoint, time: latestTime, importance: 1)
        }
        if let port = welcomePort, i < 8 {
          let point = port.welcomePosition(i)
          guard loaded.contains(BlockPosition(point).chunk),
            let standing = ResidentNavigation.standing(at: point, block: block) else { break }
          state.position = standing
          state.choose(.greet, time: latestTime); state.nextDecision = latestTime + 60
        } else if site.habitat != .aquatic {
          let origin=state.position
          let offsets=[SIMD3<Float>.zero]+(0..<60).map {ResidentCrowd.approachOffset(index:i+$0,radius:2.5+Float($0/12)*1.8)}
          guard let standing=offsets.compactMap({offset -> SIMD3<Float>? in
            let point=origin+offset
            guard loaded.contains(BlockPosition(point).chunk),
              let feet=ResidentNavigation.walkingPosition(at:point,block:block),
              simd_distance_squared(feet,player)>2.6,
              !residents.contains(where:{abs($0.state.position.y-feet.y)<ResidentNavigation.height && simd_distance_squared($0.state.position,feet)<2.6}) else {return nil}
            return feet
          }).first else {continue}
          state.position=standing
        }
        let person = makePerson(state: state)
        residents.append(person)
      }
    }
    let safeBlock: (BlockPosition) -> Block = { loaded.contains($0.chunk) ? block($0) : .stone }
    for car in traffic {
      let previous = pendingTraffic[car.id]?.previousPosition ?? car.previousPosition
      pendingTraffic[car.id] = .init(id: car.id, position: car.position, previousPosition: previous,
        velocity: car.velocity, heading: car.heading, playerDriven: car.playerDriven)
    }
    simulationAccumulator += deltaTime
    if simulationAccumulator >= 1 / 15 {
      let dt = min(0.2, simulationAccumulator)
      simulationAccumulator = 0
      simulate(seconds: dt, player: player, site: site, terrain:terrain, threats: threats, traffic: pendingTraffic.values.sorted { $0.id < $1.id }, loaded: loaded, block: safeBlock)
      pendingTraffic.removeAll(keepingCapacity: true)
      considerDecisions(site: site, terrain: terrain, player: player, environment: environment, loaded: loaded, block: safeBlock)
    }
  }

  private func simulate(seconds: Float, player: SIMD3<Float>, site: Settlement, terrain:TerrainGenerator,
    threats: [SIMD3<Float>], traffic: [VehicleTraffic], loaded: Set<ChunkCoordinate>, block: (BlockPosition) -> Block) {
    var plans = 0
    var crowd = crowdNeighbors()
    // Repair invalid legacy spawn clumps once, placing each at a verified free
    // footprint. Ordinary movement below uses swept collision, never teleporting.
    for i in residents.indices {
      let origin=residents[i].state.position
      guard crowd.prefix(i).contains(where:{ abs($0.position.y-origin.y)<ResidentNavigation.height && simd_distance_squared($0.position,origin)<ResidentCrowd.separation*ResidentCrowd.separation }) else {continue}
      for n in 0..<48 {
        let probe=origin+ResidentCrowd.approachOffset(index:n,radius:1.6+Float(n/12)*1.6)
        guard let feet=navigable(probe,site:site,block:block),simd_distance_squared(feet,player)>2.6,
          !crowd.enumerated().contains(where:{$0.offset != i && abs($0.element.position.y-feet.y)<ResidentNavigation.height && simd_distance_squared($0.element.position,feet)<2.6}) else {continue}
        residents[i].state.position=feet;residents[i].route=[];residents[i].waypoint=0
        crowd[i]=crowdNeighbor(residents[i]);break
      }
    }
    let passages = navigationPassages(site:site,terrain:terrain)
    var requested:[UInt64:ResidentPassage]=[:],requests:[ResidentPassageQueue.Request]=[]
    for person in residents {
      let path=Array(person.route.dropFirst(person.waypoint).prefix(18))
      let passage=passages.first(where:{$0.contains(person.state.position)})
        ?? path.compactMap { point in passages.first(where:{$0.contains(point)}) }.first
      if let passage, passage.distanceSquared(to:person.state.position)<12*12 {
        requested[person.state.id]=passage
        requests.append(.init(person:person.state.id,passage:passage.id,inside:passage.contains(person.state.position)))
      }
    }
    for passage in passages where passage.contains(player,margin:0.6) {
      requests.append(.init(person:0,passage:passage.id,inside:true))
    }
    passageQueue.update(requests,time:latestTime)
    crowd.append(.init(id:0,position:player))
    func movementPosition(_ p:SIMD3<Float>) -> SIMD3<Float>? {
      guard !doors.contains(where:{ !$0.passable && $0.door.obstructs(p,fraction:$0.fraction) }) else {return nil}
      return navigable(p,site:site,block:block)
    }
    for i in residents.indices {
      guard loaded.contains(BlockPosition(residents[i].state.position).chunk) else { continue }
      defer { crowd[i] = crowdNeighbor(residents[i]) }
      var person = residents[i]
      func permittedPosition(_ point:SIMD3<Float>) -> SIMD3<Float>? {
        guard let feet=movementPosition(point) else {return nil}
        // Steering may explore detours, but it cannot sidestep a reservation.
        guard !passages.contains(where:{ $0.contains(feet,margin:ResidentNavigation.radius)
          && !$0.contains(person.state.position,margin:ResidentNavigation.radius)
          && !passageQueue.permits(person.state.id,passage:$0.id) }) else {return nil}
        return feet
      }
      if block(.init(person.state.position)) == .water {
        let current = terrain.waterCurrent(at:person.state.position,time:latestTime)
        person.state.position = FluidMotion.advected(person.state.position,current:current,seconds:seconds,block:block)
      }
      for car in traffic {
        guard let reaction = car.reaction(at: person.state.position, personID: person.state.id,
          navigable: { point in
            guard !traffic.contains(where: { $0.id != car.id && VehiclePhysics(position: $0.position, heading: $0.heading).overlapsPlayer(at: point) }),
              !crowd.contains(where: { $0.id != person.state.id && simd_distance_squared($0.position, point) < 0.75 }) else { return nil }
            return navigable(point, site: site, block: block)
          }) else { continue }
        person.yieldTarget = reaction.target; person.yieldUntil = latestTime + 1.0
        person.route = []; person.waypoint = 0; person.nextPath = latestTime + 0.5
        if reaction.bumped && car.playerDriven {
          person.state.position = reaction.target
          if latestTime - person.lastBump > 5 {
            person.lastBump = latestTime
            person.state.remember("The player's car bumped me aside", time: latestTime)
            person.state.record.playerTrust = max(0, person.state.record.playerTrust - 0.04)
            conversation = "\(person.state.name): Watch where you're driving!"; conversationUntil = latestTime + 3
          }
        }
        break
      }
      if latestTime < person.yieldUntil, let target = person.yieldTarget {
        person.state.moving = false
        if let step = ResidentCrowd.step(id: person.state.id, position: person.state.position,
          target: target, speed: 4.5, seconds: seconds, neighbors: crowd,
          navigable: permittedPosition) {
          let movement = step-person.state.position
          person.state.position = step; person.state.heading = atan2(-movement.x, -movement.z)
          person.state.gait += simd_length(movement)*3.5; person.state.moving = true
        }
        residents[i] = person
        continue
      }
      if person.state.record.agency?.cargo == nil && homesteads.damagedHome(for: person.state) == nil {
        person.state.record.agency?.helpingHome = nil
        person.state.record.agency?.plan = nil
        person.state.record.agency?.plannedIncident = nil
      }
      if let (incident, plan) = homesteads.plan(for: person.state.id) {
        if person.state.record.agency == nil { person.state.record.agency = .init() }
        person.state.record.agency?.plan = plan; person.state.record.agency?.plannedIncident = incident
        person.state.record.agency?.plannedAt = latestTime
        person.state.remember("My plan: \(plan.summary)", time: latestTime)
        person.state.reconsider(at: latestTime)
      }
      if let port = welcomePort, i < 8,
        !threats.contains(where: { simd_distance_squared($0, person.state.position) < 18 * 18 }) {
        let glance = port.center - person.state.position
        person.state.heading = atan2(-glance.x, -glance.z)
        person.state.moving = false; person.state.nextDecision = latestTime + 2
        person.target = person.state.position; person.route = []; person.waypoint = 0
        residents[i] = person
        continue
      }
      if let threat = threats.first(where: { simd_distance_squared($0, person.state.position) < 18 * 18 }) {
        if person.state.activity != .flee {
          let away = person.state.position - threat
          person.state.choose(.flee, time: latestTime)
          person.state.remember("A nearby T-rex frightened the neighborhood", time: latestTime)
          let direction = SIMD3<Float>(away.x + 0.01, 0, away.z)
          person.target = person.state.position + direction / max(0.01, simd_length(direction)) * 12
          person.route = []; person.waypoint = 0; person.nextPath = 0
          person.socialAccepted = false
          person.job = nil
        }
        person.state.nextDecision = latestTime + 3
      }
      let partner = person.state.partnerID.flatMap { id in residents.first { $0.state.id == id } }
      let engaged: Bool
      if person.job != nil { engaged = true }
      else if person.state.activity == .socialize {
        engaged = person.socialAccepted && partner?.state.partnerID == person.state.id && partner?.state.activity == .socialize
      } else if person.state.activity == .help {
        engaged = partner?.state.activity == .work
      } else { engaged = true }
      if person.socialAccepted && !engaged {
        person.socialAccepted = false
        person.state.remember("Our conversation ended as my neighbor left", time: latestTime)
        person.state.reconsider(at: latestTime)
      }
      if !person.socialAccepted, person.job == nil || person.job?.kind == .requestHelp, let other = partner {
        let target = other.state.position + ResidentCrowd.approachOffset(index: person.state.index % 12, radius: 1.6)
        if simd_distance_squared(target, person.target) > 9 { person.target = target; person.route = []; person.waypoint = 0 }
      }
      if let job = person.job, job.kind == .confront || job.kind == .warn {
        let target = player + ResidentCrowd.approachOffset(index: person.state.index % 12, radius: 1.6)
        if simd_distance_squared(target, person.target) > 4 { person.target = target; person.route = []; person.waypoint = 0 }
      }
      let arrived = simd_distance_squared(person.target, person.state.position) < 1.21
      let partnerClose = person.job?.kind == .acceptHelp || person.job?.kind == .repair ? true
        : partner.map { simd_distance_squared($0.state.position, person.state.position) < 9 } ?? true
      let visitorClose = person.state.activity != .greet || simd_distance_squared(player, person.state.position) < 64
      person.state.advanceNeeds(seconds: seconds, arrived: arrived && engaged && partnerClose && visitorClose, time: latestTime)
      person.state.moving = false
      if arrived, let job = person.job {
        let result = homesteads.execute(job, resident: &person.state, neighbors: residents.map(\.state),
          player: player, time: latestTime, block: block)
        if result.finished, job.kind == .acceptHelp,
          let ownerID = homesteads.properties.first(where: { $0.id == job.homeID })?.ownerID,
          let owner = residents.firstIndex(where: { $0.state.id == ownerID }), owner != i {
          residents[owner].state.meet(person.state.id, helping: true, time: latestTime)
        }
        if result.finished, job.kind == .declineHelp {
          let owner = homesteads.properties.first(where: { $0.id == job.homeID })?.ownerID
          for j in residents.indices where j != i && (residents[j].state.id == owner || residents[j].state.id == person.state.record.agency?.invitedBy) {
            residents[j].state.record.agency?.memory.remember(.refusedHelp,
              "\(person.state.name) could not help this time", other: person.state.id, time: latestTime, importance: 0.65)
          }
        }
        if let message = result.message {
          conversation = "\(person.state.name): \(message)"; conversationUntil = latestTime + 6
        }
        if let invited = result.invite, let j = residents.firstIndex(where: { $0.state.id == invited }) {
          if residents[j].state.record.agency == nil { residents[j].state.record.agency = .init() }
          residents[j].state.record.agency?.invitationHome = job.homeID
          residents[j].state.record.agency?.invitedBy = person.state.id
          residents[j].state.remember("\(person.state.name) asked me to help protect and rebuild a home", other: person.state.id, time: latestTime)
          residents[j].state.reconsider(at: latestTime)
        }
        if result.finished {
          person.job = nil; person.state.choose(.stroll, time: latestTime); person.state.nextDecision = latestTime + 0.2
          person.target = person.state.position; person.route = []; person.waypoint = 0
        }
        residents[i] = person
        continue
      }
      if !arrived {
        if person.waypoint >= person.route.count && latestTime >= person.nextPath && plans < 2 {
          plans += 1
          let occupied = Set<BlockPosition>() // transient people are handled by reservations/steering
          person.route = ResidentNavigation.path(from: person.state.position, to: person.target,
            swimming: site.habitat == .aquatic, avoiding: occupied, block: block)
          if person.route.isEmpty, simd_distance_squared(person.target, person.state.position) < 4,
            navigable(person.target, site: site, block: block) != nil { person.route = [person.target] }
          person.waypoint = 0; person.nextPath = latestTime + 1.5
          person.bestWaypointDistance = .infinity; person.stalledSeconds = 0
          if person.route.isEmpty && !person.blocked {
            person.state.remember("My route is blocked; I need another destination", time: latestTime)
            if let job = person.job {
              person.state.record.agency?.memory.remember(.failedRoute, "Could not reach this work location",
                at: job.target, time: latestTime, importance: 0.75)
            }
            person.state.reconsider(at: min(person.state.nextDecision, latestTime + 1))
          }
          person.blocked = person.route.isEmpty
        }
        if person.waypoint < person.route.count {
          var next = person.route[person.waypoint]
          person.waitingForPassage=false
          if let passage=requested[person.state.id],!passageQueue.permits(person.state.id,passage:passage.id) {
            person.waitingForPassage=true
            let waiting=passage.waitingPoint(for:person.state.position,index:passageQueue.waitingIndex(person.state.id,passage:passage.id))
            next=movementPosition(waiting) ?? person.state.position
          }
          let difference = next - person.state.position
          let distance = simd_length(difference)
          if distance < 0.15 && !person.waitingForPassage { person.waypoint += 1; person.bestWaypointDistance = .infinity; person.stalledSeconds = 0 }
          else {
            let speed: Float = person.state.activity == .flee ? 5 : 1.25 + Float(person.state.id % 4) * 0.1
            if let candidate = ResidentCrowd.step(id: person.state.id, position: person.state.position,
              target: next, speed: speed, seconds: seconds, neighbors: crowd,
              navigable: permittedPosition) {
              let movement = candidate - person.state.position
              person.state.position = candidate
              person.state.heading = atan2(-movement.x, -movement.z)
              person.state.moving = true; person.state.gait += simd_length(movement) * 3.5
            }
            let remaining = simd_distance(person.state.position, next)
            if remaining < person.bestWaypointDistance - 0.03 {
              person.bestWaypointDistance = remaining; person.stalledSeconds = 0
            } else { person.stalledSeconds += seconds }
            if person.stalledSeconds > 1.2 && !person.waitingForPassage {
              person.route = []; person.waypoint = 0; person.nextPath = latestTime
              person.stalledSeconds = 0; person.bestWaypointDistance = .infinity
            }
          }
        }
      } else {
        // Idle people also release old overlaps instead of permanently filling
        // doorways and meeting points with interpenetrating bodies.
        let idleTarget=passages.first(where:{$0.contains(person.state.position)})?.waitingPoint(for:person.state.position,index:0) ?? person.state.position
        if let separated = ResidentCrowd.step(id: person.state.id, position: person.state.position,
          target: idleTarget, speed: 1.1, seconds: seconds, neighbors: crowd,
          navigable: permittedPosition) {
          person.state.position = separated
        }
        if person.state.activity == .stroll && person.state.activityProgress > 2 { person.state.nextDecision = min(person.state.nextDecision, latestTime) }
        if person.state.activity == .greet && visitorClose && person.state.activityProgress > 1,
          !person.state.record.memories.contains(where: { $0.event.contains("player") && latestTime - $0.time < 25 }),
          conversation.isEmpty {
          conversation = "\(person.state.name): " + person.state.line(settlement: site.name, biome: site.setting,
            familiar: person.state.record.playerConversations > 0)
          conversationUntil = latestTime + 6
          person.state.remember("Greeted the player and welcomed them to the neighborhood", time: latestTime)
        }
        if let partner = person.state.partnerID, latestTime >= person.nextEncounter,
          person.state.activityProgress > 6,
          engaged,
          let j = residents.firstIndex(where: { $0.state.id == partner }),
          simd_distance_squared(person.state.position, residents[j].state.position) < 9 {
          let helping = person.state.activity == .help
          person.state.meet(partner, helping: helping, time: latestTime)
          residents[j].state.meet(person.state.id, helping: helping, time: latestTime)
          if helping { residents[j].state.record.workSatisfaction = min(1, residents[j].state.record.workSatisfaction + 0.15) }
          person.nextEncounter = latestTime + 20
          residents[j].nextEncounter = latestTime + 20
          let difference = residents[j].state.position - person.state.position
          person.state.heading = atan2(-difference.x, -difference.z)
          if simd_distance_squared(person.state.position, player) < 100 && conversation.isEmpty {
            conversation = "\(person.state.name): \(helping ? "Let me lend a hand with that." : "It's good to catch up, \(residents[j].state.name.components(separatedBy: " ").first!).")"
            conversationUntil = latestTime + 4
          }
        }
      }
      residents[i] = person
    }
  }

  private func options(for person: Person, site: Settlement, player: SIMD3<Float>,
    block: (BlockPosition) -> Block) -> [String: NPCDecisionOption] {
    var choices = homesteads.options(for: person.state, neighbors: residents.map(\.state), player: player, time: latestTime, block: block)
    for activity in [ResidentActivity.work, .eat, .rest, .stroll] {
      let point = destination(for: activity, resident: person.state, site: site, player: player)
      guard navigable(point, site: site, block: block) != nil else { continue }
      let description: String
      switch activity {
      case .work: description = person.state.workDescription + " at their workplace. Builds work fulfillment."
      case .eat: description = "Visit the market for a meal; relieves hunger."
      case .rest: description = "Return home and rest; relieves tiredness."
      default: description = site.habitat == .aquatic ? "Swim through the reef at different depths and visit the coral gardens." : "Take a walk through the settlement and enjoy the surroundings."
      }
      choices[activity.rawValue] = .init(activity: activity, description: description)
    }
    let nearby = residents.filter { $0.state.id != person.state.id
      && $0.state.activity != .flee && simd_distance_squared($0.state.position, person.state.position) < 30 * 30 }
      .sorted { simd_distance_squared($0.state.position, person.state.position) < simd_distance_squared($1.state.position, person.state.position) }.prefix(4)
    for other in nearby {
      let invited = other.state.partnerID == person.state.id && other.state.activity == .socialize
      choices["chat_\(other.state.id)"] = .init(activity: .socialize, partnerID: other.state.id,
        description: invited ? "Accept \(other.state.name)'s invitation and stop together for a conversation."
          : "Invite \(other.state.name) [\(other.state.id)] to a friendly conversation. They may accept or continue their own activity.")
      if other.state.activity == .work {
        choices["help_\(other.state.id)"] = .init(activity: .help, partnerID: other.state.id,
          description: "Offer \(other.state.name) help with \(other.state.workDescription.lowercased()). Builds trust.")
      }
    }
    if simd_distance_squared(player, person.state.position) < 64,
      !person.state.record.memories.contains(where: { $0.event.contains("player") && latestTime - $0.time < 25 }) {
      choices["greet"] = .init(activity: .greet, description: "Greet the nearby player. Acknowledge a visitor or familiar neighbor.")
    }
    return choices
  }

  private func considerDecisions(site: Settlement, terrain: TerrainGenerator, player: SIMD3<Float>,
    environment: WorldEnvironment, loaded: Set<ChunkCoordinate>, block: (BlockPosition) -> Block) {
    let now = CACurrentMediaTime()
    if let pending = pendingDecisions {
      pendingDecisions = nil
      for i in residents.indices {
        let state = residents[i].state
        guard let original = pending.choices[state.id], state.revision == pending.revisions[state.id],
          loaded.contains(BlockPosition(state.position).chunk), now - pending.submitted <= 5 else { continue }
        let available = options(for: residents[i], site: site, player: player, block: block)
        if let choice = pending.response.action(for: state.id, options: original),
          available.values.contains(where: { $0.activity == choice.activity && $0.partnerID == choice.partnerID && $0.job == choice.job }) {
          apply(choice, tone: pending.response.tone(for: state.id), index: i, site: site, player: player, block: block)
          acceptedDecisions += 1
        } else {
          rejectedDecisions += 1; residents[i].state.nextDecision = latestTime + 8
        }
      }
      decisionStatus = "Jev · \(Int(decisionLatencyMilliseconds)) ms · \(acceptedDecisions) decisions"
      if logsDecisions {
        print("WORLDCRAFT_NPC model=\(pending.response.model) latency_ms=\(Int(decisionLatencyMilliseconds)) accepted=\(acceptedDecisions) rejected=\(rejectedDecisions) input_tokens=\(pending.response.usage?["input_tokens"] ?? 0)")
      }
    }
    let due = residents.indices.filter { residents[$0].state.nextDecision <= latestTime
      && !(welcomePort != nil && $0 < 8)
      && loaded.contains(BlockPosition(residents[$0].state.position).chunk) }
      .sorted { residents[$0].state.lastDecision < residents[$1].state.lastDecision }.prefix(6)
    guard !due.isEmpty else { return }
    guard let client, now >= requestBudget.nextAllowed else {
      // Offline life is explicitly a fallback. Continue a valid activity while
      // awaiting a response instead of replacing it with a timer-driven event.
      if decisionTask == nil && latestTime - lastLocalDecision > 2 {
        lastLocalDecision = latestTime
        for i in due {
          let choices = options(for: residents[i], site: site, player: player, block: block)
          if let job = homesteads.localOption(choices, resident: residents[i].state),
            residents[i].state.record.hunger < 0.9 && residents[i].state.record.fatigue < 0.95 {
            apply(job, tone: .practical, index: i, site: site, player: player, block: block)
            continue
          }
          let invitation = choices.values.first { option in
            option.activity == .socialize && residents.contains { $0.state.id == option.partnerID && $0.state.partnerID == residents[i].state.id }
          }
          let neighbor = invitation?.partnerID ?? choices.values.first { $0.activity == .socialize }?.partnerID
          let activity = residents[i].state.localChoice(night: environment.daylight < 0.1, nearby: neighbor)
          if let choice = (activity == .socialize ? invitation : nil)
            ?? choices.values.first(where: { $0.activity == activity }) ?? choices["stroll"] {
            apply(choice, tone: .warm, index: i, site: site, player: player, block: block)
          }
        }
      }
      return
    }
    guard decisionTask == nil, requestBudget.begin(at: now) else { return }
    var choices: [UInt64: [String: NPCDecisionOption]] = [:]
    var contexts: [UInt64: NPCDecisionContext] = [:]
    var revisions: [UInt64: Int] = [:]
    for i in due {
      let state = residents[i].state
      let available = options(for: residents[i], site: site, player: player, block: block)
      guard !available.isEmpty else { continue }
      choices[state.id] = available; revisions[state.id] = state.revision
      let partners = Set(available.values.compactMap(\.partnerID))
      contexts[state.id] = .init(resident: state, neighbors: residents.map(\.state).filter { partners.contains($0.id) },
        arrived: simd_distance_squared(state.position, residents[i].target) < 2.25, pathBlocked: residents[i].blocked, waitingForPassage: residents[i].waitingForPassage)
    }
    guard !contexts.isEmpty else { requestBudget.complete(at: now); return }
    let request = JevNPCRequest(settlement: site.name, biome: site.setting, dayFraction: environment.dayFraction,
      contexts: contexts, options: choices)
    let epoch = epoch
    let submitted = now
    let requestChoices = choices, requestRevisions = revisions
    decisionStatus = "Jev deciding for \(contexts.count) residents"
    decisionTask = Task { [weak self] in
      do {
        let response = try await client.decide(request)
        guard let self, self.epoch == epoch, !Task.isCancelled else { return }
        let completed = CACurrentMediaTime()
        self.decisionLatencyMilliseconds = (completed - submitted) * 1_000
        self.requestBudget.complete(at: completed); self.decisionTask = nil
        // Revalidate against the latest loaded world on the next simulation tick.
        self.pendingDecisions = .init(response: response, choices: requestChoices,
          revisions: requestRevisions, submitted: submitted)
      } catch {
        guard let self, self.epoch == epoch, !Task.isCancelled else { return }
        let service = error as? JevServiceError
        let retry: Double?
        if case .http(_, let delay) = service { retry = delay } else { retry = nil }
        self.requestBudget.fail(at: CACurrentMediaTime(), retryAfter: retry)
        self.decisionTask = nil
        self.decisionStatus = "Local life · " + (service?.description ?? "Jev connection unavailable")
        if self.logsDecisions { print("WORLDCRAFT_NPC fallback=1 failures=\(self.requestBudget.failures) reason=\(service?.description ?? "network_error")") }
      }
    }
  }

  private func navigable(_ point: SIMD3<Float>, site: Settlement, block: (BlockPosition) -> Block) -> SIMD3<Float>? {
    site.habitat == .aquatic ? ResidentNavigation.swimPosition(at: point, block: block)
      : ResidentNavigation.walkingPosition(at: point, block: block)
  }

  private func navigationPassages(site:Settlement,terrain:TerrainGenerator) -> [ResidentPassage] {
    var result:[ResidentPassage]=[], lots=Set<SIMD2<Int>>()
    for person in residents {
      let x=floorDivide(Int(floor(person.state.position.x))-site.x,by:site.spacing)
      let z=floorDivide(Int(floor(person.state.position.z))-site.z,by:site.spacing)
      for dx in -1...1 {for dz in -1...1 {lots.insert([x+dx,z+dz])}}
    }
    if lots == passageLots {return passageCache}
    passageLots=lots
    for lot in lots.sorted(by:{$0.x == $1.x ? $0.y<$1.y:$0.x<$1.x}) {
      guard let building=site.building(lotX:lot.x,lotZ:lot.y,terrain:terrain),
        let door=site.door(lotX:lot.x,lotZ:lot.y,terrain:terrain) else {continue}
      result.append(.init(id:door.id,low:door.origin+[-0.1,0,-0.9],high:door.origin+[2.1,0,0.9],axis:2))
      if building.hasStairs {
        let origin=SIMD3<Float>(Float(site.x+lot.x*site.spacing),Float(site.floor),Float(site.z+lot.y*site.spacing))
        // Reserve the whole staircase, including landings, for one walker.
        result.append(.init(id:door.id ^ 0x535441495253,
          low:origin+[Float(building.stairStartX)-1,0,Float(building.stairZ.lowerBound)-0.5],
          high:origin+[Float(building.stairStartX+building.storey)+2,Float(building.height),Float(building.stairZ.upperBound)+1.5],axis:0))
      }
    }
    passageCache=result
    return result
  }

  private func crowdNeighbors() -> [ResidentCrowd.Neighbor] {
    residents.map(crowdNeighbor)
  }
  private func crowdNeighbor(_ person: Person) -> ResidentCrowd.Neighbor {
    let speed: Float = person.state.moving ? (person.state.activity == .flee ? 5 : 1.4) : 0
    return .init(id: person.state.id, position: person.state.position,
      velocity: [-sin(person.state.heading)*speed, 0, -cos(person.state.heading)*speed])
  }

  private func destination(for action: ResidentActivity, resident: ResidentState,
    site: Settlement, player: SIMD3<Float>) -> SIMD3<Float> {
    switch action {
    case .work: resident.workplace
    case .eat: site.meetingPoint(index: resident.index, purpose: .meal, near: resident.home)
    case .rest: resident.home
    case .greet: player + ResidentCrowd.approachOffset(index: resident.index)
    default: site.meetingPoint(index: resident.index + Int(latestTime / 35), purpose: .leisure, near: resident.home)
    }
  }
  private func apply(_ option: NPCDecisionOption, tone: ConversationTone, index: Int,
    site: Settlement, player: SIMD3<Float>, block: (BlockPosition) -> Block) {
    residents[index].socialAccepted = false
    residents[index].state.choose(option.activity, partner: option.partnerID, tone: tone, time: latestTime)
    residents[index].job = option.job
    let state = residents[index].state
    residents[index].target = option.partnerID.flatMap { id in residents.first { $0.state.id == id }?.state.position }
      .map { $0 + ResidentCrowd.approachOffset(index: state.index % 12, radius: 1.6) }
      ?? destination(for: option.activity, resident: state, site: site, player: player)
    residents[index].route = []; residents[index].waypoint = 0; residents[index].nextPath = 0
    if let job = option.job {
      residents[index].target = homesteads.destination(job, resident: state, block: block)
      residents[index].state.nextDecision = latestTime + 55
    }
    if option.activity == .socialize, let partner = option.partnerID,
      let j = residents.firstIndex(where: { $0.state.id == partner }) {
      if residents[j].state.partnerID == state.id && residents[j].state.activity == .socialize {
        let meeting = residents[j].state.position
        residents[index].target = meeting + ResidentCrowd.approachOffset(index: state.index % 12, radius: 1.6)
        residents[j].target = meeting
        residents[index].socialAccepted = true; residents[j].socialAccepted = true
        residents[j].route = []; residents[j].waypoint = 0
        residents[j].state.reconsider(at: latestTime + 22)
      } else {
        residents[j].state.remember("\(state.name) invited me to a conversation", other: state.id, time: latestTime)
        residents[j].state.reconsider(at: latestTime + 0.5)
        residents[index].state.nextDecision = latestTime + 12
      }
    }
  }

  func interact(with id: UInt64) {
    guard let site, let i = residents.firstIndex(where: { $0.state.id == id }) else { return }
    selectedResident = id
    let familiar = residents[i].state.record.memories.contains { $0.event.contains("player") }
    conversation = "\(residents[i].state.name): " + residents[i].state.line(settlement: site.name, biome: site.setting, familiar: familiar)
    conversationUntil = latestTime + 7
    guard residents[i].state.activity != .flee else { return }
    residents[i].state.record.playerTrust = min(1, residents[i].state.record.playerTrust + 0.025)
    residents[i].state.record.playerConversations = min(1_000_000, residents[i].state.record.playerConversations + 1)
    residents[i].state.remember("Had a friendly conversation with the player", time: latestTime)
    residents[i].state.record.agency?.memory.remember(.metPlayer, "The player stopped to talk with me", time: latestTime, importance: 0.7)
    guard residents[i].job == nil else { return }
    residents[i].state.choose(.greet, tone: residents[i].state.tone, time: latestTime)
    residents[i].target = residents[i].state.position; residents[i].route = []; residents[i].waypoint = 0
  }
  func witnessedEdit(at point: BlockPosition, old: Block, new: Block, terrain: TerrainGenerator, time: Double? = nil) {
    if let time { latestTime = time }
    let owner = homesteads.edited(at: point, old: old, new: new, terrain: terrain, time: latestTime)
    let removed = old.isSolid && !new.isSolid
    for i in residents.indices where simd_distance_squared(residents[i].state.position, point.center) < 14 * 14 {
      if let owner, removed {
        if residents[i].state.record.agency == nil { residents[i].state.record.agency = .init() }
        let ownHome = owner == residents[i].state.id
        residents[i].state.record.agency?.memory.remember(.homeDamaged,
          ownHome ? "The player damaged my home" : "Saw the player damage a neighbor's home",
          at: point, other: owner, time: latestTime, importance: 1)
        residents[i].state.record.playerTrust = max(0, residents[i].state.record.playerTrust - (owner == residents[i].state.id ? 0.15 : 0.04))
      }
      if !(residents[i].state.record.memories.last.map { latestTime - $0.time < 4 && $0.event.contains("player") } ?? false) {
        residents[i].state.remember(removed ? "The player damaged or changed nearby blocks" : "The player built something nearby", time: latestTime)
        // Coalesce a continuing incident so repeated edits cannot starve every
        // in-flight Jev answer or reset all repair/work progress indefinitely.
        if residents[i].job == nil { residents[i].state.reconsider(at: latestTime + 0.3) }
      }
    }
  }

  private func makePerson(state: ResidentState) -> Person { .init(state: state, target: state.home) }

  func clear() {
    clearActors(); region = nil; candidate = nil
  }
  private func clearActors() {
    passageCache=[];passageLots=[];passageQueue = .init()
    homesteads.clearSite()
    welcomePort = nil; welcomeUntil = .infinity; celebratingArrival = false
    cancelDecisions()
    for person in residents { saved[person.state.id] = person.state.record }
    if saved.count > 2_048 { saved = Dictionary(uniqueKeysWithValues: saved.values.sorted { $0.id < $1.id }.prefix(2_048).map { ($0.id, $0) }) }
    residents.removeAll(); site = nil
    residentHomes.removeAll(); nearbyResidentIndices.removeAll(); nextPopulationRefresh = 0
    prompt = ""; conversation = ""; selectedResident = nil; simulationAccumulator = 0; pendingTraffic.removeAll()
    lastLocalDecision = -.infinity; conversationUntil = 0
  }
}
