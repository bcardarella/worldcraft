import Foundation
import XCTest
@testable import WorldCore

final class LivingWorldTests: XCTestCase {
  private var terrain: TerrainGenerator { .init(seed: 8192) }
  private var village: Settlement { SettlementGenerator.site(in: .init(0, 0), terrain: terrain)! }

  func testBiomesCoverDistinctHabitatsAndRespectPlanetsAndAltitude() {
    var found = Set<Biome>()
    for x in stride(from: -2_500, through: 2_500, by: 70) {
      for z in stride(from: -2_500, through: 2_500, by: 70) {
        let a = terrain.biome(atX: x, z: z)
        XCTAssertEqual(a, terrain.biome(atX: x, z: z))
        found.insert(a)
      }
    }
    XCTAssertTrue(found.isSuperset(of: [.meadow, .woodland, .birchGrove, .autumnForest, .blossomGrove,
      .taiga, .rainforest, .wetland, .savanna, .alpine, .ocean, .coast]))
    XCTAssertEqual(TerrainGenerator(seed: 1, style: .dune).biome(atX: 0, z: 0, height: 35, water: nil), .desert)
    XCTAssertEqual(TerrainGenerator(seed: 1, style: .frost).biome(atX: 0, z: 0, height: 35, water: nil), .tundra)
    XCTAssertEqual(TerrainGenerator(seed: 1, style: .solar).biome(atX: 0, z: 0), .volcanic)
    XCTAssertEqual(terrain.biome(atX: 0, z: 0, height: 74, water: nil), .alpine)
    XCTAssertEqual(Set(Biome.allCases.flatMap(\.animals)), Set(AnimalKind.allCases.filter(\.wild)))
    XCTAssertEqual(Set(Biome.allCases.flatMap(\.plants)), Set(PlantKind.allCases))
  }

  func testEveryPlantIsSolidOutwardWoundBoundedAndDistinct() {
    var signatures = Set<String>()
    for kind in PlantKind.allCases {
      let mesh = SurfaceDecorationMesher.shape(kind).mesh(cellSize: 0.125)
      XCTAssertGreaterThan(mesh.faceCount, 0)
      XCTAssertLessThan(mesh.faceCount, 160, "\(kind) stays within the per-plant budget")
      XCTAssertTrue(mesh.positions.allSatisfy { $0.y >= 0 && $0.y <= 2.01 && abs($0.x) < 0.8 && abs($0.z) < 0.8 })
      for i in stride(from: 0, to: mesh.positions.count, by: 4) {
        let a = mesh.positions[i], b = mesh.positions[i + 1], c = mesh.positions[i + 2]
        let normal = cross(b - a, c - a)
        let n = mesh.normals[i]
        XCTAssertGreaterThan(normal.x * n.x + normal.y * n.y + normal.z * n.z, 0)
      }
      signatures.insert("\(mesh.positions) \(mesh.textureCoordinates)")
    }
    XCTAssertEqual(signatures.count, PlantKind.allCases.count)
  }

  func testNewTreesHaveRecognizableVolumesWithinChunkBorder() {
    for species in [TreeSpecies.palm, .acacia, .redwood] {
      let tree = TreeDescriptor(species: species, x: -16, z: 0, ground: 30, height: 18)
      XCTAssertEqual(tree.block(at: .init(-16, 31, 0)), tree.trunk)
      var leaves = 0
      for x in -21...(-11) { for z in -5...5 { for y in 31...50 {
        if tree.block(at: .init(x, y, z)) == tree.leaves {
          leaves += 1; XCTAssertLessThanOrEqual(abs(x + 16), 4); XCTAssertLessThanOrEqual(abs(z), 4)
        }
      } } }
      XCTAssertGreaterThan(leaves, 20)
    }
  }

  func testArchitectureVariantsHaveUsableDoorsAndSharedRoofProfiles() {
    var styles = Set<ArchitectureStyle>()
    for x in -8...8 { for z in -8...8 {
      guard let site = SettlementGenerator.site(in: .init(x, z), terrain: terrain), site.habitat == .surface else { continue }
      for lx in -2...1 { for lz in -2...1 {
        guard let building = site.building(lotX: lx, lotZ: lz, terrain: terrain) else { continue }
        styles.insert(building.style)
        let middle = (building.minimum + building.maximum) / 2
        for y in 1...4 { XCTAssertEqual(building.block(x: middle, y: y, z: building.minimum), .air) }
        XCTAssertEqual(building.block(x: middle, y: 0, z: building.minimum), .wood)
        for inset in 0...((building.maximum - building.minimum) / 2) {
          let height = building.height + building.roofHeight(inset: inset)
          XCTAssertEqual(building.block(x: building.minimum + inset, y: height, z: building.minimum + 1), building.roof)
        }
      } }
    } }
    XCTAssertTrue(styles.isSuperset(of: [.timber, .alpine, .garden, .townhouse, .modern, .artDeco]))
    var desert = village; desert.biome = .desert
    XCTAssertEqual(desert.building(lotX: 0, lotZ: 0, terrain: terrain)?.style == .adobe
      || desert.building(lotX: -1, lotZ: 0, terrain: terrain)?.style == .adobe, true)
  }

  func testResidentsHaveStableDiverseIdentityAndNeedDrivenActivities() {
    let people = (0..<village.population).map { ResidentState(index: $0, site: village) }
    XCTAssertEqual(Set(people.map(\.id)).count, village.population)
    XCTAssertEqual(Set(people.map(\.role)).count, 8)
    XCTAssertGreaterThan(Set(people.map(\.personality)).count, 3)
    XCTAssertEqual(people.map(\.name), (0..<village.population).map { ResidentState(index: $0, site: village).name })
    var person = people[0]
    person.record.hunger = 0.9
    XCTAssertEqual(person.localChoice(night: false, nearby: people[1].id), .eat)
    person.choose(.eat, time: 400)
    for _ in 0..<60 { person.advanceNeeds(seconds: 0.2, arrived: true) }
    XCTAssertLessThan(person.record.hunger, 0.1)
    person.record.fatigue = 0.95
    XCTAssertEqual(person.localChoice(night: false, nearby: nil), .rest)
    person.record.fatigue = 0.1; person.record.loneliness = 0.8
    XCTAssertEqual(person.localChoice(night: false, nearby: people[1].id), .socialize)
    let before = person.revision
    person.reconsider(at: 410)
    XCTAssertGreaterThan(person.revision, before)
    XCTAssertEqual(person.nextDecision, 410)
  }

  func testRelationshipsGrowFromEncountersAndPersistInExistingSaveFormat() throws {
    var person = ResidentState(index: 0, site: village)
    let other = ResidentState.id(index: 1, site: village)
    let initial = try XCTUnwrap(person.record.relationships.first { $0.otherID == other })
    person.meet(other, helping: true, time: 500)
    let changed = try XCTUnwrap(person.record.relationships.first { $0.otherID == other })
    XCTAssertGreaterThan(changed.affinity, initial.affinity)
    XCTAssertGreaterThan(changed.trust, initial.trust)
    for i in 0..<20 { person.remember("Conversation \(i)", time: 500 + Double(i)) }
    XCTAssertEqual(person.record.memories.count, 8)
    let save = WorldSave(seed: 8192, edits: [], player: [0, 30, 0], flying: false, heading: 0,
      selectedSlot: 0, residents: [person.record])
    XCTAssertTrue(save.isValid)
    let restored = try JSONDecoder().decode(WorldSave.self, from: JSONEncoder().encode(save))
    let record = try XCTUnwrap(restored.residents?.first)
    XCTAssertEqual(record.relationships, person.record.relationships)
    XCTAssertEqual(record.memories, person.record.memories)
    XCTAssertEqual(ResidentState(index: 0, site: village, saved: record).record.memories, record.memories)
    var invalid = record; invalid.hunger = .nan
    XCTAssertFalse(invalid.isValid)
  }

  func testNeedChangesAndCompletedActivitiesInvalidateOutstandingDecisions() {
    var person = ResidentState(index: 0, site: village)
    person.choose(.work, time: 10)
    person.record.hunger = 0.7499
    let prior = person.revision
    person.advanceNeeds(seconds: 0.2, arrived: false, time: 11)
    XCTAssertGreaterThan(person.revision, prior)
    XCTAssertEqual(person.nextDecision, 11.25)
    let crossing = person.revision
    person.advanceNeeds(seconds: 0.2, arrived: false, time: 11.2)
    XCTAssertEqual(person.revision, crossing, "Urgency crossing fires once, not every tick")
    person.choose(.eat, time: 12)
    person.record.hunger = 0.11
    person.advanceNeeds(seconds: 0.2, arrived: true, time: 13)
    XCTAssertEqual(person.nextDecision, 13.25)
    XCTAssertTrue(person.record.memories.last?.event.contains("Finished") == true)
    person.choose(.socialize, time: 14)
    let lonely = person.record.loneliness
    person.advanceNeeds(seconds: 0.2, arrived: false, time: 15)
    XCTAssertGreaterThan(person.record.loneliness, lonely, "Walking toward someone does not count as socializing")
  }

  func testNavigationRoutesAroundWallsAndRejectsWaterCliffsAndLowCeilings() {
    let block: (BlockPosition) -> Block = { p in
      if p.y < 0 { return .stone }
      if p.x == 3 && (-2...2).contains(p.z) && p.y < 5 { return .brick }
      return .air
    }
    let path = ResidentNavigation.path(from: [0.5, 0, 0.5], to: [6.5, 0, 0.5], block: block)
    XCTAssertEqual(path.last, [6.5, 0, 0.5])
    XCTAssertTrue(path.contains { abs($0.z) >= 2.5 })
    XCTAssertTrue(path.allSatisfy { ResidentNavigation.standing(at: $0, block: block) != nil })
    XCTAssertNil(ResidentNavigation.standing(at: [0.5, 0, 0.5], block: { $0.y < 1 ? .water : .air }))
    XCTAssertNil(ResidentNavigation.standing(at: [0.5, 0, 0.5], block: { $0.y == 2 || $0.y < 0 ? .stone : .air }))
    XCTAssertTrue(ResidentNavigation.path(from: [0.5, 0, 0.5], to: [100.5, 0, 0.5], maximumVisited: 12,
      block: { $0.y < 0 ? .stone : .air }).count <= 12)
  }

  func testResidentsCanSpawnOnRealSettlementStreets() {
    for index in 0..<village.population {
      let resident = ResidentState(index: index, site: village)
      XCTAssertNotNil(ResidentNavigation.standing(at: resident.position, block: terrain.block))
      XCTAssertTrue(village.contains(BlockPosition(resident.position)))
    }
  }

  func testJevPayloadUsesExplicitResidentReferencesAndTypedAllowedOptions() throws {
    let person = ResidentState(index: 0, site: village)
    let options = ["work": NPCDecisionOption(activity: .work, description: person.role.work),
      "rest": NPCDecisionOption(activity: .rest, description: "Rest at home")]
    let request = JevNPCRequest(settlement: village.name, biome: village.biome.name, dayFraction: 0.5,
      contexts: [person.id: .init(resident: person, neighbors: [])], options: [person.id: options])
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    XCTAssertEqual(object["model"] as? String, "jev-latest")
    XCTAssertEqual(request.questions.count, 2)
    let action = try XCTUnwrap(request.questions["action_\(person.id)"])
    XCTAssertEqual(action.type, "choice")
    XCTAssertTrue(action.instructions.contains("state.residents['\(person.id)']"))
    XCTAssertEqual(Set(action.criteria.keys), Set(options.keys))
    XCTAssertEqual(request.state.timeOfDay, "afternoon")
    XCTAssertEqual(request.state.residents[String(person.id)]?.name, person.name)
  }

  func testJevRejectsUnknownLowConfidenceOrInconsistentAnswers() throws {
    let good = #"{"model":"jev-1.13.0","answers":{"action_1":{"type":"choice","choice":"work","confidence":0.8,"probabilities":{"work":0.9,"rest":0.1}}},"usage":{"input_tokens":120,"output_tokens":15}}"#
    let options = ["work": NPCDecisionOption(activity: .work, description: "Work"), "rest": NPCDecisionOption(activity: .rest, description: "Rest")]
    func decode(_ value: String) throws -> JevNPCResponse { try JSONDecoder().decode(JevNPCResponse.self, from: Data(value.utf8)) }
    XCTAssertEqual(try decode(good).action(for: 1, options: options)?.activity, .work)
    XCTAssertNil(try decode(good.replacingOccurrences(of: "0.8", with: "0.1")).action(for: 1, options: options))
    XCTAssertNil(try decode(good.replacingOccurrences(of: "\"choice\":\"work\"", with: "\"choice\":\"teleport\"")).action(for: 1, options: options))
    XCTAssertNil(try decode(good.replacingOccurrences(of: "0.9", with: "0.2")).action(for: 1, options: options))
    XCTAssertNil(try decode(good).action(for: 2, options: options))
  }

  func testNetworkBudgetBoundsConcurrencyRateAndBackoff() {
    var budget = NPCRequestBudget()
    XCTAssertTrue(budget.begin(at: 10))
    XCTAssertFalse(budget.begin(at: 15))
    budget.complete(at: 11)
    XCTAssertFalse(budget.begin(at: 12))
    XCTAssertTrue(budget.begin(at: 13))
    budget.fail(at: 14, retryAfter: 30)
    XCTAssertFalse(budget.begin(at: 43))
    XCTAssertTrue(budget.begin(at: 44))
    budget.fail(at: 45)
    XCTAssertEqual(budget.nextAllowed, 49)
    XCTAssertTrue(budget.begin(at: 49))
    budget.complete(at: 50)
    XCTAssertEqual(budget.failures, 0)
  }

  func testMissingJevKeyFailsBeforeNetwork() async {
    let client = JevNPCClient(apiKey: " ")
    let request = JevNPCRequest(settlement: "Test", biome: "Meadow", dayFraction: 0.4, contexts: [:], options: [:])
    do { _ = try await client.decide(request); XCTFail("Expected missing key") }
    catch JevServiceError.missingKey { }
    catch { XCTFail("Unexpected error: \(error)") }
  }
}
