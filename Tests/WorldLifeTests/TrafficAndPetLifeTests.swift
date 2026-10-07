import XCTest
import simd
@testable import WorldCore
@testable import WorldLife

@SimulationActor final class TrafficAndPetLifeTests: XCTestCase {
  func testLargeCitiesStreamIndependentNeighborhoodsAndRetainMemories() async throws {
    let terrain = TerrainGenerator(seed:8192)
    let site = try XCTUnwrap((-8...8).lazy.flatMap { x in (-8...8).compactMap { SettlementGenerator.site(in:.init(x,$0),terrain:terrain) } }.first { $0.kind == .city })
    let life = SettlementSimulation()
    var clock: Double = 100
    func visit(_ point: SIMD3<Float>) {
      let center = BlockPosition(point).chunk
      let loaded = Set((-10...10).flatMap { x in (-10...10).map { ChunkCoordinate(center.x+x,center.z+$0) } })
      for _ in 0..<28 {
        clock += 0.08
        life.update(terrain:terrain,player:point,deltaTime:0.08,environment:.init(elapsed:clock),
          threats:[],loaded:loaded,block:{ $0.y < site.floor ? .stone : .air })
      }
      XCTAssertEqual(life.currentSite?.id,site.id)
      XCTAssertGreaterThan(life.count,5)
      XCTAssertLessThanOrEqual(life.count,48)
    }
    let firstDistrict = site.center + [-300,0,-300]
    visit(firstDistrict)
    let first = try XCTUnwrap(life.states.first)
    life.interact(with:first.id)
    let conversationCount = life.records.first { $0.id == first.id }!.playerConversations
    XCTAssertGreaterThan(conversationCount,0)
    let firstIDs = Set(life.states.map(\.id)), restore = life.checkpoint()
    // Visit a residential district; the southeast quarter is now a stadium.
    visit(site.center + [300,0,-300])
    XCTAssertTrue(firstIDs.isDisjoint(with:life.states.map(\.id)))
    XCTAssertEqual(life.records.first { $0.id == first.id }?.playerConversations,conversationCount)
    restore()
    XCTAssertEqual(Set(life.states.map(\.id)),firstIDs)
    visit(firstDistrict)
    XCTAssertEqual(life.states.first { $0.id == first.id }?.record.playerConversations,conversationCount)
  }
  func testTrafficSweepsSurviveSkippedTicksAndRollbackRestoresPeople() async throws {
    let terrain = TerrainGenerator(seed:8192)
    let site = try XCTUnwrap(SettlementGenerator.site(in:.init(0,0),terrain:terrain))
    let town = SettlementSimulation()
    let center = BlockPosition(site.center).chunk
    let loaded = Set((-8...8).flatMap { x in (-8...8).map { z in ChunkCoordinate(center.x+x,center.z+z) } })
    func block(_ p: BlockPosition) -> Block { p.y < site.floor ? .stone : .air }
    func tick(_ seconds: Float, _ time: Double, _ traffic: [VehicleTraffic] = []) {
      town.update(terrain:terrain,player:site.center,deltaTime:seconds,environment:.init(elapsed:time),
        threats:[],traffic:traffic,loaded:loaded,block:block)
    }
    for i in 0..<5 { tick(0.08,500+Double(i)*0.08) }
    let before = try XCTUnwrap(town.states.first)
    let restore = town.checkpoint()
    let start = before.position+[0,0,6], end = before.position-[0,0,6]
    tick(0.03,501,[.init(id:3,position:end,previousPosition:start,velocity:.zero,heading:0,playerDriven:true)])
    XCTAssertFalse(town.states.first!.record.memories.contains { $0.event.contains("bumped") })
    // The car has already stopped. The retained sweep must still push the
    // resident when the lower-frequency town simulation next runs.
    tick(0.04,501.04,[.init(id:3,position:end,previousPosition:end,velocity:.zero,heading:0,playerDriven:true)])
    let after = try XCTUnwrap(town.states.first { $0.id == before.id })
    XCTAssertGreaterThan(abs(after.position.x-before.position.x),1.7)
    XCTAssertTrue(after.record.memories.contains { $0.event.contains("bumped") })
    XCTAssertLessThan(after.record.playerTrust,before.record.playerTrust)
    XCTAssertNotNil(ResidentNavigation.walkingPosition(at:after.position,block:block))
    restore()
    XCTAssertEqual(town.states.first!.position,before.position)
    XCTAssertFalse(town.states.first!.record.memories.contains { $0.event.contains("bumped") })
  }
  func testHayHayWaitsThenRemembersPettingAndChoosesToFollow() async throws {
    let home = SIMD3<Float>(8.5,30,8.5), life = FaunaSimulation()
    var record = FaunaRecord(id:777,species:"hayHay",home:home)
    record.hunger = 0.05; record.thirst = 0; record.fatigue = 0
    life.restore([record])
    let loaded = Set((-2...2).flatMap { x in (-2...2).map { ChunkCoordinate(x,$0) } })
    func tick(_ time: Double, following: Bool) {
      let actor = FaunaSnapshot(id:777,species:"hayHay",kind:.hayHay,position:home,home:home,trusting:true,following:following)
      life.update(actors:[actor],deltaTime:0.1,time:time,player:home+[3,0,0],offering:nil,
        weather:.sample(seed:0,time:0,style:.verdant),night:false,loaded:loaded,
        plants:{_ in []},block:{$0.y < 30 ? .stone : .air})
    }
    tick(100,following:false)
    XCTAssertEqual(life.directive(id:777)?.goal,.returnHome)
    life.petted(id:777,at:home,time:101)
    tick(101.1,following:true)
    XCTAssertEqual(life.directive(id:777)?.goal,.follow)
    let saved = try JSONDecoder().decode([FaunaRecord].self,from:JSONEncoder().encode(life.records))
    XCTAssertTrue(saved[0].memory.experiences.contains { $0.kind == .metPlayer })
    XCTAssertEqual(JevAnimalRequest.Context(saved[0],time:102).speciesBehavior,HayHay.personality)
  }
  func testCompanionsBoardAndTravelWithoutWaitingForGroundChunks() async {
    let creatures=CreatureSimulation(),life=FaunaSimulation(),terrain=TerrainGenerator(seed:42)
    let ids=(1...16).map { UInt64($0) }
    var wildlife:[AnimalState]=[]
    var time:Double=100
    let rides:[CompanionCarrier.Kind]=[.car(.sports),.boat(.megaYacht),.boat(.jetSki)]
    for (index,kind) in rides.enumerated() {
      var carrier=CompanionCarrier(id:UInt64(90+index),kind:kind,position:[4000*Float(index),100,-2000],heading:Float(index))
      carrier.journey=UInt64(index+1)
      for _ in 0..<16 {
        time+=0.08
        let frame=companionFrame(terrain:terrain,player:carrier.position,wildlife:wildlife,ids:ids,carrier:carrier,time:time)
        wildlife=creatures.step(frame,world:.init(frame.world,animals:[]),site:nil,life:life).wildlife
      }
      XCTAssertEqual(Set(wildlife.map(\.id)),Set(ids))
      XCTAssertEqual(wildlife.filter {$0.passenger?.visible == true}.count,carrier.capacity)
      for pet in wildlife {
        XCTAssertEqual(pet.passenger?.carrier.id,carrier.id)
        XCTAssertEqual(pet.companionJourney,carrier.journey)
        XCTAssertEqual(pet.position,carrier.passenger(ordinal:ids.firstIndex(of:pet.id)!).position)
        XCTAssertFalse(pet.moving)
      }
    }
  }
  func testCompanionsWaitAboardOverWaterThenDisembarkSeparatelyOnDryGround() async throws {
    let creatures=CreatureSimulation(),life=FaunaSimulation(),terrain=TerrainGenerator(seed:42)
    let ids:[UInt64]=[1,2,3,4]
    var carrier=CompanionCarrier(id:90,kind:.boat(.motorboat),position:[8,30,8],heading:0)
    carrier.journey=4
    var wildlife=ids.enumerated().map { i,id in
      var pet=HayHayCollection.companion(id:id,at:.zero);pet.board(carrier,ordinal:i);return pet
    }
    let player=SIMD3<Float>(12,30,8)
    var frame=companionFrame(terrain:terrain,player:player,wildlife:wildlife,ids:ids,time:200)
    // No supporting terrain (including a boat exit at sea) must not strand a
    // companion inside the water or let walking logic move them off the seat.
    wildlife=creatures.step(frame,world:.init(frame.world,animals:[]),site:nil,life:life).wildlife
    XCTAssertTrue(wildlife.allSatisfy {$0.passenger != nil})
    var sea:[ChunkCoordinate:ChunkData]=[:]
    for x in -1...2 {for z in -1...2 {
      let coordinate=ChunkCoordinate(x,z)
      var chunk=ChunkData(coordinate:coordinate)
      for a in 0..<16 {for b in 0..<16 {for y in 24...36 {chunk[a,y,b] = .water}}}
      sea[coordinate]=chunk
    }}
    frame=companionFrame(terrain:terrain,player:player,wildlife:wildlife,ids:ids,time:200.1,chunks:sea)
    wildlife=creatures.step(frame,world:.init(frame.world,animals:[]),site:nil,life:life).wildlife.filter {ids.contains($0.id)}
    XCTAssertEqual(wildlife.count,4)
    XCTAssertTrue(wildlife.allSatisfy {$0.passenger != nil && !$0.moving})
    var chunks:[ChunkCoordinate:ChunkData]=[:]
    for x in -1...2 {for z in -1...2 {
      let coordinate=ChunkCoordinate(x,z)
      var chunk=ChunkData(coordinate:coordinate)
      for a in 0..<16 {for b in 0..<16 {chunk[a,29,b] = .stone}}
      chunks[coordinate]=chunk
    }}
    for i in 0..<3 {
      frame=companionFrame(terrain:terrain,player:player,wildlife:wildlife,ids:ids,time:201+Double(i)*0.08,chunks:chunks)
      wildlife=creatures.step(frame,world:.init(frame.world,animals:[]),site:nil,life:life).wildlife.filter { ids.contains($0.id) }
    }
    XCTAssertEqual(wildlife.count,4)
    XCTAssertTrue(wildlife.allSatisfy {$0.passenger == nil && $0.companionJourney==4})
    for (i,pet) in wildlife.enumerated() {
      XCTAssertFalse(carrier.obstructsCompanion(at:pet.position))
      XCTAssertTrue(AnimalKind.hayHay.canStand(at:pet.position,juvenile:false,block:frame.world.block))
      for other in wildlife.dropFirst(i+1) {XCTAssertGreaterThan(simd_distance(pet.position,other.position),1.1)}
    }
  }
  private func companionFrame(terrain:TerrainGenerator,player:SIMD3<Float>,wildlife:[AnimalState],ids:[UInt64],
    carrier:CompanionCarrier?=nil,time:Double,chunks:[ChunkCoordinate:ChunkData]=[:])->LifeFrame {
    .init(world:.init(terrain:terrain,chunks:chunks,plants:[:],obstacle:nil,revision:0),
      environment:.init(elapsed:time),player:player,seconds:0.08,animals:[],wildlife:wildlife,
      threats:[],offering:nil,flying:false,driving:carrier != nil,logs:false,hayHayIDs:ids,companionCarrier:carrier)
  }
}
