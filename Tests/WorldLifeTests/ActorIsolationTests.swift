import XCTest
import QuartzCore
@testable import WorldCore
@testable import WorldLife

private enum ActorFixture {
  @SimulationActor static func hold(_ released: DispatchSemaphore, entered: CheckedContinuation<Bool, Never>) {
    entered.resume(returning: Thread.isMainThread)
    _ = released.wait(timeout: .now() + 5)
  }
  static let record: FaunaRecord = {
    var record = FaunaRecord(id: 7, species: "deer", home: [8.5, 30, 8.5])
    record.hunger = 0.9; record.thirst = 0; record.fatigue = 0
    return record
  }()
  static func frame(time: Double = 100, revision: UInt64 = 0, player: SIMD3<Float> = [100, 30, 100]) -> LifeFrame {
    let coordinate = ChunkCoordinate(0, 0)
    var chunk = ChunkData(coordinate: coordinate)
    for x in -1...16 { for z in -1...16 { chunk[x, 29, z] = .grass } }
    let plant = PlantInstance(position: .init(9, 30, 8), kind: .grass)
    let animal = FaunaSnapshot(id: record.id, species: record.species, kind: .deer, position: record.position, home: record.home)
    return .init(world: .init(terrain: .init(seed: 8192, style: .solar), chunks: [coordinate: chunk],
      plants: [coordinate: [plant]], obstacle: nil, revision: revision), environment: .init(elapsed: time),
      player: player, seconds: 0.1, animals: [animal], wildlife: [], threats: [], offering: nil,
      flying: false, driving: false, logs: false)
  }
}

@SimulationActor final class ActorTransactionTests: XCTestCase {
  func testTramplingRemovesPlantsAndPreservesTheInputSnapshot() async throws {
    let frame=ActorFixture.frame()
    let world=LifeStagingWorld(frame.world,animals:[])
    let ground=BlockPosition(9,29,8)
    world.trample([.init(position:ground,material:.grass)])
    XCTAssertEqual(world.block(ground),.air)
    XCTAssertEqual(frame.world.block(ground),.grass)
    XCTAssertTrue(world.nearbyPlants([9,30,8]).isEmpty)
    guard case .trample(let blocks,let plants)=try XCTUnwrap(world.effects.first) else { return XCTFail("Missing crush batch") }
    XCTAssertEqual(blocks.count,1); XCTAssertEqual(plants.map(\.position),[.init(9,30,8)])
    world.trample([.init(position:ground,material:.grass)])
    XCTAssertEqual(world.effects.count,1,"Overlapping sweeps cannot duplicate damage")
  }
  func testRejectedConsumptionRestoresNeedsAndRetriesWithoutDuplicatingFood() async throws {
    let worker = LifeWorker()
    var before = ActorFixture.record
    for tick in 0..<50 {
      let frame = ActorFixture.frame(time: 100 + Double(tick) * 0.1)
      let proposal = worker.propose(frame, commands: tick == 0 ? [.restoreFauna([before])] : [])
      XCTAssertFalse(proposal.ranOnMainThread)
      if !proposal.effects.isEmpty {
        XCTAssertEqual(proposal.effects, [.eat(.init(9, 30, 8), .grass)])
        worker.resolve(proposal.id, accepted: false)
        let restored = worker.propose(nil, commands: [])
        let record = try XCTUnwrap(restored.view.fauna.first { $0.id == before.id })
        XCTAssertEqual(record.hunger, before.hunger)
        XCTAssertFalse(record.memory.experiences.contains { $0.kind == .foundFood })
        worker.resolve(restored.id, accepted: true)
        let retry = worker.propose(frame, commands: [])
        XCTAssertEqual(retry.effects, proposal.effects)
        XCTAssertLessThan(try XCTUnwrap(retry.view.fauna.first { $0.id == before.id }).hunger, before.hunger)
        worker.resolve(retry.id, accepted: true)
        return
      }
      before = try XCTUnwrap(proposal.view.fauna.first { $0.id == before.id })
      worker.resolve(proposal.id, accepted: true)
    }
    XCTFail("The hungry animal never reached its verified food")
  }

  func testPlayerCommandSurvivesRejectionAndIsNotAppliedTwice() async throws {
    let worker = LifeWorker()
    let initial = worker.propose(ActorFixture.frame(), commands: [.restoreFauna([ActorFixture.record])])
    worker.resolve(initial.id, accepted: true)
    let before = try XCTUnwrap(initial.view.fauna.first { $0.id == 7 })
    let next = worker.propose(ActorFixture.frame(time: 101), commands: [.fed(7, before.position, 101)])
    worker.resolve(next.id, accepted: false)
    let save = worker.propose(nil, commands: [.suspend])
    let record = try XCTUnwrap(save.view.fauna.first { $0.id == 7 })
    XCTAssertEqual(record.hunger, max(0, before.hunger - 0.4), accuracy: 0.00001)
    XCTAssertEqual(record.memory.experiences.filter { $0.kind == .fedByPlayer }.count, 1)
    worker.resolve(save.id, accepted: true)
  }

  func testStagedEffectsHaveBoundedUniqueTargetsAndNeverMutateSnapshot() async {
    let frame = ActorFixture.frame()
    let world = LifeStagingWorld(frame.world, animals: frame.animals)
    let point = BlockPosition(9, 30, 8)
    XCTAssertTrue(world.eat(point, .grass)); XCTAssertFalse(world.eat(point, .grass))
    XCTAssertTrue(world.hunt(7)); XCTAssertFalse(world.hunt(7)); XCTAssertFalse(world.hunt(999))
    for x in 0..<6 { XCTAssertTrue(world.edit(.init(x, 29, 0), .grass, .air)) }
    XCTAssertFalse(world.edit(.init(7, 29, 0), .grass, .air))
    XCTAssertEqual(world.effects.count, 8)
    XCTAssertEqual(world.block(.init(0, 29, 0)), .air)
    XCTAssertEqual(frame.world.block(.init(0, 29, 0)), .grass)
    XCTAssertEqual(frame.world.plants[point.chunk]?.count, 1)
  }

  func testCheckpointRestoresRepairStockAndIncident() async throws {
    let terrain = TerrainGenerator(seed: 8192)
    let site = try XCTUnwrap(SettlementGenerator.site(in: .init(0, 0), terrain: terrain))
    let life = HomesteadSimulation(); life.configure(site: site, terrain: terrain)
    let home = try XCTUnwrap(life.properties.first), material = home.original(at: home.minimum, terrain: terrain)
    var record = HomeRecord(home: home)
    record.damage(at: home.minimum, original: material, time: 50); record.stock.add(material)
    life.restore([record]); life.configure(site: site, terrain: terrain)
    let rollback = life.checkpoint()
    var person = ResidentState(index: home.ownerIndex, site: site)
    person.record.agency = .init(); person.position = home.minimum.center
    person.choose(.repair, time: 100)
    for _ in 0..<16 { person.advanceNeeds(seconds: 0.25, arrived: true, time: 104) }
    life.onEdit = { _, _, _ in true }
    _ = life.execute(.init(.repair, home: home.id, target: home.minimum, material: material),
      resident: &person, neighbors: [], player: [900, 30, 900], time: 104, block: { _ in .air })
    XCTAssertEqual(life.records.first { $0.id == home.id }?.stock[material], 0)
    rollback()
    XCTAssertEqual(life.records.first { $0.id == home.id }?.stock[material], 1)
    XCTAssertFalse(life.isComplete(home.id))
  }

  func testDinosaurMotorUsesSameCollisionAndChompRulesOnActor() async throws {
    let creatures = CreatureSimulation(), life = FaunaSimulation()
    var frame = ActorFixture.frame(player: [8, 30, 20])
    let rex = RexState(id: 12, color: .pink, baby: false, position: [8, 30, 8])
    frame.dinosaurs.families[.init(0, 0)] = [rex]
    var expected = rex
    let _ = expected.update(deltaTime: 0.05, time: frame.environment.elapsed, player: frame.player, block: frame.world.block)
    let result = creatures.step(frame, world: .init(frame.world, animals: []), site: nil, life: life)
    let actual = try XCTUnwrap(result.dinosaurs.families[.init(0, 0)]?.first { $0.id == rex.id })
    XCTAssertEqual(actual.position, expected.position)
    XCTAssertEqual(actual.heading, expected.heading)
    XCTAssertEqual(actual.mood, expected.mood)
    XCTAssertEqual(actual.jaw, expected.jaw)
  }
}

@MainActor final class LifeCoordinatorTests: XCTestCase {
  // Hold the real executor to model expensive synchronous AI work. MainActor
  // must remain usable and must never wait on this semaphore. Timeout is only
  // a failsafe; tests release it explicitly without sleeping on MainActor.
  private func holdSimulation(until released: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { resumed in
      Task { @SimulationActor in
        ActorFixture.hold(released, entered: resumed)
      }
    }
  }
  func testBusyAILeavesMainActorResponsiveAndCoalescesFrameSnapshots() async {
    let coordinator = LifeCoordinator(), released = DispatchSemaphore(value: 0)
    coordinator.currentWorldRevision = { 0 }
    let fixture = ActorFixture.frame()
    let onMain = await holdSimulation(until: released)
    XCTAssertFalse(onMain)
    var captures = 0
    for _ in 0..<180 {
      coordinator.tick(seconds: 1 / 90) { _ in captures += 1; return fixture }
      // This is synchronous UI work while the simulation executor is blocked.
      XCTAssertTrue(Thread.isMainThread)
    }
    XCTAssertEqual(captures, 1)
    XCTAssertTrue(coordinator.busy)
    XCTAssertGreaterThan(coordinator.coalescedFrames, 170)
    released.signal()
    await coordinator.flush()
    XCTAssertFalse(coordinator.busy)
    XCTAssertEqual(coordinator.completedFrames, 1)
    XCTAssertEqual(coordinator.mainThreadViolations, 0)
  }
  func testWorldEditInvalidatesInFlightResultBeforePublishingEffects() async {
    let coordinator = LifeCoordinator(), released = DispatchSemaphore(value: 0)
    var revision: UInt64 = 0, publications = 0, mutations = 0
    coordinator.currentWorldRevision = { revision }
    coordinator.onApplied = { _ in publications += 1 }
    coordinator.commitEffects = { _ in mutations += 1; return true }
    _ = await holdSimulation(until: released)
    coordinator.tick(seconds: 0.1) { _ in ActorFixture.frame() }
    revision += 1
    released.signal(); await coordinator.flush()
    XCTAssertEqual(publications, 0); XCTAssertEqual(mutations, 0)
    XCTAssertEqual(coordinator.rejectedFrames, 1)
    XCTAssertTrue(coordinator.fauna.records.isEmpty)
  }
  func testResetDiscardsOldPlanetAndFlushPersistsNewestCommands() async {
    let coordinator = LifeCoordinator(), released = DispatchSemaphore(value: 0)
    coordinator.currentWorldRevision = { 0 }
    _ = await holdSimulation(until: released)
    coordinator.tick(seconds: 0.1) { _ in ActorFixture.frame() }
    coordinator.reset()
    let newPlanet = FaunaRecord(id: 999, species: "dog", home: [8, 30, 8])
    coordinator.fauna.restore([newPlanet])
    released.signal(); await coordinator.flush()
    XCTAssertEqual(coordinator.fauna.records.map(\.id), [999])
    XCTAssertEqual(coordinator.pendingCommandCount, 0)
    XCTAssertFalse(coordinator.busy)
    XCTAssertGreaterThan(coordinator.rejectedFrames, 0)
  }
}
