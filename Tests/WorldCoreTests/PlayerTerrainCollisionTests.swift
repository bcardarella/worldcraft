import XCTest
@testable import WorldCore

final class PlayerTerrainCollisionTests: XCTestCase {
  func testFlightCrossesManyUnrenderedChunksThenStopsOnStickRelease() {
    let terrain = TerrainGenerator(seed: 8192)
    var collision = PlayerTerrainCollision()
    var player = PlayerPhysics(position: [15.5, 180, -0.5])
    player.flying = true
    var entry = TerrainEntryReadiness()
    let startingChunk = BlockPosition(player.position).chunk
    // Only the original entry chunk has ever rendered. Both negative coordinates
    // and the chunk 0/1 boundary used to reactivate loading and stop all movement.
    for _ in 0..<600 {
      entry.observe(chunkReady: BlockPosition(player.position).chunk == startingChunk)
      if entry.isWaiting { continue }
      player.update(deltaTime: 1/60, movement: [1,0,0], jump: false, sprint: true,
        block: { collision.block(at: $0, terrain: terrain) })
    }
    XCTAssertEqual(player.position.x, 15.5 + CreativeFlight.speed * 20, accuracy: 0.01)
    XCTAssertEqual(player.position.y, 180)
    XCTAssertGreaterThan(BlockPosition(player.position).chunk.x, 25)
    XCTAssertFalse(entry.isWaiting)
    let released = player.position
    for _ in 0..<90 {
      player.update(deltaTime: 1/90, movement: .zero, jump: false, sprint: true,
        block: { collision.block(at: $0, terrain: terrain) })
    }
    XCTAssertEqual(player.position, released)
    XCTAssertEqual(player.velocity, .zero)
    XCTAssertTrue(player.flying)
    // There is no reason to generate terrain while querying empty sky.
    XCTAssertEqual(collision.proceduralSamples, 0)
    XCTAssertEqual(collision.count, 0)
  }

  func testEntryWaitsForFirstChunkButDoesNotRestartUntilPlanetChanges() {
    var entry = TerrainEntryReadiness()
    for _ in 0..<100 { entry.observe(chunkReady: false) }
    XCTAssertTrue(entry.isWaiting)
    entry.observe(chunkReady: true)
    XCTAssertFalse(entry.isWaiting)
    for _ in 0..<100 { entry.observe(chunkReady: false) }
    XCTAssertFalse(entry.isWaiting, "Travel must not return to the startup loading state")
    entry.reset()
    entry.observe(chunkReady: false)
    XCTAssertTrue(entry.isWaiting, "A new planet must get its own initial scene readiness")
    entry.observe(chunkReady: true)
    XCTAssertFalse(entry.isWaiting)
  }

  func testFlyingCannotPassThroughEditedWallBeforeMeshArrives() {
    let terrain = TerrainGenerator(seed: 8192)
    var collision = PlayerTerrainCollision()
    var edits: [BlockPosition: Block] = [:]
    for y in 140...145 { for z in -2...2 { edits[.init(17,y,z)] = .brick } }
    var player = PlayerPhysics(position: [15.5, 140, 0.5])
    player.flying = true
    for _ in 0..<60 {
      player.update(deltaTime: 1/60, movement: [1,0,0], jump: false, sprint: true,
        block: { collision.block(at: $0, terrain: terrain, edit: edits[$0]) })
    }
    XCTAssertLessThanOrEqual(player.position.x + PlayerPhysics.radius, 17)
    XCTAssertTrue(player.flying)
    for key in edits.keys { edits[key] = .air }
    for _ in 0..<60 {
      player.update(deltaTime: 1/60, movement: [1,0,0], jump: false, sprint: true,
        block: { collision.block(at: $0, terrain: terrain, edit: edits[$0]) })
    }
    XCTAssertGreaterThan(player.position.x, 50)
  }

  func testDescendingOntoUnrenderedProceduralGroundLandsSafely() {
    let terrain = TerrainGenerator(seed: 8192)
    let spawn = terrain.spawn()
    var player = PlayerPhysics(position: spawn + [0,20,0])
    var collision = PlayerTerrainCollision()
    player.flying = true
    for _ in 0..<600 where player.flying {
      player.update(deltaTime: 1/60, movement: [0,-1,0], jump: false, sprint: false,
        block: { collision.block(at: $0, terrain: terrain) })
    }
    XCTAssertFalse(player.flying)
    XCTAssertTrue(player.grounded)
    XCTAssertFalse(player.collides(at: player.position, block: { collision.block(at: $0, terrain: terrain) }))
    XCTAssertTrue(player.collides(at: player.position - [0,0.4,0], block: { collision.block(at: $0, terrain: terrain) }))
    XCTAssertGreaterThan(collision.proceduralSamples, 0)
    XCTAssertGreaterThan(collision.cacheHits, collision.proceduralSamples)
  }

  func testPreparedVoxelDataAndLiveEditsOverrideCachedTerrain() {
    let terrain = TerrainGenerator(seed: 8192)
    let p = BlockPosition(-2,110,3)
    var collision = PlayerTerrainCollision()
    let generated = collision.block(at: p, terrain: terrain)
    XCTAssertEqual(generated, terrain.block(at: p))
    let samples = collision.proceduralSamples
    var prepared = ChunkData(coordinate: p.chunk)
    prepared[14,110,3] = .brick
    // This is the same data lookup used before the main renderer uploads a mesh.
    XCTAssertEqual(collision.block(at: p, terrain: terrain, chunk: prepared), .brick)
    XCTAssertEqual(collision.block(at: p, terrain: terrain, chunk: prepared, edit: .air), .air)
    prepared[14,110,3] = .air
    XCTAssertEqual(collision.block(at: p, terrain: terrain, chunk: prepared), .air)
    XCTAssertEqual(collision.block(at: p, terrain: terrain, chunk: prepared, edit: .stone), .stone)
    XCTAssertEqual(collision.proceduralSamples, samples)
    // Retiring a render chunk uses the deterministic world again, not a wall.
    XCTAssertEqual(collision.block(at: p, terrain: terrain), generated)
  }

  func testLowFlightDoesNotPauseWhenVoxelDataPublicationIsDelayed() {
    let terrain = TerrainGenerator(seed: 1667327165707871140, style: .dune)
    var collision = PlayerTerrainCollision()
    var player = PlayerPhysics(position: [307.5,110,830.5])
    player.flying = true
    var data: [ChunkCoordinate: ChunkData] = [:]
    for frame in 0..<150 {
      if frame == 80 {
        // Let collision data catch up halfway through; no mesh is uploaded.
        let key = BlockPosition(player.position).chunk
        data[key] = terrain.generate(key)
      }
      player.update(deltaTime: 1/60, movement: [1,0,0], jump: false, sprint: true,
        block: { collision.block(at: $0, terrain: terrain, chunk: data[$0.chunk]) })
    }
    XCTAssertEqual(player.position.x, 307.5 + CreativeFlight.speed * 5, accuracy: 0.01)
    XCTAssertEqual(player.position.y, 110)
    XCTAssertTrue(player.flying)
    XCTAssertGreaterThan(collision.proceduralSamples, 0)
    XCTAssertLessThanOrEqual(collision.count, collision.capacity)
  }

  func testLongTravelCacheEvictsWithoutGrowingOrLeakingAcrossPlanets() {
    var collision = PlayerTerrainCollision(capacity: 32)
    let terrain = TerrainGenerator(seed: 8192)
    for x in 0..<96 {
      let p = BlockPosition(x,127,-3)
      let expected = terrain.block(at: p)
      XCTAssertEqual(collision.block(at: p, terrain: terrain), expected)
      XCTAssertEqual(collision.block(at: p, terrain: terrain), expected)
      XCTAssertLessThanOrEqual(collision.count, 32)
    }
    XCTAssertEqual(collision.count, 32)
    XCTAssertEqual(collision.proceduralSamples, 96)
    XCTAssertEqual(collision.cacheHits, 96)
    let planet = TerrainGenerator(seed: 22, style: .solar), p = BlockPosition(1,40,1)
    XCTAssertEqual(collision.block(at: p, terrain: planet), planet.block(at: p))
    XCTAssertEqual(collision.count, 1)
    XCTAssertEqual(collision.proceduralSamples, 1)
    XCTAssertEqual(collision.cacheHits, 0)
    collision.clear()
    XCTAssertEqual(collision.count, 0)
  }

  func testGeneratedWallsAndCavesMatchWhenTheirRenderDataIsAbsent() {
    let terrain = TerrainGenerator(seed: 8192)
    var collision = PlayerTerrainCollision()
    for x in [-31,-1,0,15,16,48] { for y in stride(from: -50, through: 100, by: 7) {
      let p = BlockPosition(x,y,33)
      XCTAssertEqual(collision.block(at: p, terrain: terrain), terrain.block(at: p))
    } }
    XCTAssertEqual(collision.block(at: .init(0, ChunkData.minimumY-1, 0), terrain: terrain), .stone)
  }

  func testThirdPersonCameraDoesNotHitAnInvisibleChunkBoundary() {
    var camera = ThirdPersonCamera(), collision = PlayerTerrainCollision()
    let terrain = TerrainGenerator(seed: 8192)
    let eye = SIMD3<Float>(15.5,180,15.5)
    let offset = camera.offset(eye: eye, heading: 0, pitch: 0, seconds: 1/60,
      block: { collision.block(at: $0, terrain: terrain) })
    XCTAssertEqual(offset.x, ThirdPersonCamera.boom.x, accuracy: 0.001)
    XCTAssertEqual(offset.y, ThirdPersonCamera.boom.y, accuracy: 0.001)
    XCTAssertEqual(offset.z, ThirdPersonCamera.boom.z, accuracy: 0.001)
    // Actual newly placed walls still retract the camera immediately.
    let blocked = camera.offset(eye: eye, heading: 0, pitch: 0, seconds: 1/60,
      block: { collision.block(at: $0, terrain: terrain, edit: $0.z == 18 ? .brick : nil) })
    XCTAssertLessThan(blocked.z, 3)
    XCTAssertGreaterThan(blocked.z, 0)
  }
}
