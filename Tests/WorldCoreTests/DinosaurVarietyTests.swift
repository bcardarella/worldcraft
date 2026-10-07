import XCTest
import simd
@testable import WorldCore

final class DinosaurVarietyTests: XCTestCase {
  func testAllSpeciesAndBabiesHaveDistinctBoundedSolidGeometry() {
    var silhouettes = Set<[SIMD3<Float>]>()
    for kind in DinosaurKind.allCases {
      for baby in [false, true] { for id: UInt64 in [1, 37, 95, 173] {
        let model = DinosaurSculpture.make(.init(kind: kind, color: .pink, id: id, juvenile: baby))
        let mesh = model.combinedMesh()
        XCTAssertLessThan(mesh.faceCount, 720, kind.name)
        XCTAssertEqual(PackedTerrainMesh(mesh).parts.count, 1)
        XCTAssertLessThanOrEqual(model.parts.count, 9)
        XCTAssertGreaterThanOrEqual(model.bounds.minimum.y, -0.04, kind.name)
        XCTAssertTrue(model.parts.flatMap(\.boxes).allSatisfy { box in
          model.colors.indices.contains(box.color) && (0..<3).allSatisfy { box.size[$0] > 0 && box.size[$0].isFinite }
        })
        XCTAssertTrue(mesh.textureCoordinates.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        XCTAssertTrue(stride(from: 0, to: mesh.indices.count, by: 3).allSatisfy { i in
          let a = Int(mesh.indices[i]), b = Int(mesh.indices[i + 1]), c = Int(mesh.indices[i + 2])
          return simd_dot(simd_cross(mesh.positions[b] - mesh.positions[a], mesh.positions[c] - mesh.positions[a]), mesh.normals[a]) > 0
        })
        if !baby {
          XCTAssertLessThanOrEqual(WorldScale.blocks(model.bounds.maximum.y), kind.clearance.height, kind.name)
          if id == 1 { silhouettes.insert(mesh.positions) }
        } else {
          let adult = DinosaurSculpture.make(.init(kind: kind, color: .pink, id: id, juvenile: false))
          XCTAssertLessThan(model.bounds.maximum.y * 0.45, adult.bounds.maximum.y * 0.6)
          XCTAssertNotEqual(model.parts.first { $0.joint == .head }?.boxes, adult.parts.first { $0.joint == .head }?.boxes)
        }
      } }
    }
    XCTAssertEqual(silhouettes.count, DinosaurKind.allCases.count)
  }

  func testColorsAndMarkingsAreStableWithoutDuplicatingMeshes() throws {
    var keys: [String: Data] = [:], patterns = Set<Int>(), crests = Set<Int>()
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    for id: UInt64 in 0..<48 { for color in RexColor.allCases {
      let look = DinosaurAppearance(kind: .triceratops, color: color, id: id, juvenile: false)
      XCTAssertEqual(look, .init(kind: .triceratops, color: color, id: id, juvenile: false))
      patterns.insert(look.pattern); crests.insert(look.crest)
      let sculpture = DinosaurSculpture.make(look), shape = try encoder.encode(sculpture.parts)
      if let previous = keys[sculpture.geometryKey] { XCTAssertEqual(previous, shape) }
      keys[sculpture.geometryKey] = shape
    } }
    XCTAssertEqual(patterns.count, 4); XCTAssertEqual(crests.count, 3)
    XCTAssertEqual(RexColor.allCases.count, 12)
  }

  func testDietsSocialProfilesAndHabitatsMatchSpecies() {
    XCTAssertEqual(Set(Biome.allCases.flatMap { DinosaurKind.inhabitants(of: $0, style: .verdant) }), Set(DinosaurKind.allCases.filter { $0 != .trex }))
    for kind in DinosaurKind.allCases {
      XCTAssertEqual(kind.prey.isEmpty, !kind.carnivore)
      XCTAssertEqual(kind.forages(.fern), !kind.carnivore)
      XCTAssertFalse(kind.forages(.mushroom))
      XCTAssertFalse(kind.behaviorDescription.isEmpty)
    }
    XCTAssertEqual(DinosaurKind.spinosaurus.prey.first, .fish)
    XCTAssertEqual(DinosaurKind.ankylosaurus.socialStyle, .solitary)
    XCTAssertEqual(DinosaurKind.velociraptor.socialStyle, .looseHuntingGroup)
    XCTAssertEqual(DinosaurKind.parasaurolophus.socialStyle, .herd)
    XCTAssertTrue(DinosaurKind.inhabitants(of: .meadow, style: .solar).isEmpty)
    XCTAssertTrue(DinosaurKind.inhabitants(of: .ocean, style: .verdant).isEmpty)
  }

  func testSpawnedGroupsAreSeededAndPreserveIdentities() {
    let terrain = TerrainGenerator(seed: 8192)
    var kinds = Set<DinosaurKind>(), babies = 0, groups = 0
    var heights: [SIMD2<Int>: Int] = [:]
    func terrainFloor(_ p: BlockPosition) -> Block {
      let key = SIMD2(p.x, p.z)
      let height = heights[key] ?? terrain.height(atX: p.x, z: p.z); heights[key] = height
      return p.y <= height ? .grass : .air
    }
    for x in -14...14 { for z in -14...14 {
      let coordinate = ChunkCoordinate(x * 16, z * 16)
      let group = RexState.herd(in: coordinate, terrain: terrain, block: terrainFloor)
      guard let first = group.first else { continue }
      groups += 1; kinds.insert(first.kind)
      XCTAssertFalse(first.baby)
      XCTAssertTrue(group.allSatisfy { $0.groupID == first.id && $0.kind == first.kind })
      XCTAssertEqual(Set(group.map(\.id)).count, group.count)
      babies += group.filter(\.baby).count
      if first.kind.socialStyle == .solitary { XCTAssertEqual(group.filter { !$0.baby }.count, 1) }
      XCTAssertEqual(group.map(\.id), RexState.herd(in: coordinate, terrain: terrain, block: terrainFloor).map(\.id))
    } }
    XCTAssertGreaterThan(groups, 10); XCTAssertGreaterThan(babies, 5); XCTAssertGreaterThan(kinds.count, 4)
  }

  func testHerbivoresNeverChompAndPredatorsHonorNeeds() {
    for kind in DinosaurKind.allCases where !kind.carnivore {
      var state = RexState(id: 13, color: .mint, baby: false, position: [0, 30, 0], kind: kind)
      for n in 0..<80 {
        XCTAssertFalse(state.update(deltaTime: 0.05, time: Double(n) * 0.05, player: [0, 30, -2]) { $0.y < 30 ? .grass : .air })
        XCTAssertEqual(state.mood, .wandering)
      }
    }
    var rex = RexState(id: 1, color: .pink, baby: false, position: [0, 30, 0])
    let drink = AnimalDecisionOption(.drink, at: .init(0, 30, 9), description: "Reach water")
    for n in 0..<20 {
      _ = rex.update(deltaTime: 0.05, time: Double(n) * 0.05, player: [0, 30, -8], directive: drink) { $0.y < 30 ? .grass : .air }
      XCTAssertEqual(rex.mood, .wandering)
    }
  }

  func testSpinosaurusCanDiveButCannotSwimThroughWalls() {
    var swimmer = RexState(id: 5, color: .coral, baby: false, position: [0, 30, 0], kind: .spinosaurus)
    let hunt = AnimalDecisionOption(.hunt, at: .init(0, 27, -8), preyID: 4, description: "Catch fish")
    for n in 0..<20 {
      _ = swimmer.update(deltaTime: 0.05, time: Double(n) * 0.05, player: [100, 90, 100], directive: hunt) { _ in .water }
    }
    XCTAssertLessThan(swimmer.position.y, 30); XCTAssertLessThan(swimmer.position.z, -2)
    var blocked = RexState(id: 5, color: .coral, baby: false, position: [0, 30, 0], kind: .spinosaurus)
    for n in 0..<60 {
      _ = blocked.update(deltaTime: 0.05, time: Double(n) * 0.05, player: [100, 90, 100], directive: hunt) { $0.z <= -3 ? .stone : .water }
    }
    XCTAssertGreaterThan(blocked.position.z, -3 + DinosaurKind.spinosaurus.clearance.radius)
  }

  func testColossalSitesAreRareStableAndActuallyExist() {
    let terrain = TerrainGenerator(seed: 8192)
    var sites: [ColossalRexSite] = []
    for x in -10...10 { for z in -10...10 {
      let region = ChunkCoordinate(x, z)
      if let site = ColossalRexSite.candidate(in: region, terrain: terrain) {
        sites.append(site)
        let again = ColossalRexSite.candidate(in: region, terrain: terrain)
        XCTAssertEqual(site.id, again?.id); XCTAssertEqual(site.position, again?.position)
        XCTAssertTrue((110...140).contains(site.heightMetres))
        XCTAssertNil(SettlementGenerator.site(at: .init(site.position), terrain: terrain))
      }
      XCTAssertNil(ColossalRexSite.candidate(in: region, terrain: .init(seed: 8192, style: .solar)))
    } }
    XCTAssertGreaterThan(sites.count, 2); XCTAssertLessThan(sites.count, 441 / 7)
  }

  func testColossalMovementHasConstantProbeCostAndNeverTargetsVisitors() {
    let site = ColossalRexSite(id: 0, region: .init(0, 0), position: [0, 30, 0], heightMetres: 120, color: .purple)
    var left = ColossalRexState(site: site), right = left
    let walk = AnimalDecisionOption(.patrol, at: .init(0, 30, -200), description: "Patrol")
    var probes = 0
    for n in 0..<900 {
      left.update(deltaTime: 1 / 90, time: Double(n) / 90, player: [-30, 30, 0], directive: walk) { _, _ in
        probes += 1; return .init(height: 30)
      }
      right.update(deltaTime: 1 / 90, time: Double(n) / 90, player: [30, 30, 0], directive: walk) { _, _ in .init(height: 30) }
    }
    XCTAssertEqual(left.position, right.position); XCTAssertEqual(left.heading, right.heading)
    XCTAssertGreaterThan(left.display, 0.9); XCTAssertLessThan(left.position.z, -5)
    XCTAssertLessThanOrEqual(probes, 200)
    let before = left.position
    for n in 0..<90 {
      left.update(deltaTime: 1 / 90, time: Double(n) / 90, player: .zero, directive: walk) { _, _ in .init(height: 30, waterDepth: 30) }
    }
    XCTAssertEqual(left.position, before)
    probes = 0
    let options = left.options(time: 10) { _, _ in probes += 1; return .init(height: 30) }
    XCTAssertLessThanOrEqual(probes, 16); XCTAssertNotNil(options["home"])
    let model = DinosaurSculpture.make(.init(kind: .trex, color: site.color, id: site.id, juvenile: false))
    let scale = site.heightMetres / model.bounds.maximum.y
    XCTAssertEqual(WorldScale.metres(model.bounds.maximum.y * WorldScale.blocks(1) * scale), 120, accuracy: 0.001)
  }

  func testDinosaurSocialMemoryRoundTripsAndOldFaunaRecordsStillLoad() throws {
    var record = FaunaRecord(id: 4, species: "velociraptor", home: [1, 30, 1])
    record.social = .init(groupID: 3, juvenile: false)
    record.social?.bond(with: 3, family: true, time: 10)
    record.memory.remember(.socialized, "A familiar hunting companion", other: 3, time: 12, importance: 0.7)
    let encoded = try JSONEncoder().encode(record)
    let loaded = try JSONDecoder().decode(FaunaRecord.self, from: encoded)
    XCTAssertTrue(loaded.isValid); XCTAssertEqual(loaded.social?.bonds, record.social?.bonds)
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "social"); legacy["species"] = "trex"
    let old = try JSONDecoder().decode(FaunaRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertTrue(old.isValid); XCTAssertNil(old.social)
    record.social?.need = .infinity; XCTAssertFalse(record.isValid)
  }

  func testJevReceivesSpeciesNeedsRelationshipsAndOnlyExecutableChoices() throws {
    var record = FaunaRecord(id: 4, species: "velociraptor", home: [1, 30, 1])
    record.social = .init(groupID: 3, juvenile: false)
    record.social?.bond(with: 3, family: false, time: 10)
    let choices: [String: AnimalDecisionOption] = [
      "join_hunt": .init(.joinHunt, at: .init(4, 30, 4), preyID: 9, partnerID: 3, description: "Join companion 3 hunting rabbit 9"),
      "home": .init(.returnHome, at: .init(1, 30, 1), description: "Return to my habitual sleeping place")]
    let request = JevAnimalRequest(records: [record], options: [4: choices], night: false, raining: false, time: 100)
    XCTAssertTrue(request.state.animals["4"]?.speciesBehavior?.contains("loose hunting group") == true)
    XCTAssertEqual(request.state.animals["4"]?.group?.bonds.first?.other, 3)
    XCTAssertEqual(Set(request.questions["action_4"]!.criteria.keys), Set(choices.keys))
    XCTAssertNoThrow(try JSONEncoder().encode(request))
  }
}
