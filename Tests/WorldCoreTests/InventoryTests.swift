import XCTest
import simd
@testable import WorldCore

final class InventoryTests: XCTestCase {
  func testCollectionFillsExistingStacksAndReturnsEveryExcessItem() {
    var bag = Inventory()
    XCTAssertEqual(bag.collect(.block(.stone), count: 70), 0)
    XCTAssertEqual(bag[0]?.count, 64)
    XCTAssertEqual(bag[1]?.count, 6)
    XCTAssertTrue(bag.consume(slot: 0, count: 4))
    bag.collect(.block(.stone), count: 5)
    XCTAssertEqual(bag[0]?.count, 64)
    XCTAssertEqual(bag[1]?.count, 7)
    let room = bag.capacity(for: .block(.stone))
    XCTAssertEqual(bag.collect(.block(.stone), count: room + 19), 19)
    XCTAssertEqual(bag.capacity(for: .block(.stone)), 0)
    XCTAssertEqual(bag.collect(.plant(.grass), count: 9), 9)
    XCTAssertTrue(bag.isValid)
    XCTAssertEqual(bag.slots.compactMap { $0 }.reduce(0) { $0 + $1.count }, 36 * 64)
  }

  func testMoveMergeSwapAndConsumptionPreserveCounts() {
    var bag = Inventory()
    bag.collect(.block(.dirt), count: 80)
    bag.move(from: 0, to: 17)
    XCTAssertNil(bag[0]); XCTAssertEqual(bag[17]?.count, 64)
    bag.move(from: 17, to: 1)
    XCTAssertEqual(bag[1]?.count, 64); XCTAssertEqual(bag[17]?.count, 16)
    bag.collect(.plant(.daisy), count: 3)
    bag.move(from: 0, to: 1)
    XCTAssertEqual(bag[1]?.item, .plant(.daisy))
    XCTAssertEqual(bag[0]?.item, .block(.dirt))
    XCTAssertFalse(bag.consume(slot: 1, count: 4))
    XCTAssertEqual(bag[1]?.count, 3)
    XCTAssertTrue(bag.consume(slot: 1, count: 3))
    XCTAssertNil(bag[1])
    let unchanged = bag
    bag.move(from: -1, to: 100); bag.move(from: 0, to: 0)
    XCTAssertFalse(bag.consume(slot: 36))
    XCTAssertEqual(bag, unchanged)
    XCTAssertNil(bag[-1]); XCTAssertNil(bag[36])
  }

  func testMixedTransactionsConserveInventoryAcrossRearrangementAndSave() throws {
    var bag = Inventory(), totals: [InventoryItem: Int] = [:]
    let items: [InventoryItem] = [.block(.grass), .block(.dirt), .block(.stone), .plant(.grass), .plant(.sunflower)]
    for step in 0..<800 {
      let item = items[step % items.count], count = 1 + step % 79
      let remainder = bag.collect(item, count: count)
      totals[item, default: 0] += count - remainder
      let slot = (step * 11) % 36
      if let stack = bag[slot], bag.consume(slot: slot) { totals[stack.item, default: 0] -= 1 }
      bag.move(from: (step * 7) % 36, to: (step * 13) % 36)
      XCTAssertTrue(bag.isValid)
      if step % 100 == 0 { bag = try JSONDecoder().decode(Inventory.self, from: JSONEncoder().encode(bag)) }
    }
    for item in items {
      XCTAssertEqual(bag.slots.compactMap { $0 }.filter { $0.item == item }.reduce(0) { $0 + $1.count }, totals[item])
    }
    XCTAssertEqual(bag.collect(.block(.water)), 1)
    XCTAssertEqual(bag.collect(.block(.lava)), 1)
    XCTAssertEqual(bag.collect(.block(.air)), 1)
  }

  func testMaterialHardnessAffectsCompletionAndResetsWhenAimOrButtonChanges() {
    var mining = MiningProgress()
    let grass = MiningTarget(position: .init(0, 10, 0), item: .plant(.grass))
    let stone = MiningTarget(position: .init(0, 9, 0), item: .block(.stone))
    for _ in 0..<3 { XCTAssertFalse(mining.update(target: grass, held: true, seconds: 0.05)) }
    XCTAssertTrue(mining.update(target: grass, held: true, seconds: 0.05))
    XCTAssertFalse(mining.update(target: stone, held: true, seconds: 0.05))
    XCTAssertLessThan(mining.fraction, 0.02)
    for _ in 0..<30 { XCTAssertFalse(mining.update(target: stone, held: true, seconds: 0.05)) }
    XCTAssertGreaterThan(mining.fraction, 0.4)
    XCTAssertFalse(mining.update(target: stone, held: false, seconds: 0.05))
    XCTAssertEqual(mining.fraction, 0)
    for _ in 0..<65 { _ = mining.update(target: stone, held: true, seconds: 0.05) }
    XCTAssertEqual(mining.fraction, 1)
    XCTAssertFalse(mining.update(target: nil, held: true, seconds: 0.05))
    XCTAssertNil(mining.target)
  }

  func testLongFramesCannotInstantlyMineAndBedrockLiquidsAreProtected() {
    var mining = MiningProgress()
    let stone = MiningTarget(position: .init(0, 10, 0), item: .block(.stone))
    XCTAssertFalse(mining.update(target: stone, held: true, seconds: 20))
    XCTAssertEqual(mining.work, 0.05)
    for item in [InventoryItem.block(.water), .block(.lava), .block(.air)] {
      XCTAssertFalse(mining.update(target: .init(position: .init(0, 3, 0), item: item), held: true, seconds: 0.05))
      XCTAssertEqual(mining.fraction, 0)
    }
    XCTAssertFalse(mining.update(target: .init(position: .init(0, ChunkData.minimumY, 0), item: .block(.stone)), held: true, seconds: 0.05))
    XCTAssertFalse(mining.update(target: stone, held: true, seconds: .nan))
    XCTAssertEqual(mining.fraction, 0)
    XCTAssertLessThan(InventoryItem.plant(.grass).breakingEffort, InventoryItem.block(.dirt).breakingEffort)
    XCTAssertLessThan(InventoryItem.block(.dirt).breakingEffort, InventoryItem.block(.wood).breakingEffort)
    XCTAssertLessThan(InventoryItem.block(.wood).breakingEffort, InventoryItem.block(.stone).breakingEffort)
    XCTAssertGreaterThan(InventoryItem.block(.basalt).breakingEffort, InventoryItem.block(.stone).breakingEffort)
  }

  func testDropsSettleOnSolidGroundAndFloatInWaterWithoutExpiring() {
    var drop = DroppedItem(stack: .init(.plant(.grass)), position: [0.5, 5, 0.5])
    for _ in 0..<500 { drop.update(seconds: 0.05) { $0.y < 1 ? .stone : .air } }
    XCTAssertGreaterThanOrEqual(drop.position.y, 1.2)
    XCTAssertLessThan(drop.position.y, 1.5)
    XCTAssertEqual(drop.stack.count, 1)
    XCTAssertEqual(drop.pickupDelay, 0)
    XCTAssertTrue(drop.isValid)
    drop.position = [0.5, 2, 0.5]; drop.velocity = .zero
    for _ in 0..<100 { drop.update(seconds: 0.05) { $0.y < 4 ? .water : .air } }
    XCTAssertGreaterThan(drop.position.y, 2)
    XCTAssertLessThan(drop.position.y, 4.3)
    XCTAssertTrue(drop.isValid)
  }

  func testHarvestedPlantsStayRemovedAfterChunkRegenerationAndCanBeReplanted() throws {
    let terrain = TerrainGenerator(seed: 8192)
    var chunk = ChunkData(coordinate: .init(0, 0))
    for z in 0..<16 { for x in 0..<16 { chunk[x, 10, z] = .grass } }
    let natural = SurfaceDecorationMesher.instances(in: chunk, terrain: terrain)
    let plant = try XCTUnwrap(natural.first)
    var changes = [plant.position: PlantEdit(position: plant.position, kind: nil)]
    let harvested = SurfaceDecorationMesher.instances(in: chunk, terrain: terrain, changes: changes)
    XCTAssertEqual(harvested.count, natural.count - 1)
    XCTAssertFalse(harvested.contains { $0.position == plant.position })
    let restored = try JSONDecoder().decode([PlantEdit].self, from: JSONEncoder().encode(Array(changes.values)))
    changes = Dictionary(uniqueKeysWithValues: restored.map { ($0.position, $0) })
    XCTAssertFalse(SurfaceDecorationMesher.instances(in: chunk, terrain: terrain, lush: false, changes: changes).contains { $0.position == plant.position })
    changes[plant.position] = .init(position: plant.position, kind: .sunflower)
    let replanted = SurfaceDecorationMesher.instances(in: chunk, terrain: terrain, changes: changes).filter { $0.position == plant.position }
    XCTAssertEqual(replanted.count, 1)
    XCTAssertEqual(replanted.first?.kind, .sunflower)
    chunk[plant.position.x, plant.position.y - 1, plant.position.z] = .air
    XCTAssertFalse(SurfaceDecorationMesher.instances(in: chunk, terrain: terrain, changes: changes).contains { $0.position == plant.position })
  }

  func testPlantPlacementRequiresCorrectMediumAndRoom() {
    let root = BlockPosition(0, 10, 0)
    let soil: (BlockPosition) -> Block = { $0.y < 10 ? .dirt : .air }
    let seabed: (BlockPosition) -> Block = { $0.y < 10 ? .sand : .water }
    XCTAssertTrue(PlantKind.grass.canPlant(at: root, block: soil))
    XCTAssertFalse(PlantKind.grass.canPlant(at: root, block: seabed))
    XCTAssertTrue(PlantKind.kelp.canPlant(at: root, block: seabed))
    XCTAssertFalse(PlantKind.kelp.canPlant(at: root, block: soil))
    XCTAssertFalse(PlantKind.daisy.canPlant(at: root) { $0.y == 11 ? .stone : soil($0) })
    XCTAssertFalse(PlantKind.coral.canPlant(at: root) { $0.y >= 10 ? .lava : .basalt })
    XCTAssertFalse(PlantKind.bamboo.canPlant(at: .init(0, ChunkData.height - 1, 0), block: soil))
  }

  func testPlantTargetingHonorsReachAndBlockingTerrain() throws {
    let plant = PlantInstance(position: .init(-1, 10, 0), kind: .bamboo)
    let origin = plant.center + [0, 0, 4]
    let distance = try XCTUnwrap(plant.hitDistance(origin: origin, direction: [0, 0, -2], reach: 6))
    XCTAssertGreaterThan(distance, 3)
    XCTAssertNil(plant.hitDistance(origin: origin, direction: [0, 0, -1], reach: 2))
    XCTAssertNil(plant.hitDistance(origin: origin, direction: [1, 0, 0], reach: 6))
    XCTAssertNil(plant.hitDistance(origin: origin, direction: .zero, reach: 6))
    let wall = try XCTUnwrap(VoxelRaycast.cast(origin: origin, direction: [0, 0, -1], reach: 6) { $0.z == 2 ? .stone : .air })
    XCTAssertNil(plant.hitDistance(origin: origin, direction: [0, 0, -1], reach: wall.distance))
  }

  func testTallPlantsReserveTheirUpperCellWithoutOccupyingTheirSoil() {
    let root = BlockPosition(-1, 10, 15)
    let bamboo = PlantInstance(position: root, kind: .bamboo)
    XCTAssertTrue(bamboo.overlaps(root))
    XCTAssertTrue(bamboo.overlaps(root + .init(0, 1, 0)))
    XCTAssertFalse(bamboo.overlaps(root + .init(0, -1, 0)))
    XCTAssertFalse(bamboo.overlaps(root + .init(0, 2, 0)))
    XCTAssertFalse(bamboo.overlaps(root + .init(2, 0, 0)))
  }

  func testEveryHarvestableItemHasSharedVoxelGeometryAndCorrectGrassSkins() {
    let items = Block.allCases.filter(\.isSolid).map(InventoryItem.block) + PlantKind.allCases.map(InventoryItem.plant)
    for item in items {
      let mesh = InventoryGeometry.mesh(for: item)
      XCTAssertGreaterThan(mesh.faceCount, 0, item.name)
      XCTAssertEqual(mesh.positions.count, mesh.normals.count)
      XCTAssertEqual(mesh.positions.count, mesh.textureCoordinates.count)
      XCTAssertEqual(mesh.positions.count % 4, 0)
      XCTAssertTrue(mesh.materials.allSatisfy { $0 < 6 })
    }
    XCTAssertNotEqual(InventoryItem.block(.grass), .plant(.grass))
    XCTAssertNil(InventoryItem.block(.grass).food)
    XCTAssertEqual(InventoryItem.plant(.grass).food, .grass)
    let mesh = InventoryGeometry.mesh(for: .block(.grass))
    for index in stride(from: 0, to: mesh.positions.count, by: 4) {
      let uv = mesh.textureCoordinates[index + 1]
      let tile = Int(uv.x * 16) + Int((1 - uv.y) * 8) * 16
      XCTAssertEqual(tile % 32, mesh.normals[index].y > 0 ? 0 : mesh.normals[index].y < 0 ? 2 : 1)
    }
  }

  func testAnimalDietCooldownAndTrustCannotConsumeWrongFood() {
    var rabbit = animal(.rabbit)
    XCTAssertEqual(rabbit.feed(.aquatic, time: 100), .disliked)
    XCTAssertEqual(rabbit.bond.meals, 0)
    XCTAssertEqual(rabbit.feed(.grass, time: 100), .fed)
    XCTAssertEqual(rabbit.bond.id, rabbit.id)
    XCTAssertEqual(rabbit.feed(.berries, time: 102), .chewing)
    XCTAssertEqual(rabbit.bond.meals, 1)
    XCTAssertTrue(rabbit.bond.chewing(at: 102))
    XCTAssertFalse(rabbit.bond.chewing(at: 104))
    XCTAssertEqual(rabbit.feed(.flowers, time: 108), .fed)
    XCTAssertEqual(rabbit.feed(.berries, time: 116), .fed)
    XCTAssertTrue(rabbit.bond.trusting)
    XCTAssertTrue(rabbit.bond.following(at: 180))
    XCTAssertFalse(rabbit.bond.following(at: 210))
    var wolf = animal(.wolf), fish = animal(.fish)
    XCTAssertEqual(wolf.feed(.grass, time: 100), .disliked)
    XCTAssertEqual(fish.feed(.aquatic, time: 100), .fed)
    XCTAssertFalse(AnimalKind.sheep.foods.contains(.aquatic))
    XCTAssertTrue(AnimalKind.cow.foods.contains(.grass))
    XCTAssertTrue(AnimalKind.chicken.foods.contains(.seeds))
  }

  func testShyAnimalFollowsFoodThenChewsAndRespectsWalls() {
    var rabbit = animal(.rabbit)
    let player = SIMD3<Float>(0, 1, -8)
    let flat: (BlockPosition) -> Block = { $0.y < 1 ? .grass : .air }
    for i in 0..<40 { rabbit.update(deltaTime: 0.05, time: 100 + Double(i) * 0.05, player: player, offering: .grass, block: flat) }
    XCTAssertLessThan(rabbit.position.z, -3)
    XCTAssertEqual(rabbit.feed(.grass, time: 103), .fed)
    let eatingAt = rabbit.position
    rabbit.update(deltaTime: 0.05, time: 104, player: player, block: flat)
    XCTAssertEqual(rabbit.position, eatingAt)
    XCTAssertTrue(rabbit.grazing)
    rabbit.position = [0, 1, 0]; rabbit.heading = 0
    for i in 0..<80 {
      rabbit.update(deltaTime: 0.05, time: 110 + Double(i) * 0.05, player: player) {
        $0.z == -2 && $0.y < 5 ? .stone : flat($0)
      }
    }
    XCTAssertGreaterThanOrEqual(rabbit.position.z, -1)
  }

  func testInventoryAndPlanetHarvestHistoryRoundTripAndOlderSavesRemainValid() throws {
    var bag = Inventory(); bag.collect(.block(.stone), count: 30); bag.collect(.plant(.clover), count: 8)
    let p = BlockPosition(10, 30, 10)
    let drop = DroppedItem(stack: .init(.plant(.daisy), count: 4), position: p.center)
    var rabbit = animal(.rabbit); rabbit.feed(.grass, time: 100)
    let earth = SavedPlanet(index: 0, edits: [], player: [1, 30, 1], heading: 0, worldTime: 100,
      plantEdits: [.init(position: p, kind: nil)], droppedItems: [drop], animalBonds: [rabbit.bond])
    let dune = SavedPlanet(index: 1, edits: [], player: [1, 30, 1], heading: 0, worldTime: 50,
      plantEdits: [.init(position: p, kind: .aloe)])
    let save = WorldSave(seed: 8192, edits: [], player: [1, 30, 1], flying: false, heading: 0, selectedSlot: 8,
      visitedPlanets: [earth, dune], inventory: bag, plantEdits: earth.plantEdits, droppedItems: [drop], animalBonds: [rabbit.bond])
    let restored = try JSONDecoder().decode(WorldSave.self, from: JSONEncoder().encode(save))
    XCTAssertTrue(restored.isValid)
    XCTAssertEqual(restored.inventory, bag)
    XCTAssertEqual(restored.droppedItems, [drop])
    XCTAssertEqual(restored.animalBonds, [rabbit.bond])
    XCTAssertNil(restored.visitedPlanets?[0].plantEdits?[0].kind)
    XCTAssertEqual(restored.visitedPlanets?[1].plantEdits?[0].kind, .aloe)
    let old = #"{"version":1,"seed":8192,"edits":[],"player":[1,30,1],"flying":false,"heading":0,"selectedSlot":6}"#
    let migrated = try JSONDecoder().decode(WorldSave.self, from: Data(old.utf8))
    XCTAssertTrue(migrated.isValid); XCTAssertNil(migrated.inventory)
    XCTAssertNil(migrated.plantEdits); XCTAssertNil(migrated.animalBonds)
  }

  func testMalformedStacksAndDuplicateDropsAreRejectedBySaveValidation() throws {
    var save = WorldSave(seed: 1, edits: [], player: [0, 30, 0], flying: false, heading: 0, selectedSlot: 0)
    var bag = Inventory(); bag.collect(.plant(.grass))
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(bag)) as? [String: Any])
    json["slots"] = []
    save.inventory = try JSONDecoder().decode(Inventory.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertFalse(save.isValid)
    save.inventory = bag
    var drop = DroppedItem(stack: .init(.plant(.grass)), position: [0, 30, 0])
    save.droppedItems = [drop, drop]
    XCTAssertFalse(save.isValid)
    drop.stack.count = 65; save.droppedItems = [drop]
    XCTAssertFalse(save.isValid)
    drop.stack.count = 1; drop.position.x = .infinity; save.droppedItems = [drop]
    XCTAssertFalse(save.isValid)
    save.droppedItems = nil
    XCTAssertTrue(save.isValid)
  }

  private func animal(_ kind: AnimalKind) -> AnimalState {
    .init(id: 42, kind: kind, home: [0, 1, 0], position: [0, 1, 0], heading: 0)
  }
}
