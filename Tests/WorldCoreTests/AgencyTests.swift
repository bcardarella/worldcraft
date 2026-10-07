import Foundation
import XCTest
@testable import WorldCore

final class AgencyTests: XCTestCase {
  private let terrain = TerrainGenerator(seed: 8192)
  private var village: Settlement { SettlementGenerator.site(in: .init(0, 0), terrain: terrain)! }

  func testMemoriesConsolidateAndProtectSalientExperiences() throws {
    var memory = AgentMemory()
    let home = BlockPosition(1, 30, 2)
    memory.remember(.homeDamaged, "My home was damaged", at: home, time: 1, importance: 1)
    for i in 0..<80 {
      memory.remember(.foundFood, "Grass", at: .init(i, 30, 0), time: Double(i + 2), importance: 0.1)
    }
    XCTAssertEqual(memory.experiences.count, 32)
    XCTAssertTrue(memory.experiences.contains { $0.kind == .homeDamaged })
    memory.remember(.homeDamaged, "Damage happened again", at: home, time: 90, importance: 0.7)
    XCTAssertEqual(memory.experiences.first { $0.kind == .homeDamaged }?.occurrences, 2)
    XCTAssertEqual(memory.recall(time: 91, relevant: [.homeDamaged]).first?.detail, "Damage happened again")
    XCTAssertEqual(try JSONDecoder().decode(AgentMemory.self, from: JSONEncoder().encode(memory)), memory)
    memory.remember(.danger, "Invalid", at: .init(Int.max, 30, 0), time: 0)
    XCTAssertTrue(memory.isValid)
  }

  func testHomesHaveStableOwnersAndExcludeRoadsAndSpaceports() {
    for style in PlanetStyle.allCases {
      let generator = TerrainGenerator(seed: 8192, style: style)
      guard let site = (-3...3).lazy.flatMap({ x in (-3...3).compactMap { SettlementGenerator.site(in: .init(x, $0), terrain: generator) } }).first else {
        XCTFail("Expected inhabited planet \(style)"); continue
      }
      let homes = OwnedHome.properties(in: site, terrain: generator)
      XCTAssertFalse(homes.isEmpty)
      XCTAssertEqual(homes.map(\.id), OwnedHome.properties(in: site, terrain: generator).map(\.id))
      XCTAssertEqual(Set(homes.map(\.id)).count, homes.count)
      for home in homes {
        XCTAssertEqual(home.ownerID, ResidentState.id(index: home.ownerIndex, site: site))
        XCTAssertFalse(home.contains(.init(site.x, site.floor + 1, site.z)))
        if let port = site.rocketPort {
          XCTAssertFalse(home.contains(.init(port.center)))
        }
        XCTAssertTrue(home.original(at: home.minimum, terrain: generator).isSolid)
      }
    }
  }

  func testHomeDamageAndRepairAreIdempotentAndUseBottomUpOrder() {
    let home = OwnedHome.properties(in: village, terrain: terrain)[0]
    var record = HomeRecord(home: home)
    let a = home.minimum + .init(0, 3, 0), b = home.minimum + .init(0, 1, 0)
    record.damage(at: a, original: .brick, time: 5)
    let incident = record.incident
    record.damage(at: a, original: .brick, time: 6)
    record.damage(at: b, original: .wood, time: 7)
    XCTAssertEqual(record.repairs.map(\.position), [b, a])
    XCTAssertEqual(record.incident, incident)
    record.acknowledgeRepair(at: b); record.acknowledgeRepair(at: b)
    XCTAssertEqual(record.completedRepairs, 1)
    XCTAssertTrue(record.isValid)
    record.acknowledgeRepair(at: a)
    record.damage(at: a, original: .brick, time: 9)
    XCTAssertNotEqual(record.incident, incident)
  }

  func testRecipesConserveInputsAndCannotDoubleSpend() {
    var stock = MaterialStock()
    stock.add(.dirt, count: 2); stock.add(.sand); stock.add(.wood)
    XCTAssertFalse(VillageRecipe.firedBrick.make(in: &stock, role: .musician))
    XCTAssertTrue(VillageRecipe.firedBrick.make(in: &stock, role: .builder))
    XCTAssertEqual(stock[.brick], 2); XCTAssertEqual(stock[.dirt], 0)
    XCTAssertEqual(stock[.wood], 0); XCTAssertEqual(stock[.sand], 0)
    let before = stock
    XCTAssertFalse(stock.consume([.init(.brick, 2), .init(.brick, 1)]))
    XCTAssertEqual(stock, before)
    XCTAssertFalse(VillageRecipe.firedBrick.make(in: &stock, role: .builder))
    XCTAssertFalse(stock.add(.air)); XCTAssertFalse(stock.add(.water))
    XCTAssertTrue(stock.consume([.init(.brick, 1)])); XCTAssertEqual(stock[.brick], 1)
    XCTAssertTrue(stock.isValid)
  }

  func testDefenseAccountsForAbilityNearbyAlliesFlightAndVehicles() {
    var people = (0..<village.population).map { ResidentState(index: $0, site: village) }
    for i in people.indices { people[i].position = [0, 30, 0]; people[i].record.fatigue = 0 }
    let guardNPC = people.first { $0.role == .guard }!
    let ordinary = people.first { ![.guard, .builder].contains($0.role) }!
    XCTAssertFalse(HomeDefense.canIntervene(resident: ordinary, allies: [], player: [2, 30, 0], flying: false, driving: false))
    XCTAssertTrue(HomeDefense.canIntervene(resident: ordinary, allies: [guardNPC], player: [2, 30, 0], flying: false, driving: false))
    XCTAssertTrue(HomeDefense.canIntervene(resident: guardNPC, allies: [], player: [2, 30, 0], flying: false, driving: false))
    XCTAssertFalse(HomeDefense.canIntervene(resident: guardNPC, allies: people, player: [2, 30, 0], flying: true, driving: false))
    XCTAssertFalse(HomeDefense.canIntervene(resident: guardNPC, allies: people, player: [2, 30, 0], flying: false, driving: true))
    var distant = guardNPC; distant.position.x = 100
    XCTAssertFalse(HomeDefense.canIntervene(resident: ordinary, allies: [distant], player: [2, 30, 0], flying: false, driving: false))
  }

  func testFriendshipsAndHelpfulWorkBecomeLongTermMemories() {
    var resident = ResidentState(index: 0, site: village)
    let neighbor = ResidentState.id(index: 1, site: village)
    resident.meet(neighbor, helping: true, time: 1)
    resident.meet(neighbor, helping: true, time: 2)
    resident.meet(neighbor, helping: true, time: 3)
    XCTAssertTrue(HomeDefense.willingToHelp(resident, requester: neighbor))
    XCTAssertEqual(resident.record.agency?.memory.experiences.first?.occurrences, 3)
    XCTAssertTrue(resident.record.isValid)
  }

  func testBudgetReservationsSurviveRestartCancelAndUnknownCosts() throws {
    var budget = ReasoningBudget()
    let id = try XCTUnwrap(budget.begin(at: 100, reservation: 0.01))
    XCTAssertNil(budget.begin(at: 200, reservation: 0.01), "Only one concurrent request")
    budget.fail(id, at: 110)
    XCTAssertEqual(budget.spent(at: 111), 0.01)
    var restored = ReasoningBudget(charges: try JSONDecoder().decode([ReasoningCharge].self, from: JSONEncoder().encode(budget.charges)))
    XCTAssertNil(restored.begin(at: 120, reservation: 0.01), "Restart keeps the request interval")
    let next = try XCTUnwrap(restored.begin(at: 161, reservation: 0.03))
    restored.complete(next, actualCost: nil)
    XCTAssertNil(restored.begin(at: 222, reservation: 0.011), "Reserve full worst-case cost before sending")
    XCTAssertEqual(restored.spent(at: 223), 0.04, accuracy: 0.000_001)
    XCTAssertNotNil(restored.begin(at: 3_762, reservation: 0.05))
  }

  func testBudgetAccountsForActualCostAndLimitsRequestRate() throws {
    var budget = ReasoningBudget()
    for n in 0..<60 {
      let time = Double(n * 60 + 1)
      let id = try XCTUnwrap(budget.begin(at: time, reservation: 0.0005))
      budget.complete(id, actualCost: 0.0001)
      XCTAssertNil(budget.begin(at: time + 1, reservation: 0.0005))
    }
    XCTAssertEqual(budget.spent(at: 3_600), 0.006, accuracy: 0.000_001)
    XCTAssertNil(budget.begin(at: 3_600, reservation: 0.001))
    XCTAssertNotNil(budget.begin(at: 3_601, reservation: 0.001))
  }

  func testEcologyNeedsDietsWeatherAndHabitualHomes() {
    var animal = FaunaRecord(id: 2, species: "deer", home: [2, 30, 4])
    animal.hunger = 0.9; animal.thirst = 0.9
    let choices: Set<AnimalGoal> = [.forage, .drink, .shelter, .returnHome, .explore]
    XCTAssertEqual(animal.localChoice(available: choices, night: true, raining: true, hungryPredator: false), .drink)
    animal.drink(seconds: 10, at: .init(2, 30, 4), time: 2)
    XCTAssertGreaterThan(animal.thirst, 0.8, "Large time steps cannot instantly satisfy needs")
    animal.thirst = 0; animal.eat(at: .init(4, 30, 4), time: 3)
    XCTAssertEqual(animal.localChoice(available: choices, night: true, raining: true, hungryPredator: false), .shelter)
    XCTAssertEqual(animal.localChoice(available: choices, night: true, raining: false, hungryPredator: false), .returnHome)
    XCTAssertEqual(animal.home, [2, 30, 4])
    XCTAssertTrue(AnimalKind.deer.forages(.grass)); XCTAssertFalse(AnimalKind.wolf.forages(.grass))
    XCTAssertTrue(AnimalKind.wolf.prey.contains(.rabbit)); XCTAssertFalse(AnimalKind.deer.prey.contains(.rabbit))
    XCTAssertTrue(AnimalKind.duck.migratory); XCTAssertFalse(AnimalKind.sheep.migratory)
    XCTAssertTrue((0..<100).contains { WorldWeather.sample(seed: UInt64($0), time: 80, style: .verdant).wet })
    XCTAssertFalse(WorldWeather.sample(seed: 0, time: 80, style: .solar).wet)
    XCTAssertTrue(animal.isValid)
  }

  func testDirectedMovementReachesFoodInsteadOfSleepingInPlaceAtNight() throws {
    var animal: AnimalState?
    for x in -10...10 {
      if let candidate = AnimalState.spawn(in: .init(x, 0), generator: terrain, block: terrain.block), !candidate.kind.aquatic { animal = candidate; break }
    }
    var actor = try XCTUnwrap(animal)
    actor.position = [0.5, 30, 0.5]; actor.heading = 0
    let option = AnimalDecisionOption(.forage, at: .init(0, 30, -8), plant: .grass, description: "Eat grass")
    for _ in 0..<180 { actor.update(deltaTime: 1 / 60, time: 1_000, player: [100, 30, 100], directive: option, block: { $0.y < 30 ? .dirt : .air }) }
    XCTAssertLessThan(actor.position.z, -3)
    XCTAssertFalse(actor.resting)
  }

  func testAgencySavesKeepPlanetHistoriesAndRejectInvalidRecords() throws {
    let home = OwnedHome.properties(in: village, terrain: terrain)[0]
    var house = HomeRecord(home: home); house.damage(at: home.minimum, original: .wood, time: 10)
    var animal = FaunaRecord(id: 1, species: "sheep", home: [1, 30, 1])
    animal.memory.remember(.fedByPlayer, "A friendly visitor", time: 2)
    var save = WorldSave(seed: 8192, edits: [], player: [0, 30, 0], flying: false, heading: 0, selectedSlot: 0,
      visitedPlanets: [.init(index: 1, edits: [], player: [0, 30, 0], heading: 0, worldTime: 20, homes: [house], fauna: [animal])],
      homes: [house], fauna: [animal])
    let decoded = try JSONDecoder().decode(WorldSave.self, from: JSONEncoder().encode(save))
    XCTAssertTrue(decoded.isValid); XCTAssertEqual(decoded.homes?.first?.repairs.count, 1)
    XCTAssertEqual(decoded.visitedPlanets?.first?.fauna?.first?.memory.experiences.first?.kind, .fedByPlayer)
    save.fauna = [animal, animal]; XCTAssertFalse(save.isValid)
    animal.hunger = .nan; save.fauna = [animal]; XCTAssertFalse(save.isValid)
  }

  func testPenguinCanEnterWaterToHuntAndReturnToLand() {
    var penguin = AnimalState(id: 1, kind: .penguin, home: [0.5, 30, 0.5], position: [0.5, 30, 0.5], heading: 0)
    func block(_ p: BlockPosition) -> Block {
      if p.z < 0 { return p.y < 26 ? .stone : p.y < 30 ? .water : .air }
      return p.y < 30 ? .stone : .air
    }
    let hunt = AnimalDecisionOption(.hunt, at: .init(0, 27, -7), preyID: 2, description: "Catch fish")
    for _ in 0..<300 { penguin.update(deltaTime: 1 / 60, time: 100, player: [100, 30, 100], directive: hunt, block: block) }
    XCTAssertLessThan(penguin.position.z, -4); XCTAssertLessThan(penguin.position.y, 29)
    let home = AnimalDecisionOption(.returnHome, at: .init(0, 30, 1), description: "Return to shore")
    for _ in 0..<800 { penguin.update(deltaTime: 1 / 60, time: 100, player: [100, 30, 100], directive: home, block: block) }
    XCTAssertGreaterThanOrEqual(penguin.position.z, 0)
    XCTAssertEqual(penguin.position.y, 30, accuracy: 0.02)
  }
}
