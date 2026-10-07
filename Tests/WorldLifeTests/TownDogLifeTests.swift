import XCTest
import simd
import WorldCore
@testable import WorldLife

@SimulationActor final class TownDogLifeTests: XCTestCase {
  let loaded = Set((-3...3).flatMap { x in (-3...3).map { ChunkCoordinate(x, $0) } })
  let dry = WorldWeather.sample(seed: 0, time: 0, style: .verdant)
  var dog: FaunaSnapshot { .init(id: 45, species: "dog", kind: .dog, position: [0.5, 30, 0.5], home: [0.5, 30, 0.5]) }
  func record(hunger: Float = 0.01, thirst: Float = 0, fatigue: Float = 0) -> FaunaRecord {
    var value = FaunaRecord(id: dog.id, species: "dog", home: dog.home)
    value.hunger = hunger; value.thirst = thirst; value.fatigue = fatigue
    return value
  }
  func tick(_ life: FaunaSimulation, frame: Int = 0, actor: FaunaSnapshot? = nil, player: SIMD3<Float> = [100, 30, 100],
    offering: AnimalFood? = nil, plants: [PlantInstance] = [], weather: WorldWeather? = nil, night: Bool = false,
    block: (BlockPosition) -> Block = { $0.y < 30 ? .grass : .air }) {
    life.update(actors: [actor ?? dog], deltaTime: 0.1, time: 100 + Double(frame) / 10,
      player: player, offering: offering, weather: weather ?? dry, night: night, loaded: loaded,
      plants: { _ in plants }, block: block)
  }

  func testStrangerIsGreetedWithoutFeedingAndRemembered() async {
    let life = FaunaSimulation(); life.restore([record()])
    tick(life, player: [2, 30, 0.5])
    XCTAssertEqual(life.directive(id: dog.id)?.goal, .greetPlayer)
    for frame in 1..<23 { tick(life, frame: frame, player: [2, 30, 0.5]) }
    XCTAssertTrue(life.records[0].memory.experiences.contains { $0.kind == .metPlayer })
    XCTAssertFalse(dog.predator)
  }

  func testOfferedFoodInterruptsSniffingEvenWhenFullButBeggingCannotFeedIt() async {
    let life = FaunaSimulation(); life.restore([record()])
    tick(life)
    XCTAssertEqual(life.directive(id: dog.id)?.goal, .sniff)
    for frame in 1..<22 { tick(life, frame: frame, player: [2, 30, 0.5], offering: .berries) }
    XCTAssertEqual(life.directive(id: dog.id)?.goal, .beg)
    for frame in 22..<55 { tick(life, frame: frame, player: [2, 30, 0.5], offering: .berries) }
    XCTAssertGreaterThan(life.records[0].hunger, 0.01)
    XCTAssertFalse(life.records[0].memory.experiences.contains { $0.kind == .fedByPlayer || $0.kind == .foundFood })
  }

  func testDogActuallyConsumesABerryPlantButDoesNotHuntOrEatUnrelatedPlants() async {
    let life = FaunaSimulation(); life.restore([record(hunger: 0.2)])
    let berry = PlantInstance(position: .init(1, 30, 0), kind: .berryBush)
    var consumed = false
    life.onEatPlant = { point, kind in
      guard !consumed, point == berry.position, kind == .berryBush else { return false }
      consumed = true; return true
    }
    for frame in 0..<30 { tick(life, frame: frame, plants: consumed ? [] : [berry]) }
    XCTAssertTrue(consumed)
    XCTAssertLessThan(life.records[0].hunger, 0.1)
    XCTAssertTrue(life.records[0].memory.experiences.contains { $0.kind == .foundFood })
    XCTAssertFalse(AnimalKind.dog.forages(.fern))
    XCTAssertFalse(dog.preysOn(.init(id: 2, species: "rabbit", kind: .rabbit, position: dog.position, home: dog.home)))
  }

  func testThirstExhaustionRainAndNightStillMatter() async throws {
    let thirsty = FaunaSimulation(); thirsty.restore([record(thirst: 0.95)])
    tick(thirsty, player: [2, 30, 0.5], offering: .berries) { p in
      p.x == 4 && p.z == 0 && p.y == 30 ? .water : p.y < 30 ? .grass : .air
    }
    XCTAssertEqual(thirsty.directive(id: dog.id)?.goal, .drink)
    let tired = FaunaSimulation(); tired.restore([record(fatigue: 0.99)])
    tick(tired, player: [2, 30, 0.5], offering: .berries)
    XCTAssertEqual(tired.directive(id: dog.id)?.goal, .sleep)
    let rain = try XCTUnwrap((0..<100).map { WorldWeather.sample(seed: UInt64($0), time: 80, style: .verdant) }.first { $0.wet })
    let sheltered = FaunaSimulation(); sheltered.restore([record()])
    tick(sheltered, weather: rain) { p in p.y < 30 || (p.y == 34 && p.x == 3 && p.z == 0) ? .stone : .air }
    XCTAssertEqual(sheltered.directive(id: dog.id)?.goal, .shelter)
    let sleeping = FaunaSimulation(); sleeping.restore([record()])
    tick(sleeping, night: true)
    XCTAssertEqual(sleeping.directive(id: dog.id)?.goal, .sleep)
  }

  func testPettingAndFeedingMemoryPersistAndJevReceivesThePersonality() async throws {
    let life = FaunaSimulation(); life.restore([record(hunger: 0.7)])
    tick(life)
    life.petted(id: dog.id, at: dog.position, time: 100)
    life.fed(id: dog.id, at: dog.position, time: 101)
    let saved = try JSONDecoder().decode([FaunaRecord].self, from: JSONEncoder().encode(life.records))
    let restored = FaunaSimulation(); restored.restore(saved)
    XCTAssertEqual(restored.knownKind(id: dog.id), .dog)
    XCTAssertTrue(saved[0].isValid)
    XCTAssertLessThan(saved[0].hunger, 0.4)
    XCTAssertEqual(Set(saved[0].memory.experiences.map(\.kind)), [.metPlayer, .fedByPlayer])
    let context = JevAnimalRequest.Context(saved[0], time: 102)
    XCTAssertEqual(context.speciesBehavior, TownDog.personality)
    XCTAssertTrue(context.recentExperiences.contains { $0.contains("petted") })
    XCTAssertTrue(context.recentExperiences.contains { $0.contains("food") })
  }
}
