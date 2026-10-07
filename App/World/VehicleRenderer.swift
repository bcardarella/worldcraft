import RealityKit
import UIKit
import WorldCore

@MainActor
final class VehicleRenderer {
  private struct Car {
    let id: UInt64
    let siteID: UInt64
    let root: Entity
    let variant: Int
    let solar: Bool
    var physics: VehiclePhysics
    var traffic: CityTrafficDriver?
    var lap = RaceProgress()
    var circuitID: UInt64?
    var wheelSpin: Float = 0
    var rival = false
    var crushed = false
    var racer = RaceDriver()
    var raceAccumulator: Float = 0
    var tactic: RacingTactic = .steady
    var tacticUntil: Double = 0
  }
  private var cars: [Car] = []
  private var race:RaceEvent?
  private var saved: [UInt64: VehicleRecord] = [:]
  var records: [VehicleRecord] {
    let active = Set(cars.map(\.id))
    return cars.filter { !$0.rival }.map(record) + saved.values.filter { !active.contains($0.id) }.sorted { $0.id < $1.id }.prefix(max(0, 128 - cars.count))
  }
  func restore(_ records: [VehicleRecord]) {
    saved = Dictionary(records.filter(\.isValid).prefix(128).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
  }
  private func record(_ car: Car) -> VehicleRecord {
    var value=VehicleRecord(id: car.id, siteID: car.siteID, position: [car.physics.position.x, car.physics.position.y, car.physics.position.z],
      heading: car.physics.heading, variant: car.variant, solar: car.solar, kind: car.physics.kind,
      parkingBrake: car.physics.parkingBrake, traffic: car.traffic)
    value.crushed=car.crushed;return value
  }
  private let models = VehicleModelLibrary()
  private var racingService = RacingDecisionService(apiKey:nil)
  private var racingTask: Task<Void,Never>?
  private var racingEpoch = UUID()
  private var nextRacingDecision: Double = 0
  func configureJev(key:String?,enabled:Bool) {
    cancelRacing(); racingService=RacingDecisionService(apiKey:enabled ? key:nil)
  }
  func suspendDecisions() { cancelRacing() }
  private func cancelRacing() {
    racingEpoch=UUID(); racingTask?.cancel(); racingTask=nil; nextRacingDecision=0
  }
  private var driver: UInt64?
  private var boardingPosition: SIMD3<Float>?
  private var headlightTime: Double = -.infinity
  private var previousTraffic: [UInt64: SIMD3<Float>] = [:]
  func trafficSnapshot() -> [VehicleTraffic] {
    let result = cars.filter { $0.root.isEnabled }.map { car in
      VehicleTraffic(id: car.id, position: car.physics.position,
        previousPosition: previousTraffic[car.id] ?? car.physics.position,
        velocity: car.physics.velocity, heading: car.physics.heading, playerDriven: car.id == driver, kind: car.physics.kind)
    }
    previousTraffic = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0.position) })
    return result
  }
  private var circuits: [WorldLandmark] = []
  // Static fallback samples outside loaded chunks are shared by all rivals.
  // Cap and discard on world changes; terrain edits always use live loaded data.
  private var circuitBlocks: [BlockPosition: Block] = [:]
  private func circuitBlock(_ p: BlockPosition, track: WorldLandmark) -> Block {
    if let cached = circuitBlocks[p] { return cached }
    let value = track.block(at: p, surface: track.floor, natural: track.floor - 1) ?? .stone
    if circuitBlocks.count >= 32_768 { circuitBlocks.removeAll(keepingCapacity: true) }
    circuitBlocks[p] = value
    return value
  }
  private var focused: UInt64?
  private var notice = ""
  private var noticeUntil: Double = 0
  private var time: Double = 0
  var audioStates: [VehicleSoundState] {
    cars.filter { $0.root.isEnabled }.map {
      .init(id: $0.id, position: $0.physics.position, speed: abs($0.physics.speed),
        racing: $0.physics.kind.sporting, occupied: $0.id == driver || $0.rival || $0.traffic?.isActive == true)
    }
  }
  var isDriving: Bool { driver != nil }
  var completedLaps: Int { cars.first { $0.id == driver }?.lap.laps ?? 0 }
  var isOnCircuit: Bool { cars.first { $0.id == driver }?.circuitID != nil }
  var eye: SIMD3<Float>? { cars.first { $0.id == driver }?.physics.eye }
  var heading: Float? { cars.first { $0.id == driver }?.physics.heading }
  var companionCarrier: CompanionCarrier? {
    driver.flatMap { companionCarrier(for:$0) }
  }
  func companionCarrier(for id:UInt64) -> CompanionCarrier? {
    guard let car=cars.first(where:{$0.id == id}) else { return nil }
    return .init(id:car.id,kind:.car(car.physics.kind),position:car.physics.position,heading:car.physics.heading)
  }
  var velocity: SIMD3<Float> { cars.first { $0.id == driver }?.physics.velocity ?? .zero }
  var impactSpeed: Float { cars.first { $0.id == driver }?.physics.impactSpeed ?? 0 }
  var slipSpeed: Float { cars.first { $0.id == driver }?.physics.slipSpeed ?? 0 }
  var speed: Float { abs(cars.first { $0.id == driver }?.physics.speed ?? 0) }
  var activeHeadlightCount: Int { cars.filter { $0.root.isEnabled && $0.root.findEntity(named: "Headlight beam")?.isEnabled == true }.count }
  var prompt: String {
    if time < noticeUntil { return notice }
    if isDriving {
      let racing: String
      if let car = cars.first(where: { $0.id == driver }), car.circuitID != nil {
        let lap = car.lap
        racing = (race?.label ?? "Square / X / E: start 3-lap race · Practice lap \(lap.laps+1)") + (race == nil ? " · " + (lap.active ? String(format:"%.1fs",lap.elapsed) : "Clockwise · cross the chequered line") : "")
          + (lap.best.map { String(format:" · Best %.1fs",$0) } ?? "") + " · "
      } else { racing = "" }
      let car = cars.first { $0.id == driver }
      let parked = car?.physics.parkingBrake == true ? "PARKING BRAKE ON · R1 / RB / Space to release · " : "Handbrake / drift: R1 / RB / Space · "
      return (car?.physics.kind.name ?? "Car") + " · " + racing + parked + "RT: drive · LT: reverse/brake · Triangle / Y / R: exit" }
    return focused.flatMap { id in cars.first { $0.id == id } }.map { "\($0.physics.kind.name) · Triangle / Y or LT / R to drive" } ?? ""
  }

  func update(site: Settlement?, terrain: TerrainGenerator, root: Entity, player: SIMD3<Float>, deltaTime: Float,
    loaded: Set<ChunkCoordinate>, obstacles: [SIMD3<Float>], daylight: Float, block: (BlockPosition) -> Block) {
    guard deltaTime > 0 else { if racingTask != nil { cancelRacing() }; return }
    time += Double(deltaTime)
    race?.advance(seconds:deltaTime)
    if time-headlightTime > 0.2 {
      headlightTime = time
      let nearest = cars.filter { $0.root.isEnabled && ($0.id == driver || $0.rival || $0.traffic?.isActive == true) }
        .sorted { a,b in
          if a.id == b.id { return false }
          if a.id == driver { return true }; if b.id == driver { return false }
          return simd_distance_squared(a.physics.position,player) < simd_distance_squared(b.physics.position,player)
        }.prefix(3)
      let lit = Set(nearest.filter { $0.id == driver || simd_distance_squared($0.physics.position,player) < 100*100 }.map(\.id))
      for car in cars {
        guard let lamp = car.root.findEntity(named: "Headlight beam") else { continue }
        let active = !car.crushed && !RenderDiagnostics.current.disableLocalLights && lit.contains(car.id) && daylight < 0.55
        if lamp.isEnabled != active { lamp.isEnabled = active }
        if active, var light = lamp.components[SpotLightComponent.self] {
          light.intensity = 4_800*(1-smoothstep(0.05,0.55,daylight))
          lamp.components.set(light)
          // The player's headlights cast road/building shadows; other nearby
          // traffic uses unshadowed beams to bound shadow map work.
          if car.id == driver { lamp.components.set(SpotLightComponent.Shadow()) }
          else { lamp.components.remove(SpotLightComponent.Shadow.self) }
        }
      }
    }
    circuits = terrain.landmarks.filter { $0.kind == .circuit }
    let nearbyTrack = circuits.filter { simd_distance_squared($0.center,player)<500*500 }
      .min { simd_distance_squared($0.center,player)<simd_distance_squared($1.center,player) }
    let safe: (BlockPosition) -> Block = { loaded.contains($0.chunk) ? block($0) : .stone }
    for i in cars.indices.reversed() where cars[i].id != driver
      && simd_distance_squared(cars[i].physics.position, player) > (cars[i].rival ? 1_100 * 1_100 : RaceGarage.contains(car: cars[i].id, track: cars[i].siteID) ? RaceGarage.departureDistance * RaceGarage.departureDistance : 200 * 200) {
      if !cars[i].rival { saved[cars[i].id] = record(cars[i]) }; cars[i].root.removeFromParent(); cars.remove(at: i)
    }
    if saved.count > 128 {
      saved = Dictionary(uniqueKeysWithValues: saved.values.sorted { $0.id < $1.id }.prefix(128).map { ($0.id, $0) })
    }
    let garageDemand = circuits.reduce(0) { count, track in
      count + (0..<RaceGarage.bayCount).filter { bay in
        let id = RaceGarage.carID(track: track.id, bay: bay)
        return saved[id] == nil && !cars.contains { $0.id == id }
          && RaceGarage.isNear(track.circuit.pitPosition(bay), player: player)
      }.count
    }
    let rivalDemand = nearbyTrack.map { track in
      (0..<4).filter { index in
        let id=track.id &+ UInt64(index+1) &* 0x4a45565241434501
        return saved[id] == nil && !cars.contains { $0.id == id }
      }.count
    } ?? 0
    // Parked/saved city cars must not consume every opponent slot. Also free
    // reservations already occupied before the player approached the track.
    let trafficLimit = max(0,18-garageDemand-rivalDemand)
    if cars.count > trafficLimit,
      let index=cars.indices.filter({ cars[$0].id != driver && !cars[$0].rival
        && !RaceGarage.contains(car:cars[$0].id,track:cars[$0].siteID) })
        .max(by:{ simd_distance_squared(cars[$0].physics.position,player)<simd_distance_squared(cars[$1].physics.position,player) }) {
      saved[cars[index].id]=record(cars[index]); cars[index].root.removeFromParent(); cars.remove(at:index)
    }
    var restored = false
    if cars.count < 18 {
      for record in saved.values.sorted(by: { $0.id < $1.id }) {
        let point = SIMD3<Float>(record.position[0], record.position[1], record.position[2])
        let garageCar = RaceGarage.contains(car: record.id, track: record.siteID)
        if !garageCar && cars.count >= trafficLimit { continue }
        guard !cars.contains(where: { $0.id == record.id }), loaded.contains(BlockPosition(point).chunk),
          (garageCar ? RaceGarage.isNear(point, player: player) : simd_distance_squared(point, player) < 150 * 150)
        else { continue }
        if garageCar && !RaceGarage.requiredChunks(at: point).isSubset(of: loaded) { continue }
        var kind = record.kind ?? .touring
        if record.modelVersion == nil && kind != .race {
          let variety = VehicleKind.spawned(id:record.id,in:site?.kind ?? .town)
          if VehiclePhysics.isClear(at:point,heading:record.heading,kind:variety,block:safe) { kind=variety }
        }
        guard let entity = models.model(kind:kind,variant:record.variant,solar:record.solar) else { break }
        entity.position = point
        entity.orientation = simd_quatf(angle: record.heading, axis: [0, 1, 0])
        root.addChild(entity)
        cars.append(.init(id: record.id, siteID: record.siteID, root: entity, variant: record.variant, solar: record.solar,
          physics: .init(position: point, heading: record.heading, kind: kind, parkingBrake: record.parkingBrake ?? false),
          traffic: record.crushed == true ? .parked:garageCar ? .parked:record.restoredTraffic(in:site),crushed:record.crushed ?? false))
        if record.crushed == true {entity.scale.y *= 0.18}
        restored = true; break
      }
    }
    if !restored, cars.count < 18 {
      for track in circuits {
        for index in 0..<RaceGarage.bayCount {
          let id = RaceGarage.carID(track: track.id, bay: index)
          let point = track.circuit.pitPosition(index)
          guard saved[id] == nil, !cars.contains(where: { $0.id == id }),
            RaceGarage.isNear(point, player: player), RaceGarage.requiredChunks(at: point).isSubset(of: loaded),
            VehiclePhysics.isClear(at: point, heading: 0, kind: .race, block: safe),
            !isOccupied(point, heading: 0, ignoring: id, people: obstacles + [player]) else { continue }
          guard let entity = models.model(kind:.race,variant:index,solar:terrain.style == .solar) else { break }
          entity.position = point; root.addChild(entity)
          cars.append(.init(id:id,siteID:track.id,root:entity,variant:index,solar:terrain.style == .solar,
            physics:.init(position:point,kind:.race),traffic:.parked,circuitID:track.id))
          restored = true; break
        }
        if restored { break }
      }
    }
    if !restored, cars.count < 18, cars.filter(\.rival).count < 6,
      let track=nearbyTrack {
      for index in 0..<4 {
        let id=track.id &+ UInt64(index+1) &* 0x4a45565241434501
        guard saved[id] == nil,!cars.contains(where:{$0.id == id}) else { continue }
        let progress=Float(index)*track.circuit.length/4+30
        let point=track.circuit.point(at:progress,lane:index%2 == 0 ? -2.2:2.2)
        let direction=track.circuit.tangent(at:progress),heading=atan2(-direction.x,-direction.z)
        let raceBlock: (BlockPosition)->Block = { [self] p in
          loaded.contains(p.chunk) ? block(p) : circuitBlock(p, track: track)
        }
        guard VehiclePhysics.isClear(at:point,heading:heading,kind:.race,block:raceBlock),
          let entity=models.model(kind:.race,variant:index%3,solar:terrain.style == .solar) else { continue }
        entity.position=point; root.addChild(entity)
        let person=SculptureBuilder(materials:[SimpleMaterial(color:.darkGray,roughness:0.8,isMetallic:false),
          SimpleMaterial(color:index%2 == 0 ? .orange:.cyan,roughness:0.3,isMetallic:false)])
        let pilot=Entity(); pilot.scale = .init(repeating:WorldScale.metresPerBlock); pilot.name="Racing driver"; entity.addChild(pilot)
        person.box([0.55,0.62,0.4],[-0.45,1.75,0.20],0,parent:pilot)
        person.box([0.46,0.49,0.43],[-0.45,2.25,0.12],1,parent:pilot); person.finish()
        cars.append(.init(id:id,siteID:track.id,root:entity,variant:index%3,solar:terrain.style == .solar,
          physics:.init(position:point,heading:heading,kind:.race),traffic:.parked,circuitID:track.id,rival:true))
        restored=true; break
      }
    }
    if !restored, cars.count < trafficLimit, let site, site.habitat != .aquatic {
      let indices = (0..<site.vehicleCount).sorted {
        simd_distance_squared(site.vehiclePosition($0),player) < simd_distance_squared(site.vehiclePosition($1),player)
      }
      for index in indices {
        let id = CityTrafficDriver.carID(in:site,index:index)
        guard saved[id] == nil, !cars.contains(where: { $0.id == id }) else { continue }
        let point = site.vehiclePosition(index)
        let kind=VehicleKind.spawned(id:id,in:site.kind)
        guard site.isRoad(atX:Int(point.x),z:Int(point.z)),simd_distance_squared(point,player) < 150*150,
          loaded.contains(BlockPosition(point).chunk), VehiclePhysics.isClear(at: point, heading: 0, kind:kind, block: safe) else { continue }
        guard let entity = models.model(kind:kind,variant:index % 3,solar:site.habitat == .solar) else { break }
        entity.position = point; root.addChild(entity)
        cars.append(.init(id: id, siteID: site.id, root: entity, variant: index % 3, solar: site.habitat == .solar,
          physics: .init(position: point,kind:kind), traffic: .spawned(in:site,index:index)))
        // Stream one car model per frame, keeping settlement arrival inexpensive.
        break
      }
    }
    // The occupied car survives crossing settlement/region boundaries.
    while cars.count > 18 {
      guard let index = cars.indices.filter({ cars[$0].id != driver && cars[$0].siteID != site?.id })
        .max(by: { simd_distance_squared(cars[$0].physics.position, player) < simd_distance_squared(cars[$1].physics.position, player) }) else { break }
      if !cars[index].rival { saved[cars[index].id] = record(cars[index]) }
      cars[index].root.removeFromParent(); cars.remove(at: index)
    }
    for i in cars.indices {
      if cars[i].traffic == nil, cars[i].siteID == site?.id {
        cars[i].traffic = record(cars[i]).restoredTraffic(in:site)
      }
      let enabled = cars[i].id == driver || cars[i].rival || (loaded.contains(BlockPosition(cars[i].physics.position).chunk)
        && (RaceGarage.contains(car: cars[i].id, track: cars[i].siteID)
          ? RaceGarage.isNear(cars[i].physics.position, player: player, retaining: true)
          : simd_distance_squared(cars[i].physics.position, player) < 160 * 160))
      if cars[i].root.isEnabled != enabled { cars[i].root.isEnabled = enabled }
      guard enabled else { continue }
      if cars[i].rival, race?.canDrive(cars[i].id) != false, let track=circuits.first(where:{$0.id == cars[i].siteID}) {
        cars[i].raceAccumulator += min(0.05,deltaTime)
        if cars[i].raceAccumulator >= 1.0/30 {
          let seconds=min(0.05,cars[i].raceAccumulator); cars[i].raceAccumulator=0
          var physics=cars[i].physics
          let traffic=cars.map { VehicleTraffic(id:$0.id,position:$0.physics.position,previousPosition:$0.physics.position,
            velocity:$0.physics.velocity,heading:$0.physics.heading,playerDriven:$0.id == driver,kind:$0.physics.kind) }
          let tactic=time<cars[i].tacticUntil ? cars[i].tactic:RacingTactic.steady
          let observation=RacerObservation(id:cars[i].id,circuit:track.circuit,physics:physics,traffic:traffic,previous:tactic)
          let controls=cars[i].racer.controls(physics:physics,circuit:track.circuit,tactic:tactic,observation:observation,seconds:seconds)
          physics.update(deltaTime:seconds,throttle:controls.throttle,turn:controls.steering,brake:0,
            block: { [self] p in loaded.contains(p.chunk) ? block(p) : circuitBlock(p, track: track) },
            occupied: { [self] p,yaw in isOccupied(p,heading:yaw,ignoring:cars[i].id,people:obstacles+[player]) })
          cars[i].physics=physics; cars[i].wheelSpin += physics.speed*seconds/WorldScale.blocks(0.208)
          cars[i].lap.update(position:physics.position,seconds:seconds,circuit:track.circuit)
          race?.record(cars[i].id,laps:cars[i].lap.laps)
        }
      }
      if cars[i].id != driver, var traffic=cars[i].traffic, traffic.isActive {
        var physics = cars[i].physics
        traffic.update(physics:&physics,seconds:deltaTime,block:safe,
          occupied: { [self] p, yaw in isOccupied(p, heading: yaw, ignoring: cars[i].id, people: obstacles + [player]) })
        cars[i].traffic = traffic
        cars[i].physics = physics
        cars[i].wheelSpin += physics.speed * deltaTime / WorldScale.blocks(0.208)
      }
      let previous=cars[i].root.position
      if cars[i].id == driver || cars[i].rival || cars[i].traffic?.isActive == true || previous != cars[i].physics.position {
        positionModel(i)
      }
      if cars[i].rival { cars[i].root.position=previous+(cars[i].physics.position-previous)*min(1,deltaTime*24) }
    }
    if racingTask == nil && time >= nextRacingDecision {
      let traffic=cars.map { VehicleTraffic(id:$0.id,position:$0.physics.position,previousPosition:$0.physics.position,
        velocity:$0.physics.velocity,heading:$0.physics.heading,playerDriven:$0.id == driver,kind:$0.physics.kind) }
      let observations=cars.filter(\.rival).sorted { $0.tacticUntil < $1.tacticUntil }.prefix(6).compactMap { car -> RacerObservation? in
        guard let track=circuits.first(where:{$0.id == car.siteID}) else { return nil }
        return .init(id:car.id,circuit:track.circuit,physics:car.physics,traffic:traffic,previous:car.tactic)
      }
      nextRacingDecision=time+3
      if !observations.isEmpty {
        let epoch=racingEpoch, service=racingService, requested=time
        racingTask=Task { [weak self] in
          let decisions=await service.decide(observations,time:requested)
          guard let self,!Task.isCancelled,epoch == self.racingEpoch else { return }
          self.racingTask=nil
          guard self.time-requested<6 else { return }
          for i in self.cars.indices where self.cars[i].rival {
            if let tactic=decisions[self.cars[i].id] { self.cars[i].tactic=tactic; self.cars[i].tacticUntil=self.time+6 }
          }
        }
      }
    }
  }

  func drive(deltaTime: Float, throttle: Float, steering: Float, brake: Float,
    obstacles: [SIMD3<Float>], loaded: Set<ChunkCoordinate>, block: (BlockPosition) -> Block) -> Float {
    guard let i = cars.firstIndex(where: { $0.id == driver }) else { return 0 }
    guard race?.canDrive(cars[i].id) != false else {cars[i].physics.stop(); return 0}
    var physics = cars[i].physics
    let previous = physics.heading
    let profile = physics.kind
    var pushable: [Int: Bool] = [:]
    physics.update(deltaTime: deltaTime, throttle: throttle, turn: steering, brake: brake,
      block: { loaded.contains($0.chunk) ? block($0) : .stone },
      occupied: { [self] p, yaw in
        if isOccupied(p, heading: yaw, ignoring: cars[i].id, people: []) { return true }
        let car = VehiclePhysics(position: p, heading: yaw, kind:profile)
        for (index, person) in obstacles.enumerated() where car.overlapsPlayer(at: person) {
          // A contact escape is evaluated once per resident per frame, rather
          // than repeated for all six 120-Hz vehicle physics substeps.
          if let clear = pushable[index] { if !clear { return true }; continue }
          let traffic = VehicleTraffic(id: cars[i].id, position: p, previousPosition: cars[i].physics.position,
            velocity: [-sin(yaw), 0, -cos(yaw)], heading: yaw, playerDriven: true,kind:profile)
          let canMove = traffic.reaction(at: person, personID: UInt64(index), navigable: { candidate in
            guard !isOccupied(candidate, heading: yaw, ignoring: cars[i].id, people: []),
              !obstacles.enumerated().contains(where: { $0.offset != index && simd_distance_squared($0.element, candidate) < 0.75 }) else { return nil }
            return ResidentNavigation.walkingPosition(at: candidate, block: { loaded.contains($0.chunk) ? block($0) : .stone })
          }) != nil
          pushable[index] = canMove
          if !canMove { return true }
        }
        return false
      })
    cars[i].physics = physics
    cars[i].wheelSpin += physics.speed * deltaTime / WorldScale.blocks(0.208)
    positionModel(i)
    if let track = circuits.first(where: { $0.contains(x:Int(floor(physics.position.x)),z:Int(floor(physics.position.z))) }) {
      if cars[i].circuitID != track.id { cars[i].lap = .init(); cars[i].circuitID = track.id }
      cars[i].lap.update(position:physics.position,seconds:min(0.05,max(0,deltaTime)),circuit:track.circuit)
      race?.record(cars[i].id,laps:cars[i].lap.laps)
    } else { cars[i].circuitID = nil; cars[i].lap = .init() }
    return atan2(sin(physics.heading - previous), cos(physics.heading - previous))
  }

  func startRace(block:(BlockPosition)->Block) {
    guard let playerIndex=cars.firstIndex(where:{$0.id==driver}),
      let track=circuits.first(where:{$0.id==cars[playerIndex].circuitID}) else {return}
    guard abs(cars[playerIndex].physics.speed)<1 else {notice="Stop on the track or in the pits to start a race";noticeUntil=time+3;return}
    let opponents=cars.indices.filter {$0 != playerIndex && cars[$0].rival && cars[$0].siteID==track.id}.prefix(4)
    guard !opponents.isEmpty else {notice="Waiting for the other racers to arrive";noticeUntil=time+3;return}
    let indices=[playerIndex]+opponents
    var starts:[(SIMD3<Float>,Float)]=[]
    for slot in indices.indices {
      let progress = -6-Float(slot/2)*9
      let point=track.circuit.point(at:progress,lane:slot%2 == 0 ? -3:3)
      let d=track.circuit.tangent(at:progress),yaw=atan2(-d.x,-d.z)
      guard VehiclePhysics.isClear(at:point,heading:yaw,kind:cars[indices[slot]].physics.kind,block:block),
        !cars.indices.contains(where:{!indices.contains($0) && VehiclePhysics.overlaps(position:point,heading:yaw,kind:cars[indices[slot]].physics.kind,
          otherPosition:cars[$0].physics.position,otherHeading:cars[$0].physics.heading,otherKind:cars[$0].physics.kind)}) else {
        notice="Start grid isn't clear yet";noticeUntil=time+3;return
      }
      starts.append((point,yaw))
    }
    cancelRacing()
    for (slot,i) in indices.enumerated() {
      cars[i].physics = .init(position:starts[slot].0,heading:starts[slot].1,kind:cars[i].physics.kind)
      cars[i].lap = .init();cars[i].racer = .init();cars[i].raceAccumulator=0;cars[i].tacticUntil=0
      cars[i].lap.update(position:starts[slot].0,seconds:0,circuit:track.circuit)
      positionModel(i)
    }
    race = .init(circuitID:track.id,player:cars[playerIndex].id,opponents:opponents.map{cars[$0].id})
    noticeUntil=0
  }

  private func isOccupied(_ point: SIMD3<Float>, heading: Float, ignoring id: UInt64,
    people: [SIMD3<Float>]) -> Bool {
    let c = cos(heading), s = sin(heading)
    let kind = cars.first { $0.id == id }?.physics.kind
      ?? (circuits.contains { RaceGarage.contains(car: id, track: $0.id) } ? .race : .touring)
    for p in people where abs(p.y - point.y) < 4 {
      let delta = p - point
      if abs(c * delta.x - s * delta.z) < kind.halfWidth+0.65 && abs(s * delta.x + c * delta.z) < kind.halfLength+0.7 { return true }
    }
    return cars.contains { !$0.crushed && $0.id != id && VehiclePhysics.overlaps(position:point,heading:heading,kind:kind,
      otherPosition:$0.physics.position,otherHeading:$0.physics.heading,otherKind:$0.physics.kind) }
  }

  func crush(from:SIMD3<Float>,to:SIMD3<Float>,radius:Float) {
    let delta=SIMD2<Float>(to.x-from.x,to.z-from.z),length=simd_length_squared(delta)
    guard length>0.0001,length<256*256 else {return}
    for i in cars.indices where !cars[i].crushed && cars[i].id != driver {
      let p=cars[i].physics.position,d=SIMD2<Float>(p.x-from.x,p.z-from.z)
      let t=max(0,min(1,simd_dot(d,delta)/length)),offset=d-delta*t
      if abs(p.y-to.y)<radius && simd_length_squared(offset)<pow(radius+cars[i].physics.kind.halfLength,2) {
        cars[i].crushed=true;cars[i].physics.stop();cars[i].traffic = .parked;cars[i].rival=false
        cars[i].root.scale.y *= 0.18;cars[i].root.findEntity(named:"Headlight beam")?.isEnabled=false
        saved[cars[i].id]=record(cars[i])
      }
    }
  }
  func focus(eye: SIMD3<Float>, direction: SIMD3<Float>, block: (BlockPosition) -> Block) {
    guard !isDriving else { focused = nil; return }
    focused = cars.filter { car in
      let delta = car.physics.position + [0, 1.5, 0] - eye
      let distance = simd_length(delta)
      return !car.crushed && car.root.isEnabled && distance < 7 && abs(car.physics.speed) < 1
        && distance > 0.001 && simd_dot(delta / distance, simd_normalize(direction)) > 0.78
        && VoxelRaycast.cast(origin: eye, direction: delta, reach: max(0, distance - 1), block: block) == nil
    }.min { simd_distance_squared($0.physics.position, eye) < simd_distance_squared($1.physics.position, eye) }?.id
  }

  /// Returns a safe position on exit. Entry is reflected immediately by isDriving.
  func interact(player: SIMD3<Float>, block: (BlockPosition) -> Block,
    occupied: (SIMD3<Float>) -> Bool = { _ in false }) -> SIMD3<Float>? {
    if let i = cars.firstIndex(where: { $0.id == driver }) {
      guard abs(cars[i].physics.speed) < 1 else {
        notice = "Stop the car to get out · Space / R1 / RB brakes"; noticeUntil = time + 3; return nil
      }
      func obstructed(_ p: SIMD3<Float>) -> Bool {
        occupied(p) || cars.contains { $0.id != driver && $0.physics.overlapsPlayer(at: p) }
      }
      let nearby = cars[i].physics.exitPosition(block: block, occupied: obstructed)
      let roof = nearby == nil ? cars[i].physics.roofExit(block: block, occupied: obstructed) : nil
      let boarding = boardingPosition.flatMap { p in
        simd_distance_squared(p,cars[i].physics.position) <= 24*24 && !obstructed(p) && !cars[i].physics.overlapsPlayer(at: p) && VehiclePhysics.safeFooting(at: p, block: block) ? p : nil
      }
      guard let exit = nearby ?? roof ?? boarding else {
        notice = "No safe exit or headroom · reverse toward clear ground"; noticeUntil = time + 3; return nil
      }
      race?.cancel()
      cars[i].physics.stop(); cars[i].traffic = .parked
      driver = nil; focused = nil; boardingPosition = nil; noticeUntil = 0
      return exit
    }
    if let id = focused, let i = cars.firstIndex(where: { $0.id == id }) {
      let feet = SIMD3<Float>(player.x, floor(player.y + 0.05) + 0.02, player.z)
      boardingPosition = VehiclePhysics.safeFooting(at: feet, block: block) ? feet : nil
      driver = id; cars[i].rival=false; cars[i].root.findEntity(named:"Racing driver")?.removeFromParent(); cars[i].traffic = .parked; cars[i].physics.stop(); noticeUntil = 0
    }
    return nil
  }

  func obstructsPlayer(at feet: SIMD3<Float>) -> Bool {
    cars.contains { !$0.crushed && $0.root.isEnabled && $0.physics.overlapsPlayer(at: feet) }
  }
  func obstructsCamera(_ point: SIMD3<Float>, radius: Float) -> Bool {
    cars.contains { car in
      guard car.id != driver && car.root.isEnabled else { return false }
      let local = simd_quatf(angle: -car.physics.heading, axis: [0,1,0]).act(point - car.physics.position)
      return RocketBox([car.physics.kind.halfWidth*2, car.physics.kind.height, car.physics.kind.halfLength*2],
        [0, car.physics.kind.height/2, 0]).overlaps(center: local, radius: radius)
    }
  }

  var hasInteraction: Bool { isDriving || focused != nil }
  func safeSavePosition(block: (BlockPosition) -> Block) -> SIMD3<Float>? {
    guard var physics = cars.first(where: { $0.id == driver })?.physics else { return nil }
    physics.stop()
    return physics.exitPosition(block: block) ?? physics.roofExit(block: block)
      ?? boardingPosition.flatMap { VehiclePhysics.safeFooting(at: $0, block: block) ? $0 : nil }
  }

  private func positionModel(_ index: Int) {
    let car = cars[index]
    car.root.position = car.physics.position
    car.root.orientation = simd_quatf(angle: car.physics.heading, axis: [0, 1, 0])
    for side in 0..<2 {
      car.root.findEntity(named: "Front wheel \(side)")?.orientation = simd_quatf(angle: -car.physics.wheelAngle, axis: [0, 1, 0])
        * simd_quatf(angle: -car.wheelSpin, axis:[1,0,0])
      car.root.findEntity(named: "Rear wheel \(side)")?.orientation = simd_quatf(angle:-car.wheelSpin,axis:[1,0,0])
    }
    car.root.findEntity(named: "Steering wheel")?.orientation = simd_quatf(angle: car.physics.steering * -0.8, axis: [0, 0, 1])
  }

  func clear() {
    race=nil; circuitBlocks.removeAll()
    cars.forEach { $0.root.removeFromParent() }; cars.removeAll()
    cancelRacing(); driver = nil; focused = nil; boardingPosition = nil; previousTraffic.removeAll(); circuits.removeAll(); notice = ""; noticeUntil = 0; saved.removeAll()
  }
}
