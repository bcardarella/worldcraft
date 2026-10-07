import Foundation
import QuartzCore
import WorldCore
import os

@SimulationActor final class LifeWorker {
  private let fauna = FaunaSimulation()
  private let town = SettlementSimulation()
  private let creatures = CreatureSimulation()
  private let planner = DeliberationService()
  private var restoreStep: (@SimulationActor () -> Void)?
  private var serial: UInt64 = 0
  init() {
    fauna.planner = planner; town.homesteads.planner = planner
  }
  /// One speculative frame maximum. Commands are applied before its checkpoint,
  /// so user actions survive rejection of a stale world snapshot.
  func propose(_ frame: LifeFrame?, commands: [LifeCommand]) -> LifeProposal {
    precondition(restoreStep == nil, "Acknowledge the previous proposal first")
    let start = CACurrentMediaTime()
    let onMain = Thread.isMainThread
    let log = OSLog(subsystem: "com.worldcraft.vision", category: .pointsOfInterest)
    let signpost = OSSignpostID(log: log)
    os_signpost(.begin, log: log, name: "Actor life simulation", signpostID: signpost)
    defer { os_signpost(.end, log: log, name: "Actor life simulation", signpostID: signpost) }
    for command in commands { apply(command) }
    let undoFauna = fauna.checkpoint(), undoTown = town.checkpoint(), undoCreatures = creatures.checkpoint()
    restoreStep = { undoFauna(); undoTown(); undoCreatures() }
    var effects: [LifeEffect] = [], population = CreatureStep()
    if let frame, frame.seconds > 0 {
      let world = LifeStagingWorld(frame.world, animals: frame.animals)
      world.protectedAnimals = Set(frame.hayHayIDs)
      if let ride=frame.mount { world.protectedAnimals.insert(ride.id) }
      fauna.onEatPlant = world.eat; fauna.onHunt = world.hunt; town.homesteads.onEdit = world.edit
      let time = frame.environment.elapsed, loaded = frame.world.loaded
      let weather = WorldWeather.sample(seed: frame.world.terrain.seed, time: time, style: frame.world.terrain.style)
      let passengers=Set(frame.wildlife.filter { $0.passenger != nil }.map(\.id))
        .union(frame.companionCarrier == nil ? []:frame.hayHayIDs)
      fauna.update(actors: frame.animals.filter { !passengers.contains($0.id) }, deltaTime: frame.seconds, time: time, player: frame.player,
        offering: frame.offering, weather: weather, night: frame.environment.daylight < 0.1,
        loaded: loaded, plants: world.nearbyPlants, block: world.block)
      town.logsDecisions = frame.logs
      town.homesteads.playerFlying = frame.flying; town.homesteads.playerDriving = frame.driving
      town.update(terrain: frame.world.terrain, player: frame.player, deltaTime: frame.seconds,
        environment: frame.environment, threats: frame.threats, traffic: frame.traffic, loaded: loaded, doors:frame.world.doors, block: world.block)
      town.homesteads.updateSurvey(terrain: frame.world.terrain, chunks: frame.world.chunks, time: time)
      population = creatures.step(frame, world: world, site: town.currentSite, life: fauna)
      fauna.register(population.wildlife.filter { $0.passenger == nil }.map { .init(id: $0.id, species: String(describing: $0.kind), kind: $0.kind,
        position: $0.position, home: $0.home, trusting: $0.kind.pet || $0.bond.trusting,
        following: $0.followsPlayer(at: time)) } + population.dinosaurs.snapshots)
      effects = world.effects
      fauna.onEatPlant = nil; fauna.onHunt = nil; town.homesteads.onEdit = nil
    }
    serial &+= 1
    return .init(id: serial, view: view(), effects: effects, creatures: population,
      milliseconds: (CACurrentMediaTime() - start) * 1_000, ranOnMainThread: onMain)
  }
  func resolve(_ id: UInt64, accepted: Bool) {
    guard id == serial else { return }
    if !accepted { restoreStep?() }
    restoreStep = nil
  }
  private func apply(_ command: LifeCommand) {
    switch command {
    case .reset: creatures.clear(); town.clear(); town.restore([]); fauna.restore([]); planner.suspend()
    case .suspend: town.suspend(); fauna.suspend(); planner.suspend()
    case .restoreResidents(let people, let homes): town.restore(people, homes: homes)
    case .restoreFauna(let records): fauna.restore(records)
    case .jev(let key, let enabled): town.configureJev(key: key, enabled: enabled); fauna.configureJev(key: key, enabled: enabled)
    case .reasoning(let key, let enabled, let limit): planner.configure(key: key, enabled: enabled, hourlyLimit: limit)
    case .fed(let id, let position, let time): fauna.fed(id: id, at: position, time: time)
    case .petted(let id, let position, let time): fauna.petted(id: id, at: position, time: time)
    case .talk(let id): town.interact(with: id)
    case .edited(let p, let old, let new, let terrain, let time): town.witnessedEdit(at: p, old: old, new: new, terrain: terrain, time: time)
    case .welcome(let port, let terrain, let time): _ = town.prepareRocketWelcome(port: port, terrain: terrain, time: time)
    case .celebrate(let name, let time): town.celebrateRocketArrival(planet: name, time: time)
    }
  }
  private func view() -> LifeView {
    let records = fauna.records
    return .init(residents: town.states, residentRecords: town.records, residentPositions: town.positions, homes: town.homesteads.records,
      properties: town.homesteads.properties, fauna: records,
      faunaByID: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }), directives: fauna.directives,
      site: town.currentSite, conversation: town.conversation, welcomeReady: town.welcomeReady,
      celebrating: town.isCelebrating, decisionStatus: town.decisionStatus, faunaStatus: fauna.status,
      reasoningStatus: planner.status, decisionLatencyMilliseconds: town.decisionLatencyMilliseconds,
      acceptedDecisions: town.acceptedDecisions, rejectedDecisions: town.rejectedDecisions,
      interventions: town.homesteads.takeInterventions())
  }
}
