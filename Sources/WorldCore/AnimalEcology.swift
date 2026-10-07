import Foundation

public struct WorldWeather: Sendable {
  public let precipitation: Float
  public let snow: Bool
  public var cloudCover: Float = 0.35
  public var storminess: Float = 0
  public var formation: CloudFormation {
    storminess > 0.6 ? .cumulonimbus : cloudCover > 0.65 ? .stratus : cloudCover < 0.27 ? .cirrus : .cumulus
  }
  public var wet: Bool { precipitation > 0.15 }
  public static func sample(seed: UInt64, time: Double, style: PlanetStyle) -> Self {
    guard style != .solar && style != .ember, time.isFinite, time >= 0 else { return .init(precipitation: 0, snow: false) }
    let window = UInt64(time / 240)
    var value = (seed ^ (window &* 0x9E37_79B1_85EB_CA87)) &+ 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 30)) &* 0x94D0_49BB_1331_11EB
    let phase = Float(time.truncatingRemainder(dividingBy: 240))
    let rainy = value % (style == .dune ? 9 : 4) == 0
    let rain:Float=rainy ? smoothstep(15,40,phase)*(1-smoothstep(185,230,phase)):0
    let front=rainy ? smoothstep(0,40,phase)*(1-smoothstep(195,240,phase)):0
    let fair=0.25+0.16*sin(Float(time)*0.003+Float(seed%100))
    return .init(precipitation:rain,snow:style == .frost,cloudCover:fair+(1-fair)*front,
      storminess:front*(value%3 == 0 ? 0.95:0.45))
  }
}

public enum AnimalGoal: String, Codable, CaseIterable, Sendable {
  case forage, hunt, drink, shelter, sleep, returnHome, migrate, explore, follow, flee
  case rejoinGroup, socialize, protectYoung, patrol, joinHunt
  case beg, greetPlayer, sniff
  public var label: String {
    switch self {
    case .rejoinGroup: "Rejoining group"; case .socialize: "Socializing"; case .protectYoung: "Guarding young"
    case .patrol: "Patrolling territory"; case .joinHunt: "Joining a hunt"
    case .beg: "Hoping for a snack"; case .greetPlayer: "Making a new friend"; case .sniff: "Investigating a smell"
    case .forage: "Foraging"; case .hunt: "Hunting"; case .drink: "Seeking water"
    case .shelter: "Sheltering"; case .sleep: "Sleeping"; case .returnHome: "Returning home"
    case .migrate: "Migrating"; case .explore: "Exploring"; case .follow: "Following a friend"; case .flee: "Escaping danger"
    }
  }
}

extension AnimalKind {
  public var canSwim: Bool { [.fish, .duck, .frog, .bear, .penguin, .otter].contains(self) }
  public var migratory: Bool { [.duck, .parrot, .zebra, .fish].contains(self) }
  public var prey: [AnimalKind] {
    switch self {
    case .wolf: [.rabbit, .sheep, .deer, .goat]
    case .fox: [.rabbit, .chicken, .duck]
    case .bear: [.fish, .rabbit, .deer, .pig]
    case .penguin, .otter: [.fish]
    default: []
    }
  }
  public func forages(_ plant: PlantKind) -> Bool {
    if let food = InventoryItem.plant(plant).food, foods.contains(food) { return true }
    // Grass seed heads are a natural food even though hand-feeding birds uses sunflowers.
    return [.chicken, .duck, .parrot].contains(self) && [.grass, .dryGrass].contains(plant)
  }
}

public struct FaunaRecord: Codable, Sendable {
  public let id: UInt64
  public let species: String
  public var home: SIMD3<Float>
  public var position: SIMD3<Float>
  public var hunger: Float
  public var thirst: Float
  public var fatigue: Float
  public var memory = AgentMemory()
  public var social: FaunaSocialState?
  public var brood: DinosaurBrood?
  public var hatchedDinosaur: HatchedDinosaur?
  public var plan: AgencyPlan?
  public var lastPlan: Double = 0
  public var lastMigration: Double = 0
  public var absentUntil: Double = 0
  public var goal: AnimalGoal = .explore
  public init(id: UInt64, species: String, home: SIMD3<Float>) {
    self.id = id; self.species = species; self.home = home; position = home
    hunger = 0.2 + Float(id % 30) / 100; thirst = 0.15 + Float((id >> 8) % 30) / 100
    fatigue = Float((id >> 16) % 40) / 100
  }
  public var isValid: Bool {
    (DinosaurKind(rawValue: species) != nil || species == "colossal_trex" || AnimalKind.allCases.contains { String(describing: $0) == species })
      && [home, position].allSatisfy { p in (0..<3).allSatisfy { p[$0].isFinite && abs(p[$0]) < 100_000_000 } }
      && [hunger, thirst, fatigue].allSatisfy { $0.isFinite && (0...1).contains($0) }
      && [lastPlan, lastMigration, absentUntil].allSatisfy { $0.isFinite && (0..<1_000_000_000).contains($0) }
      && memory.isValid && (plan?.isValid ?? true) && (social?.isValid ?? true)
      && (brood?.isValid ?? true) && (hatchedDinosaur?.isValid ?? true)
  }
  public mutating func advance(seconds: Float, aquatic: Bool = false) {
    let dt = min(0.25, max(0, seconds))
    hunger = min(1, hunger + dt / 200)
    thirst = aquatic ? 0 : min(1, thirst + dt / 160)
    fatigue = min(1, fatigue + dt / 400)
    if social != nil {
      let interval: Float = DinosaurKind(rawValue: species)?.socialStyle == .solitary ? 1_200 : 220
      social!.need = min(1, social!.need + dt / interval)
    }
  }
  public func localChoice(available: Set<AnimalGoal>, night: Bool, raining: Bool, hungryPredator: Bool) -> AnimalGoal {
    if species == "dog" { return TownDog.choice(self, available: available, night: night, raining: raining) }
    let order: [AnimalGoal] = [.flee, .protectYoung] + (species == "hayHay" ? [.greetPlayer] : [])
      + (thirst > 0.65 ? [.drink] : [])
      + (hunger > 0.6 ? (hungryPredator ? [.joinHunt, .hunt, .forage] : [.forage, .hunt]) : [])
      + (raining ? [.shelter] : [])
      + (night || fatigue > 0.75 ? [.sleep, .returnHome] : [])
      + [.rejoinGroup, .follow]
      + (thirst > 0.4 ? [.drink] : [])
      + (hunger > 0.4 ? [.forage, .hunt] : [])
      + ((social?.need ?? 0) > 0.45 ? [.socialize] : [])
      + [.migrate, .patrol, .explore, .returnHome, .socialize]
    return order.first(where: available.contains) ?? .explore
  }
  public var behaviorDescription: String? {
    if species == "hayHay" { return HayHay.personality }
    if species == "dog" { return TownDog.personality }
    if species == "colossal_trex" {
      return "Solitary colossal T-rex. Roam territory, meet needs and rest. Never pursue the player; acknowledge close visitors with a display."
    }
    return DinosaurKind(rawValue: species)?.behaviorDescription
  }
  public mutating func eat(at point: BlockPosition, time: Double, hunted: Bool = false) {
    hunger = max(0, hunger - (hunted ? 0.65 : 0.4))
    memory.remember(hunted ? .hunted : .foundFood, hunted ? "Successfully hunted prey here" : "Found edible plants here",
      at: point, time: time, importance: 0.65)
  }
  public mutating func drink(seconds: Float, at point: BlockPosition, time: Double) {
    thirst = max(0, thirst - max(0, min(seconds, 0.25)) / 4)
    memory.remember(.foundWater, "Remember this drinking place", at: point, time: time, importance: 0.65)
  }
  public mutating func sleep(seconds: Float) { fatigue = max(0, fatigue - max(0, min(seconds, 0.25)) / 14) }
}

public struct AnimalDecisionOption: Equatable, Sendable {
  public let goal: AnimalGoal
  public let point: BlockPosition
  public let preyID: UInt64?
  public let plant: PlantKind?
  public let partnerID: UInt64?
  public let description: String
  public init(_ goal: AnimalGoal, at point: BlockPosition, preyID: UInt64? = nil, plant: PlantKind? = nil, partnerID: UInt64? = nil, description: String) {
    self.goal = goal; self.point = point; self.preyID = preyID; self.plant = plant; self.partnerID = partnerID; self.description = description
  }
}

public struct JevAnimalRequest: Encodable, Sendable {
  public struct Context: Encodable, Sendable {
    public let species: String
    public let hunger: Float
    public let thirst: Float
    public let fatigue: Float
    public let currentGoal: String
    public let home: BlockPosition
    public let recentExperiences: [String]
    public let longerPlan: String?
    public let speciesBehavior: String?
    public let group: FaunaSocialState?
    public init(_ record: FaunaRecord, time: Double) {
      speciesBehavior = record.behaviorDescription
      group = record.social
      species = record.species; hunger = record.hunger; thirst = record.thirst; fatigue = record.fatigue
      currentGoal = record.goal.rawValue; home = .init(record.home)
      recentExperiences = record.memory.recall(time: time).map(\.detail)
      longerPlan = record.plan.map { "\($0.summary) Priorities: \($0.priorities.map(\.rawValue).joined(separator: ", "))." }
    }
  }
  public struct State: Encodable, Sendable {
    public let weather: String
    public let timeOfDay: String
    public let animals: [String: Context]
  }
  public let model = "jev-latest"
  public let state: State
  public let questions: [String: JevNPCRequest.Question]
  public init(records: [FaunaRecord], options: [UInt64: [String: AnimalDecisionOption]], night: Bool, raining: Bool, time: Double) {
    state = .init(weather: raining ? "Rain or snow; exposed animals need cover" : "Dry", timeOfDay: night ? "Night" : "Day",
      animals: Dictionary(uniqueKeysWithValues: records.map { (String($0.id), Context($0, time: time)) }))
    questions = Dictionary(uniqueKeysWithValues: records.compactMap { animal in
      guard let choices = options[animal.id], !choices.isEmpty else { return nil }
      return ("action_\(animal.id)", .init(instructions:
        "For state.animals['\(animal.id)'], choose its next executable goal. Use speciesBehavior and group relationships. Balance hunger, thirst, tiredness, social need, danger, learned locations and the longer plan. Dependent young seek family. Herds maintain contact and protect young when capable. Solitary adults value territory. Joining a hunt is optional; choose only a listed live prey target. Finish useful actions unless a need or danger is more urgent. Carnivores hunt only listed prey; food and water must actually be reached. Shelter in precipitation. Sleep at the habitual home at night unless hungry, threatened or migrating. A remembered experience is history, not a guarantee a resource still exists.",
        criteria: choices.mapValues(\.description)))
    })
  }
}
