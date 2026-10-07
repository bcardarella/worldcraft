import XCTest
import simd
@testable import WorldCore

final class ActorModelTests: XCTestCase {
  func testEveryAnimalAndResidentHasValidBoundedSingleMaterialGeometry() throws {
    var models: [ActorSculpture] = []
    for kind in AnimalKind.allCases { for baby in [false, true] {
      models.append(AnimalSculpture.make(.init(kind: kind, id: UInt64(kind.rawValue * 71 + 901), juvenile: baby)))
    } }
    for habitat: SettlementHabitat in [.surface, .aquatic, .solar] {
      for (i, role) in ResidentRole.allCases.enumerated() { for variant in 0..<4 {
        let model = ResidentSculpture.make(.init(id: UInt64(i * 73 + variant * 481 + 22), role: role, habitat: habitat))
        XCTAssertLessThan(model.bounds.maximum.y, 2, "Must fit resident navigation's four-block clearance")
        models.append(model)
      } }
    }
    for model in models {
      XCTAssertEqual(Set(model.parts.map(\.joint)).count, model.parts.count)
      XCTAssertEqual(model.colors.count, ActorPalette.capacity)
      XCTAssertTrue(model.colors.allSatisfy { color in (0..<3).allSatisfy { color[$0].isFinite && (0...1).contains(color[$0]) } })
      XCTAssertTrue(model.parts.flatMap(\.boxes).allSatisfy { box in
        (0..<3).allSatisfy { box.size[$0].isFinite && box.size[$0] > 0 && box.center[$0].isFinite }
          && model.colors.indices.contains(box.color)
      })
      let mesh = model.combinedMesh()
      XCTAssertLessThan(mesh.faceCount, 900, model.geometryKey)
      XCTAssertLessThanOrEqual(model.parts.filter { !$0.boxes.isEmpty }.count, 9)
      XCTAssertEqual(PackedTerrainMesh(mesh).parts.count, 1, "Distant actors must stay one draw")
      XCTAssertEqual(mesh.indices.count, mesh.faceCount * 6)
      XCTAssertTrue(mesh.positions.allSatisfy { p in (0..<3).allSatisfy { p[$0].isFinite } })
      XCTAssertTrue(mesh.textureCoordinates.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
      let validWinding = stride(from: 0, to: mesh.indices.count, by: 3).allSatisfy { i in
        let a = Int(mesh.indices[i]), b = Int(mesh.indices[i + 1]), c = Int(mesh.indices[i + 2])
        return simd_dot(simd_cross(mesh.positions[b] - mesh.positions[a], mesh.positions[c] - mesh.positions[a]), mesh.normals[a]) > 0
      }
      XCTAssertTrue(validWinding, model.geometryKey)
      XCTAssertGreaterThanOrEqual(model.bounds.minimum.y, -0.04, model.name)
    }
  }

  func testPaletteUVsSelectTheCorrectPaddedColorAcrossAllSixFaces() {
    let colors = (0..<16).map { SIMD3<Float>(Float($0) / 16, 0.5, 0.25) }
    let pixels = ActorPalette.pixels(colors)
    XCTAssertEqual(pixels.count, 64 * 64 * 4)
    for slot in 0..<16 {
      var source = VoxelMesh(); source.appendBox(size: [1, 1, 1], center: .zero, material: UInt32(slot))
      let mesh = ActorPalette.textured(source)
      XCTAssertEqual(Set(mesh.materials), [0])
      for uv in mesh.textureCoordinates {
        let x = Int(uv.x * 64), y = Int((1 - uv.y) * 64)
        XCTAssertEqual((y / 16) * 4 + x / 16, slot)
        XCTAssertTrue((2...13).contains(x % 16) && (2...13).contains(y % 16))
        for channel in 0..<3 { XCTAssertEqual(Float(pixels[(y * 64 + x) * 4 + channel]) / 255, colors[slot][channel], accuracy: 0.027) }
        XCTAssertEqual(pixels[(y * 64 + x) * 4 + 3], 255)
      }
    }
  }

  func testAppearanceIsStableAndTraitsAreIndependentOfOccupation() {
    for id: UInt64 in 0..<64 {
      let a = ResidentAppearance(id: id, role: .farmer, habitat: .surface)
      let b = ResidentAppearance(id: id, role: .scholar, habitat: .surface)
      XCTAssertEqual(a, .init(id: id, role: .farmer, habitat: .surface))
      XCTAssertEqual([a.skin, a.hairColor, a.hairstyle, a.build, a.feature], [b.skin, b.hairColor, b.hairstyle, b.build, b.feature])
      XCTAssertEqual(AnimalAppearance(kind: .cow, id: id, juvenile: false), .init(kind: .cow, id: id, juvenile: false))
    }
    let people = (0..<256).map { ResidentAppearance(id: UInt64($0), role: .merchant, habitat: .surface) }
    XCTAssertEqual(Set(people.map(\.skin)).count, 8)
    XCTAssertEqual(Set(people.map(\.hairstyle)).count, 7)
    XCTAssertEqual(Set(people.map(\.build)).count, 3)
    XCTAssertGreaterThan(Set(people.map { "\($0.skin)-\($0.hairColor)" }).count, 55)
    XCTAssertGreaterThan(Set(people.map { ResidentSculpture.make($0).geometryKey }).count, 200)
  }

  func testJuvenilesHaveDifferentProportionsAndLandmarkSpeciesHaveDistinctShapes() {
    for kind in AnimalKind.allCases {
      let adult = AnimalSculpture.make(.init(kind: kind, id: 52, juvenile: false))
      let baby = AnimalSculpture.make(.init(kind: kind, id: 52, juvenile: true))
      XCTAssertNotEqual(adult.geometryKey, baby.geometryKey)
      XCTAssertLessThan(baby.bounds.maximum.y * 0.62, adult.bounds.maximum.y)
      XCTAssertNotEqual(adult.parts.first { $0.joint == .head }?.boxes, baby.parts.first { $0.joint == .head }?.boxes)
    }
    let giraffe = AnimalSculpture.make(.init(kind: .giraffe, id: 9, juvenile: false))
    let elephant = AnimalSculpture.make(.init(kind: .elephant, id: 9, juvenile: false))
    let tortoise = AnimalSculpture.make(.init(kind: .tortoise, id: 9, juvenile: false))
    XCTAssertGreaterThan(giraffe.bounds.maximum.y, 2.8)
    XCTAssertGreaterThan(elephant.bounds.maximum.x - elephant.bounds.minimum.x, 1.1)
    XCTAssertLessThan(tortoise.bounds.maximum.y, 0.7)
  }

  func testSharedGeometryKeysDoNotDependOnPaletteAndNestedPivotsAreBaked() throws {
    var encoded: [String: Data] = [:], colors = Set<[SIMD3<Float>]>()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    for id: UInt64 in 0..<160 {
      let model = AnimalSculpture.make(.init(kind: .cow, id: id, juvenile: false))
      let shape = try encoder.encode(model.parts)
      if let previous = encoded[model.geometryKey] { XCTAssertEqual(previous, shape) }
      encoded[model.geometryKey] = shape; colors.insert(model.colors)
    }
    XCTAssertGreaterThan(colors.count, 3)
    var head = ActorPart(.head, at: [0, 1.5, -0.4])
    head.box([0.3, 0.3, 0.3], .zero, 0)
    var eyes = ActorPart(.eyes, at: [0, 0.05, -0.2])
    eyes.box([0.1, 0.1, 0.01], .zero, 0)
    let sculpture = ActorSculpture(name: "fixture", key: "fixture", colors: [[1, 1, 1]], parts: [head, eyes])
    XCTAssertEqual(sculpture.worldPivot(.eyes), [0, 1.55, -0.6])
    let mesh = sculpture.combinedMesh()
    XCTAssertEqual(mesh.positions.map(\.z).min()!, -0.605, accuracy: 0.00001)
    XCTAssertEqual(mesh.positions.map(\.y).max()!, 1.65, accuracy: 0.00001)
  }

  func testAddedSpeciesHaveHabitatsAndEcologicallyAppropriateFood() {
    XCTAssertEqual(Set(Biome.allCases.flatMap(\.animals)), Set(AnimalKind.allCases.filter(\.wild)))
    XCTAssertTrue(AnimalKind.panda.foods.contains(.bamboo))
    XCTAssertTrue(AnimalKind.panda.forages(.bamboo))
    XCTAssertTrue(AnimalKind.elephant.foods.contains(.leaves))
    XCTAssertTrue(AnimalKind.giraffe.foods.contains(.leaves))
    XCTAssertTrue(AnimalKind.tortoise.foods.contains(.grass))
    XCTAssertTrue(AnimalKind.otter.canSwim && AnimalKind.otter.prey.contains(.fish))
    XCTAssertFalse(AnimalKind.otter.foods.contains(.grass))
    XCTAssertTrue(AnimalKind.boar.foods.contains(.berries))
    XCTAssertEqual(AnimalKind.fish.rawValue, 17, "Old enum values must remain stable")
  }

  func testSavedSpeciesOverridesExpandedBiomeChoicesWithoutChangingIdentity() throws {
    let terrain = TerrainGenerator(seed: 8192)
    var matched = false
    for x in -12...12 {
      let chunk = ChunkCoordinate(x, 0)
      guard let old = AnimalState.spawn(in: chunk, generator: terrain, block: terrain.block), !old.kind.aquatic else { continue }
      let restored = AnimalState.spawn(in: chunk, generator: terrain, knownKind: { $0 == old.id ? .rabbit : nil }, block: terrain.block)
      if let restored {
        XCTAssertEqual(restored.kind, .rabbit); XCTAssertEqual(restored.id, old.id)
        XCTAssertEqual(restored.baby, old.baby); XCTAssertEqual(restored.position, old.position)
        matched = true; break
      }
    }
    XCTAssertTrue(matched)
  }

  func testLargeAnimalsCannotPassUnderLowCeilingsOrThroughNarrowWalls() {
    func lowCeiling(_ p: BlockPosition) -> Block { p.y < 0 || p.y >= 4 ? .stone : .air }
    XCTAssertFalse(AnimalKind.giraffe.canStand(at: [0.5, 0, 0.5], juvenile: false, block: lowCeiling))
    XCTAssertFalse(AnimalKind.elephant.canStand(at: [0.5, 0, 0.5], juvenile: false, block: lowCeiling))
    XCTAssertTrue(AnimalKind.rabbit.canStand(at: [0.5, 0, 0.5], juvenile: false, block: lowCeiling))
    XCTAssertTrue(AnimalKind.elephant.canStand(at: [0.5, 0, 0.5], juvenile: true, block: lowCeiling))
    func corridor(_ p: BlockPosition) -> Block { p.y < 0 || p.x < 0 || p.x > 1 ? .stone : .air }
    XCTAssertFalse(AnimalKind.elephant.canStand(at: [1, 0, 0.5], juvenile: false, block: corridor))
    XCTAssertTrue(AnimalKind.rabbit.canStand(at: [1, 0, 0.5], juvenile: false, block: corridor))
  }

  func testRexPatternsKeepSingleMaterialAndBoundedGeometry() {
    for pattern in 0..<3 { for part in RexSculpture.Part.allCases {
      let mesh = ActorPalette.textured(RexSculpture.mesh(part, pattern: pattern))
      XCTAssertLessThan(mesh.faceCount, 400)
      XCTAssertEqual(PackedTerrainMesh(mesh).parts.count, 1)
    } }
  }
}
