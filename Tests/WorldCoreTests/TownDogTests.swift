import XCTest
import simd
@testable import WorldCore

final class TownDogTests: XCTestCase {
  func town(_ kind: SettlementKind = .town) -> Settlement {
    .init(id: 42, kind: kind, name: "Test town", x: 0, z: 0, floor: 30, ground: .grass)
  }
  func flat(_ p: BlockPosition) -> Block { p.y < 30 ? .grass : .air }

  func testDogBelongsToSurfaceSettlementsWithStableIdentityAndSafeSpawn() throws {
    for kind: SettlementKind in [.village, .town, .city] {
      let site = town(kind)
      let dog = try XCTUnwrap(TownDog.spawn(in: site, block: flat))
      XCTAssertEqual(dog.kind, .dog); XCTAssertFalse(dog.baby)
      XCTAssertEqual(dog.id, TownDog.id(in: site)); XCTAssertEqual(dog.home, dog.position)
      XCTAssertTrue(site.contains(.init(dog.position)))
      XCTAssertTrue(dog.kind.canStand(at: dog.position, juvenile: false, block: flat))
      XCTAssertEqual(dog.position, TownDog.spawn(in: site, block: flat)?.position)
      XCTAssertNil(TownDog.spawn(in: site, block: { _ in .stone }))
      for habitat: SettlementHabitat in [.aquatic, .solar] {
        var hostile = site; hostile.habitat = habitat
        XCTAssertNil(TownDog.spawn(in: hostile, block: flat))
      }
    }
    XCTAssertFalse(Biome.allCases.flatMap(\.animals).contains(.dog))
    XCTAssertEqual(AnimalKind.dog.rawValue, 24)
    XCTAssertEqual(AnimalKind.boar.rawValue, 23)
    XCTAssertTrue(AnimalKind.dog.prey.isEmpty)
  }

  func testPhotoAppearanceKeepsItsCoatBandanaFloppyEarsAndFitsCollision() throws {
    let model = DogSculpture.make()
    XCTAssertLessThanOrEqual(model.bounds.maximum.y, AnimalKind.dog.clearance.height)
    XCTAssertGreaterThanOrEqual(model.bounds.minimum.y, -0.001)
    XCTAssertLessThan(model.combinedMesh().faceCount, 750)
    XCTAssertEqual(model.parts.count, 9)
    let head = try XCTUnwrap(model.parts.first { $0.joint == .head })
    XCTAssertTrue(head.boxes.contains { $0.center.z < -0.35 && $0.color == 3 }, "Black nose at the end of the long muzzle")
    for side: Float in [-1, 1] {
      XCTAssertTrue(head.boxes.contains { $0.center.x * side > 0.15 && $0.center.y < -0.2 }, "Long hanging ears on both sides")
    }
    let body = try XCTUnwrap(model.parts.first { $0.joint == .body })
    XCTAssertGreaterThan(body.boxes.filter { $0.color == 8 || $0.color == 9 }.count, 5)
    let tail = try XCTUnwrap(model.parts.first { $0.joint == .tail })
    for (a, b) in zip(tail.boxes, tail.boxes.dropFirst()) {
      XCTAssertTrue((0..<3).allSatisfy { abs(a.center[$0] - b.center[$0]) <= (a.size[$0] + b.size[$0]) / 2 }, "Stepped tail must stay connected")
    }
    for id: UInt64 in [1, 9, 73, 842] {
      let other = AnimalSculpture.make(.init(kind: .dog, id: id, juvenile: false))
      XCTAssertEqual(other.colors, model.colors)
      XCTAssertEqual(other.geometryKey, model.geometryKey, "Town identity does not randomize the reference dog's coat")
    }
  }

  func testThreeActualMealsBuildSavedFriendshipAndNoPhantomFood() throws {
    var dog = try XCTUnwrap(TownDog.spawn(in: town(), block: flat))
    XCTAssertEqual(dog.feed(.grass, time: 100), .disliked)
    XCTAssertEqual(dog.bond.meals, 0)
    XCTAssertEqual(dog.feed(.berries, time: 100), .fed)
    XCTAssertEqual(dog.feed(.berries, time: 101), .chewing)
    XCTAssertEqual(dog.feed(.berries, time: 108), .fed)
    XCTAssertFalse(dog.bond.trusting)
    XCTAssertEqual(dog.feed(.berries, time: 116), .fed)
    dog.bond = try JSONDecoder().decode(AnimalBond.self, from: JSONEncoder().encode(dog.bond))
    XCTAssertTrue(dog.bond.trusting)
    XCTAssertTrue(dog.followsPlayer(at: 10_000), "Dog friendship lasts beyond a temporary feeding lure")
    XCTAssertFalse(dog.bond.following(at: 10_000))
  }

  func testFriendlyMotorKeepsPersonalSpaceAndDoesNotOverrideDrinking() throws {
    var dog = try XCTUnwrap(TownDog.spawn(in: town(), block: flat))
    dog.position = [0.5, 30, 0.5]
    dog.update(deltaTime: 0.1, time: 100, player: [0.5, 30, -1],
      directive: .init(.greetPlayer, at: .init(0, 30, -1), description: "Hello"), block: flat)
    XCTAssertFalse(dog.moving)
    XCTAssertEqual(dog.position, [0.5, 30, 0.5])
    dog.bond.meals = 3
    for i in 0..<45 {
      dog.update(deltaTime: 0.1, time: 100 + Double(i) / 10, player: [0.5, 30, -1], offering: .berries,
        directive: .init(.drink, at: .init(5, 30, 0), description: "Urgent thirst"), block: flat)
    }
    XCTAssertGreaterThan(dog.position.x, 3, "A friendly player does not pin the dog in place when it needs water")
  }

  func testDogCanRouteAroundTownWallsWithoutPassingThroughThem() throws {
    func street(_ p: BlockPosition) -> Block {
      if p.y < 30 || (p.x == 3 && (-2...2).contains(p.z) && p.y < 36) { return .stone }
      return .air
    }
    var dog = try XCTUnwrap(TownDog.spawn(in: town(), block: flat))
    dog.position = [0.5, 30, 0.5]
    var passedWall = false
    for i in 0..<600 {
      dog.update(deltaTime: 1 / 30, time: 100 + Double(i) / 30, player: [7.5, 30, 0.5],
        directive: .init(.greetPlayer, at: .init(7, 30, 0), description: "Greet"), block: street)
      XCTAssertTrue(AnimalKind.dog.canStand(at: dog.position, juvenile: false, block: street))
      if dog.position.x > 4 { passedWall = true }
    }
    XCTAssertTrue(passedWall)
    XCTAssertLessThan(simd_distance(dog.position, [7.5, 30, 0.5]), 2.3)
  }
}
