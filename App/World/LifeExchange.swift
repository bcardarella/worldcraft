import Foundation
import WorldCore

/// Value-only messages; no RealityKit entity, live world closure, or mutable UI
/// object crosses the simulation boundary. Chunk storage is copy-on-write.
struct LifeWorldSnapshot: Sendable {
  var terrain: TerrainGenerator
  var chunks: [ChunkCoordinate: ChunkData]
  var plants: [ChunkCoordinate: [PlantInstance]]
  var obstacle: RocketPort?
  var revision: UInt64
  var doors: [BuildingDoorState] = []
  var loaded: Set<ChunkCoordinate> { Set(chunks.keys) }
  func block(_ p: BlockPosition) -> Block {
    if obstacle?.blocksTraffic(p) == true { return .basalt }
    guard let chunk = chunks[p.chunk] else { return .stone }
    return chunk[p.x - p.chunk.x * 16, p.y, p.z - p.chunk.z * 16]
  }
}
struct LifeFrame: Sendable {
  let world: LifeWorldSnapshot
  let environment: WorldEnvironment
  let player: SIMD3<Float>
  let seconds: Float
  let animals: [FaunaSnapshot]
  let wildlife: [AnimalState]
  let threats: [SIMD3<Float>]
  let offering: AnimalFood?
  let flying: Bool
  let driving: Bool
  let logs: Bool
  var dinosaurs = DinosaurPopulation()
  var drawRadius: Int = 1
  var traffic: [VehicleTraffic] = []
  var mount: MountedRide?
  var hayHayIDs: [UInt64] = []
  var hiddenCastleHayHay: UInt64?
  var companionCarrier: CompanionCarrier?
}
enum LifeEffect: Sendable, Equatable {
  case edit(BlockPosition, expected: Block, replacement: Block)
  case eat(BlockPosition, PlantKind)
  case hunt(UInt64)
  case trample([CrushedBlock], [PlantInstance])
}
enum LifeCommand: Sendable {
  case reset, suspend
  case restoreResidents([ResidentRecord], [HomeRecord])
  case restoreFauna([FaunaRecord])
  case jev(String?, Bool)
  case reasoning(String?, Bool, Double)
  case fed(UInt64, SIMD3<Float>, Double), petted(UInt64, SIMD3<Float>, Double)
  case talk(UInt64)
  case edited(BlockPosition, Block, Block, TerrainGenerator, Double)
  case welcome(RocketPort, TerrainGenerator, Double)
  case celebrate(String, Double)
}
struct LifeView: Sendable {
  var residents: [ResidentState] = []
  var residentRecords: [ResidentRecord] = []
  var residentPositions: [SIMD3<Float>] = []
  var homes: [HomeRecord] = []
  var properties: [OwnedHome] = []
  var fauna: [FaunaRecord] = []
  var faunaByID: [UInt64: FaunaRecord] = [:]
  var directives: [UInt64: AnimalDecisionOption] = [:]
  var site: Settlement?
  var conversation = ""
  var welcomeReady = false
  var celebrating = false
  var decisionStatus = "Local life"
  var faunaStatus = "Local animal instincts"
  var reasoningStatus = "Reasoning ready when needed"
  var decisionLatencyMilliseconds: Double = 0
  var acceptedDecisions = 0
  var rejectedDecisions = 0
  var interventions: [(String, SIMD3<Float>)] = []
}
struct LifeProposal: Sendable {
  let id: UInt64
  let view: LifeView
  let effects: [LifeEffect]
  let creatures: CreatureStep
  let milliseconds: Double
  let ranOnMainThread: Bool
}

/// Mutations inside a proposal see earlier staged changes. Their effects are
/// published only if the main actor validates the entire proposal. Rejecting it
/// restores stocks, hunger, paths and memories to the pre-step checkpoint.
@SimulationActor final class LifeStagingWorld {
  let source: LifeWorldSnapshot
  private(set) var effects: [LifeEffect] = []
  private var overrides: [BlockPosition: Block] = [:]
  private var eaten = Set<BlockPosition>()
  private var hunted = Set<UInt64>()
  private let animals: Set<UInt64>
  var protectedAnimals = Set<UInt64>()
  init(_ source: LifeWorldSnapshot, animals: [FaunaSnapshot]) {
    self.source = source; self.animals = Set(animals.map(\.id))
  }
  func block(_ p: BlockPosition) -> Block { overrides[p] ?? source.block(p) }
  func nearbyPlants(_ position: SIMD3<Float>) -> [PlantInstance] {
    let center = BlockPosition(position).chunk
    var found: [PlantInstance] = []
    for x in -2...2 { for z in -2...2 {
      for plant in source.plants[.init(center.x + x, center.z + z)] ?? [] where !eaten.contains(plant.position) {
        let d = plant.center - position
        if d.x * d.x + d.y * d.y + d.z * d.z < 24 * 24 { found.append(plant) }
      }
    } }
    return found
  }
  func edit(_ point: BlockPosition, _ expected: Block, _ replacement: Block) -> Bool {
    guard effects.count < 8, overrides[point] == nil, block(point) == expected else { return false }
    overrides[point] = replacement; effects.append(.edit(point, expected: expected, replacement: replacement)); return true
  }
  func eat(_ point: BlockPosition, _ kind: PlantKind) -> Bool {
    guard effects.count < 8, !eaten.contains(point), source.plants[point.chunk]?.contains(where: { $0.position == point && $0.kind == kind }) == true else { return false }
    eaten.insert(point); effects.append(.eat(point, kind)); return true
  }
  func hunt(_ id: UInt64) -> Bool {
    guard effects.count < 8, !protectedAnimals.contains(id), animals.contains(id), hunted.insert(id).inserted else { return false }
    effects.append(.hunt(id)); return true
  }
  func trample(_ proposed:[CrushedBlock]) {
    let blocks=proposed.prefix(512).filter { source.obstacle?.blocksTraffic($0.position) != true && overrides[$0.position] == nil }
    guard !blocks.isEmpty else { return }
    let points=Set(blocks.map(\.position)),chunks=Set(points.map(\.chunk))
    let plants=chunks.flatMap { source.plants[$0] ?? [] }.filter {
      !eaten.contains($0.position) && (points.contains($0.position) || points.contains($0.position + .init(0,-1,0)))
    }.prefix(128)
    for b in blocks { overrides[b.position] = .air }
    for plant in plants { eaten.insert(plant.position) }
    effects.append(.trample(blocks,Array(plants)))
  }
}
