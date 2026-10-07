import XCTest
import WorldCore
@testable import WorldLife

@SimulationActor final class LifeSimulationTests: XCTestCase {
  let terrain = TerrainGenerator(seed: 8192)
  var village: Settlement { SettlementGenerator.site(in: .init(0, 0), terrain: terrain)! }

  func preparedHome() -> (HomesteadSimulation, OwnedHome, ResidentState) {
    let life = HomesteadSimulation(); life.configure(site: village, terrain: terrain)
    let home = life.properties[0]
    var owner = ResidentState(index: home.ownerIndex, site: village, homeOverride: life.homePosition(index: home.ownerIndex))
    owner.record.agency = .init()
    return (life, home, owner)
  }
  func advance(_ person: inout ResidentState, seconds: Int = 8) {
    for _ in 0..<seconds * 4 { person.advanceNeeds(seconds: 0.25, arrived: true, time: 100) }
  }

  func testHarvestDeliveryAndCompetingRepairConserveRealMaterials() async throws {
    let (life, home, originalOwner) = preparedHome()
    var owner = originalOwner
    let missing = home.minimum, material = home.original(at: missing, terrain: terrain)
    XCTAssertTrue(material.isSolid)
    life.edited(at: missing, old: material, new: .air, terrain: terrain, time: 50)
    let source = missing + .init(-8, 1, -8)
    var world: [BlockPosition: Block] = [source: material, missing: .air]
    func block(_ p: BlockPosition) -> Block { world[p] ?? .air }
    life.onEdit = { p, expected, replacement in
      guard block(p) == expected else { return false }
      world[p] = replacement; return true
    }
    let gather = ResidentJob(.gather, home: home.id, target: source, material: material)
    owner.position = source.center + [-1, -0.5, 0]
    owner.choose(.gather, time: 100); advance(&owner)
    XCTAssertTrue(life.execute(gather, resident: &owner, neighbors: [], player: .zero, time: 110, block: block).finished)
    XCTAssertEqual(world[source], .air)
    XCTAssertEqual(owner.record.agency?.cargo?.count, 1)
    let deliver = ResidentJob(.deliver, home: home.id, target: .init(home.entrance), material: material)
    owner.position = home.entrance
    owner.choose(.gather, time: 111)
    XCTAssertFalse(life.execute(deliver, resident: &owner, neighbors: [], player: .zero, time: 111, block: block).finished)
    advance(&owner, seconds: 1)
    XCTAssertTrue(life.execute(deliver, resident: &owner, neighbors: [], player: .zero, time: 112, block: block).finished)
    XCTAssertNil(owner.record.agency?.cargo)
    XCTAssertEqual(life.records.first { $0.id == home.id }?.stock[material], 1)
    let repair = ResidentJob(.repair, home: home.id, target: missing, material: material)
    owner.choose(.repair, time: 113); advance(&owner, seconds: 3)
    _ = life.execute(repair, resident: &owner, neighbors: [], player: .zero, time: 116, block: block)
    _ = life.execute(repair, resident: &owner, neighbors: [], player: .zero, time: 117, block: block)
    XCTAssertEqual(world[missing], material)
    XCTAssertEqual(life.records.first { $0.id == home.id }?.stock[material], 0)
    XCTAssertEqual(life.records.first { $0.id == home.id }?.completedRepairs, 1)
    XCTAssertTrue(life.isComplete(home.id))
  }

  func testFailedWorldMutationCannotGiveCargoOrConsumeRepairStock() async {
    let (life, home, original) = preparedHome()
    var owner = original
    let material = home.original(at: home.minimum, terrain: terrain)
    var saved = HomeRecord(home: home)
    saved.damage(at: home.minimum, original: material, time: 50); saved.stock.add(material)
    life.restore([saved]); life.configure(site: village, terrain: terrain)
    life.onEdit = { _, _, _ in false }
    owner.position = home.minimum.center
    owner.choose(.gather, time: 100); advance(&owner)
    _ = life.execute(.init(.gather, home: home.id, target: home.minimum, material: material),
      resident: &owner, neighbors: [], player: .zero, time: 110, block: { $0 == home.minimum ? material : .air })
    XCTAssertNil(owner.record.agency?.cargo)
    owner.choose(.repair, time: 110); advance(&owner)
    _ = life.execute(.init(.repair, home: home.id, target: home.minimum, material: material),
      resident: &owner, neighbors: [], player: .zero, time: 120, block: { _ in .air })
    XCTAssertEqual(life.records.first { $0.id == home.id }?.stock[material], 1)
    XCTAssertFalse(life.isComplete(home.id))
  }

  func testCargoCanStillBeDeliveredAfterPlayerCompletesHome() async throws {
    let (life, home, original) = preparedHome()
    var owner = original; owner.record.agency?.cargo = .init(.wood, 1)
    let options = life.options(for: owner, neighbors: [], player: [900, 50, 900], time: 100, block: { _ in .air })
    let delivery = try XCTUnwrap(options["deliver_supplies"]?.job)
    owner.choose(.gather, time: 100); advance(&owner, seconds: 1)
    _ = life.execute(delivery, resident: &owner, neighbors: [], player: .zero, time: 101, block: { _ in .air })
    XCTAssertNil(owner.record.agency?.cargo)
    XCTAssertEqual(life.records.first { $0.id == home.id }?.stock[.wood], 1)
  }

  func testHelpersChooseWhetherToJoinAndRememberAcceptance() async throws {
    let (life, home, owner) = preparedHome()
    life.edited(at: home.minimum, old: home.original(at: home.minimum, terrain: terrain), new: .air, terrain: terrain, time: 50)
    var friend = (0..<village.population).map { ResidentState(index: $0, site: village) }.first { $0.role == .builder && $0.id != owner.id }!
    friend.record.agency = .init(); friend.record.agency?.invitationHome = home.id
    let options = life.options(for: friend, neighbors: [owner], player: [900, 50, 900], time: 100, block: { _ in .air })
    XCTAssertNotNil(options["decline_help"])
    let accept = try XCTUnwrap(options["assist_home"]?.job)
    _ = life.execute(accept, resident: &friend, neighbors: [owner], player: .zero, time: 101, block: { _ in .air })
    XCTAssertEqual(friend.record.agency?.helpingHome, home.id)
    XCTAssertNil(friend.record.agency?.invitationHome)
    XCTAssertTrue(friend.record.agency?.memory.experiences.contains { $0.kind == .helped } == true)
    XCTAssertNotNil(friend.record.relationships.first { $0.otherID == owner.id })
  }

  func testRestoredAnimalSpeciesRemainsAvailableToSpawner() async {
    let life = FaunaSimulation()
    var record = FaunaRecord(id: 321, species: "otter", home: [0.5, 30, 0.5])
    record.memory.remember(.fedByPlayer, "A familiar player", time: 45, importance: 0.7)
    life.restore([record])
    XCTAssertEqual(life.knownKind(id: 321), .otter)
    XCTAssertNil(life.knownKind(id: 999))
    XCTAssertEqual(life.records.first?.memory.experiences.first?.detail, "A familiar player")
  }

  func testEcologyConsumesARealPlantAndRemembersFeedingPlace() async {
    let life = FaunaSimulation()
    var record = FaunaRecord(id: 7, species: "deer", home: [0.5, 30, 0.5]); record.hunger = 0.9; record.thirst = 0
    life.restore([record])
    let p = BlockPosition(1, 30, 0)
    var exists = true, eaten = 0
    life.onEatPlant = { point, kind in
      guard exists, point == p, kind == .grass else { return false }
      exists = false; eaten += 1; return true
    }
    let actor = FaunaSnapshot(id: 7, species: "deer", kind: .deer, position: record.position, home: record.home)
    let loaded: Set<ChunkCoordinate> = [.init(0, 0), .init(-1, 0), .init(0, -1), .init(-1, -1)]
    for n in 0..<40 {
      life.update(actors: [actor], deltaTime: 0.1, time: 100 + Double(n) * 0.1, player: [100, 30, 100],
        offering: nil, weather: .sample(seed: 0, time: 0, style: .verdant), night: false,
        loaded: loaded, plants: { _ in exists ? [.init(position: p, kind: .grass)] : [] }, block: { $0.y < 30 ? .dirt : .air })
    }
    XCTAssertEqual(eaten, 1)
    XCTAssertLessThan(life.records.first!.hunger, 0.6)
    XCTAssertTrue(life.records.first!.memory.experiences.contains { $0.kind == .foundFood && $0.point == p })
  }

  func testPredationRequiresContactAndPersistsAbsenceAcrossRestore() async {
    let life = FaunaSimulation()
    var predator = FaunaRecord(id: 9, species: "wolf", home: [0.5, 30, 0.5]); predator.hunger = 0.9; predator.thirst = 0
    let prey = FaunaRecord(id: 10, species: "rabbit", home: [1.5, 30, 0.5])
    life.restore([predator, prey]); var captures = 0
    life.onHunt = { id in guard id == prey.id && captures == 0 else { return false }; captures += 1; return true }
    let actors: [FaunaSnapshot] = [
      .init(id: 9, species: "wolf", kind: .wolf, position: predator.position, home: predator.home),
      .init(id: 10, species: "rabbit", kind: .rabbit, position: prey.position, home: prey.home)]
    for n in 0..<30 {
      life.update(actors: actors, deltaTime: 0.1, time: 100 + Double(n) * 0.1, player: [100, 30, 100], offering: nil,
        weather: .sample(seed: 0, time: 0, style: .verdant), night: false, loaded: [.init(0, 0)],
        plants: { _ in [] }, block: { $0.y < 30 ? .dirt : .air })
    }
    XCTAssertEqual(captures, 1); XCTAssertFalse(life.canSpawn(id: 10, time: 110))
    let restored = FaunaSimulation(); restored.restore(life.records)
    XCTAssertFalse(restored.canSpawn(id: 10, time: 110))
    XCTAssertTrue(restored.canSpawn(id: 10, time: 110 + WorldEnvironment.dayDuration))
  }

  func testTyrannosaurFamiliesDoNotTreatEachOtherAsPrey() async {
    let life = FaunaSimulation()
    let actors: [FaunaSnapshot] = [
      .init(id: 1, species: "trex", kind: nil, position: [0, 30, 0], home: [0, 30, 0]),
      .init(id: 2, species: "trex", kind: nil, position: [1, 30, 0], home: [1, 30, 0])]
    life.update(actors: actors, deltaTime: 0.1, time: 100, player: [100, 30, 100], offering: nil,
      weather: .sample(seed: 0, time: 0, style: .verdant), night: false, loaded: [.init(0, 0)],
      plants: { _ in [] }, block: { $0.y < 30 ? .dirt : .air })
    XCTAssertFalse(life.records.contains { $0.goal == .flee || $0.goal == .hunt })
  }

  func testAnimalSeeksVerifiedWaterAndDrinksOnlyAfterArrival() async throws {
    let life = FaunaSimulation()
    var record = FaunaRecord(id: 6, species: "deer", home: [0.5, 30, 0.5])
    record.hunger = 0; record.thirst = 0.9
    life.restore([record])
    var point = record.position
    func block(_ p: BlockPosition) -> Block { p == .init(4, 30, 0) ? .water : p.y < 30 ? .dirt : .air }
    func tick(_ time: Double) {
      life.update(actors: [.init(id: 6, species: "deer", kind: .deer, position: point, home: record.home)],
        deltaTime: 0.1, time: time, player: [100, 30, 100], offering: nil,
        weather: .sample(seed: 0, time: 0, style: .verdant), night: false,
        loaded: [.init(0, 0), .init(-1, 0), .init(0, -1), .init(-1, -1)], plants: { _ in [] }, block: block)
    }
    tick(100)
    let destination = try XCTUnwrap(life.directive(id: 6))
    XCTAssertEqual(destination.goal, .drink)
    XCTAssertGreaterThanOrEqual(life.records.first!.thirst, 0.9)
    point = destination.point.center - [0, 0.5, 0]
    for i in 1..<32 { tick(100 + Double(i) * 0.1) }
    XCTAssertLessThan(life.records.first!.thirst, 0.3)
    XCTAssertTrue(life.records.first!.memory.experiences.contains { $0.kind == .foundWater })
  }

  func testRainShelterIsActualOverheadCoverAndNightUsesHabitualHome() async throws {
    let life = FaunaSimulation()
    var record = FaunaRecord(id: 8, species: "sheep", home: [0.5, 30, 0.5])
    record.hunger = 0; record.thirst = 0; record.fatigue = 0.5
    life.restore([record])
    let rain = try XCTUnwrap((0..<100).map { WorldWeather.sample(seed: UInt64($0), time: 80, style: .verdant) }.first { $0.wet })
    var point = record.position
    func tick(_ time: Double, weather: WorldWeather, night: Bool) {
      life.update(actors: [.init(id: 8, species: "sheep", kind: .sheep, position: point, home: record.home)],
        deltaTime: 0.1, time: time, player: [100, 30, 100], offering: nil,
        weather: weather, night: night, loaded: [.init(0, 0), .init(-1, 0), .init(0, -1), .init(-1, -1)],
        plants: { _ in [] }, block: { $0 == .init(3, 35, 0) || $0.y < 30 ? .stone : .air })
    }
    tick(100, weather: rain, night: false)
    let shelter = try XCTUnwrap(life.directive(id: 8))
    XCTAssertEqual(shelter.goal, .shelter)
    point = shelter.point.center - [0, 0.5, 0]
    for i in 1..<20 { tick(100 + Double(i) * 0.1, weather: rain, night: false) }
    XCTAssertTrue(life.records.first!.memory.experiences.contains { $0.kind == .foundShelter })
    let dry = WorldWeather.sample(seed: 0, time: 0, style: .verdant)
    for i in 20..<45 { tick(100 + Double(i) * 0.1, weather: dry, night: true) }
    XCTAssertEqual(life.directive(id: 8)?.goal, .returnHome)
    XCTAssertEqual(life.directive(id: 8)?.point, BlockPosition(record.home))
  }

  func testAquaResidentsCanApproachSubmergedRawMaterials() async throws {
    var reef = village; reef.habitat = .aquatic; reef.waterLevel = Float(reef.floor + 20)
    let life = HomesteadSimulation(); life.configure(site: reef, terrain: terrain)
    let home = try XCTUnwrap(life.properties.first)
    let resident = ResidentState(index: home.ownerIndex, site: reef)
    let source = BlockPosition(0, 20, 0)
    func water(_ p: BlockPosition) -> Block { p.y <= 20 ? .stone : p.y < 40 ? .water : .air }
    let destination = life.destination(.init(.gather, home: home.id, target: source, material: .stone),
      resident: resident, block: water)
    XCTAssertNotNil(ResidentNavigation.swimPosition(at: destination, block: water))
    XCTAssertGreaterThan(destination.y, Float(source.y))
  }
}
