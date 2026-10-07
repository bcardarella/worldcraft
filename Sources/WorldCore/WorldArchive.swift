import Foundation

public struct SavedEdit: Codable, Sendable {
  public var position: BlockPosition
  public var block: Block
  public init(position: BlockPosition, block: Block) {
    self.position = position
    self.block = block
  }
}

public struct WorldSave: Codable, Sendable {
  public var version = 1
  public var seed: UInt64
  public var edits: [SavedEdit]
  public var player: [Float]
  public var flying: Bool
  public var heading: Float
  public var selectedSlot: Int
  public var worldTime: Double?
  public var planetIndex: Int?
  public var visitedPlanets: [SavedPlanet]?
  public var space: SpaceFlight?
  public var systemTime: Double?
  public var viewPitch: Float?
  public var vehicles: [VehicleRecord]?
  public var boats: [BoatRecord]?
  public var boatDriver: UInt64?
  public var residents: [ResidentRecord]?
  public var inventory: Inventory?
  public var plantEdits: [PlantEdit]?
  public var droppedItems: [DroppedItem]?
  public var animalBonds: [AnimalBond]?
  public var homes: [HomeRecord]?
  public var fauna: [FaunaRecord]?
  public var rocket: RocketJourney?
  public var hayHays: HayHayCollection?
  public init(
    seed: UInt64, edits: [SavedEdit], player: [Float], flying: Bool, heading: Float,
    selectedSlot: Int,
    worldTime: Double? = nil, planetIndex: Int? = nil,
    visitedPlanets: [SavedPlanet]? = nil, space: SpaceFlight? = nil, systemTime: Double? = nil,
    viewPitch: Float? = nil, residents: [ResidentRecord]? = nil, vehicles: [VehicleRecord]? = nil,
    rocket: RocketJourney? = nil, inventory: Inventory? = nil, plantEdits: [PlantEdit]? = nil,
    droppedItems: [DroppedItem]? = nil, animalBonds: [AnimalBond]? = nil,
    homes: [HomeRecord]? = nil, fauna: [FaunaRecord]? = nil, hayHays: HayHayCollection? = nil,
    boats: [BoatRecord]? = nil, boatDriver: UInt64? = nil
  ) {
    self.seed = seed
    self.edits = edits
    self.player = player
    self.flying = flying
    self.heading = heading
    self.selectedSlot = selectedSlot
    self.worldTime = worldTime
    self.planetIndex = planetIndex
    self.visitedPlanets = visitedPlanets
    self.space = space
    self.systemTime = systemTime
    self.viewPitch = viewPitch
    self.residents = residents
    self.vehicles = vehicles
    self.boats = boats; self.boatDriver = boatDriver
    self.rocket = rocket
    self.inventory = inventory; self.plantEdits = plantEdits
    self.droppedItems = droppedItems; self.animalBonds = animalBonds
    self.homes = homes; self.fauna = fauna
    self.hayHays = hayHays
  }
}

public struct SavedPlanet: Codable, Sendable {
  public var index: Int
  public var edits: [SavedEdit]
  public var player: [Float]
  public var heading: Float
  public var worldTime: Double
  public var vehicles: [VehicleRecord]?
  public var boats: [BoatRecord]?
  public var plantEdits: [PlantEdit]?
  public var droppedItems: [DroppedItem]?
  public var animalBonds: [AnimalBond]?
  public var homes: [HomeRecord]?
  public var fauna: [FaunaRecord]?
  public var residents: [ResidentRecord]?
  public init(index: Int, edits: [SavedEdit], player: [Float], heading: Float, worldTime: Double,
    residents: [ResidentRecord]? = nil, vehicles: [VehicleRecord]? = nil, plantEdits: [PlantEdit]? = nil,
    droppedItems: [DroppedItem]? = nil, animalBonds: [AnimalBond]? = nil,
    homes: [HomeRecord]? = nil, fauna: [FaunaRecord]? = nil, boats:[BoatRecord]? = nil) {
    self.index = index
    self.edits = edits
    self.player = player
    self.heading = heading
    self.worldTime = worldTime
    self.residents = residents
    self.vehicles = vehicles
    self.boats = boats
    self.plantEdits = plantEdits; self.droppedItems = droppedItems; self.animalBonds = animalBonds
    self.homes = homes; self.fauna = fauna
  }
}

extension WorldSave {
  public var isValid: Bool {
    guard self.version == 1, self.player.count == 3,
      self.player.allSatisfy({ $0.isFinite && abs($0) < 100_000_000 }),
      self.edits.allSatisfy({
        (-100_000_000...100_000_000).contains($0.position.x)
          && (-100_000_000...100_000_000).contains($0.position.z)
          && ((ChunkData.minimumY + 1)..<ChunkData.height).contains($0.position.y)
      }),
      self.heading.isFinite, (0..<Inventory.hotbarCount).contains(self.selectedSlot),
      self.worldTime.map({ $0.isFinite && $0 >= 0 && $0 < 1_000_000_000 }) ?? true,
      self.systemTime.map({ $0.isFinite && $0 >= 0 && $0 < 1_000_000_000 }) ?? true,
      self.viewPitch.map({ $0.isFinite && abs($0) <= (space == nil ? LocomotionInput.maximumLookPitch : .pi / 2) }) ?? true,
      self.planetIndex.map({ (0..<PlanetStyle.allCases.count).contains($0) }) ?? true,
      rocket.map({ $0.isValid && space == nil
        && planetIndex == ($0.usesDestination ? $0.destinationPlanet : $0.originPlanet) }) ?? true,
      inventory.map(\.isValid) ?? true,
      hayHays.map(\.isValid) ?? true,
      plantEdits.map({ $0.count <= 200_000 && $0.allSatisfy(\.isValid) }) ?? true,
      droppedItems.map({ $0.count <= 128 && $0.allSatisfy(\.isValid) && Set($0.map(\.id)).count == $0.count }) ?? true,
      animalBonds.map({ $0.count <= 512 && $0.allSatisfy(\.isValid) }) ?? true,
      homes.map({ $0.count <= 256 && $0.allSatisfy(\.isValid) && Set($0.map(\.id)).count == $0.count }) ?? true,
      fauna.map({ $0.count <= 1_024 && $0.allSatisfy(\.isValid) && Set($0.map(\.id)).count == $0.count }) ?? true,
      vehicles.map({ $0.count <= 128 && $0.allSatisfy(\.isValid) }) ?? true,
      boats.map({ $0.count <= 128 && $0.allSatisfy(\.isValid) && Set($0.map(\.id)).count == $0.count }) ?? true,
      boatDriver.map({ id in boats?.contains(where:{$0.id == id}) == true && space == nil && rocket == nil && !flying }) ?? true,
      residents.map({ $0.count <= 2_048 && $0.allSatisfy(\.isValid) }) ?? true,
      self.visitedPlanets?.allSatisfy({
        (0..<PlanetStyle.allCases.count).contains($0.index) && $0.player.count == 3
          && $0.player.allSatisfy({ $0.isFinite && abs($0) < 100_000_000 }) && $0.heading.isFinite
          && $0.worldTime.isFinite && $0.worldTime >= 0 && $0.worldTime < 1_000_000_000
          && ($0.plantEdits.map({ $0.count <= 200_000 && $0.allSatisfy(\.isValid) }) ?? true)
          && ($0.droppedItems.map({ $0.count <= 128 && $0.allSatisfy(\.isValid) && Set($0.map(\.id)).count == $0.count }) ?? true)
          && ($0.animalBonds.map({ $0.count <= 512 && $0.allSatisfy(\.isValid) }) ?? true)
          && ($0.homes.map({ $0.count <= 256 && $0.allSatisfy(\.isValid) && Set($0.map(\.id)).count == $0.count }) ?? true)
          && ($0.fauna.map({ $0.count <= 1_024 && $0.allSatisfy(\.isValid) && Set($0.map(\.id)).count == $0.count }) ?? true)
          && ($0.vehicles.map({ $0.count <= 128 && $0.allSatisfy(\.isValid) }) ?? true)
          && ($0.boats.map({ $0.count <= 128 && $0.allSatisfy(\.isValid) && Set($0.map(\.id)).count == $0.count }) ?? true)
          && ($0.residents.map({ $0.count <= 2_048 && $0.allSatisfy(\.isValid) }) ?? true)
          && $0.edits.allSatisfy({
            ((ChunkData.minimumY + 1)..<ChunkData.height).contains($0.position.y)
              && (-100_000_000...100_000_000).contains($0.position.x)
              && (-100_000_000...100_000_000).contains($0.position.z)
          })
      }) ?? true,
      self.space.map({
        $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite
          && abs($0.position.x) < 100_000_000 && abs($0.position.y) < 100_000_000
          && abs($0.position.z) < 100_000_000
          && $0.velocity.x.isFinite && $0.velocity.y.isFinite && $0.velocity.z.isFinite
          && $0.speed <= 250
          && $0.heading.isFinite
          && (0..<PlanetStyle.allCases.count).contains($0.originIndex)
      }) ?? true
    else { return false }
    return true
  }
}
