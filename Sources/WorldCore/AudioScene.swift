import Foundation

public enum MusicMood: String, CaseIterable, Codable, Sendable {
  case meadow, forest, coast, desert, snow, town, night, cave, underwater, space, lava, race, castle

  public var companions: [MusicMood] {
    switch self {
    case .meadow: [.forest, .coast]
    case .forest: [.meadow, .castle]
    case .coast: [.meadow, .underwater]
    case .desert: [.coast, .meadow]
    case .snow: [.night, .meadow]
    case .town: [.meadow, .castle]
    case .night: [.snow, .space]
    case .cave: [.underwater, .night]
    case .underwater: [.coast, .cave]
    case .space: [.night]
    case .lava: [.cave]
    case .race: []
    case .castle: [.forest, .night]
    }
  }
  public static func select(
    style: PlanetStyle, biome: Biome, daylight: Float,
    space: Bool = false, underwater: Bool = false, racing: Bool = false,
    town: Bool = false, cave: Bool = false, castle: Bool = false
  ) -> Self {
    if space { return .space }
    if racing { return .race }
    if underwater { return .underwater }
    if cave { return .cave }
    if castle { return .castle }
    if style == .solar || biome == .volcanic { return .lava }
    if town { return .town }
    if daylight < 0.25 { return .night }
    switch biome {
    case .woodland, .birchGrove, .autumnForest, .blossomGrove, .taiga, .rainforest, .wetland:
      return .forest
    case .alpine, .tundra: return .snow
    case .desert, .savanna: return .desert
    case .ocean, .coast: return .coast
    case .meadow: return .meadow
    case .volcanic: return .lava
    }
  }
}

public struct MusicTrack: Codable, Equatable, Sendable {
  public let id, title: String
  public let mood: MusicMood
  public let duration, bpm: Double
  public let file: String
}
public struct SoundEffectAsset: Codable, Sendable {
  public let event, file: String
  public let duration: Double
  public let loop: Bool
  public let gain: Double
}
public struct AudioLibrary: Codable, Sendable {
  public let version: Int
  public let tracks: [MusicTrack]
  public let effects: [SoundEffectAsset]
  public init(version: Int, tracks: [MusicTrack], effects: [SoundEffectAsset]) {
    self.version = version
    self.tracks = tracks
    self.effects = effects
  }
}

/// Make common interactions and ambience audible first, then fill in every
/// event and its alternate takes. Loading this plan is background work, never a
/// prerequisite for the first frame. No recording is discarded.
public enum SoundPreloadPlan {
  public static let interval: Duration = .milliseconds(80)

  public static func ordered(_ effects: [SoundEffectAsset]) -> [SoundEffectAsset] {
    let common = ["step_grass", "step_stone", "jump", "land", "hotbar", "inventory_open",
      "break_stone", "place_stone", "hit_stone", "splash", "swim", "car_engine"]
    var chosen = Set<String>()
    var result: [SoundEffectAsset] = []
    func append(_ asset: SoundEffectAsset) {
      if chosen.insert(asset.file).inserted { result.append(asset) }
    }
    for event in common {
      if let asset = effects.first(where: { $0.event == event }) { append(asset) }
    }
    var events = Set<String>()
    for asset in effects where asset.loop {
      if events.insert(asset.event).inserted { append(asset) }
    }
    for asset in effects {
      if events.insert(asset.event).inserted { append(asset) }
    }
    for asset in effects { append(asset) }
    return result
  }
}

/// Stable context selection prevents a biome edge or brief dive from restarting
/// the soundtrack. History spans moods, so crossing boundaries cannot repeat a
/// recently played song. All state is value-only and independent of audio APIs.
public struct MusicDirector: Sendable {
  public private(set) var mood: MusicMood = .meadow
  public private(set) var recent: [String] = []
  private var candidate: MusicMood = .meadow
  private var candidateSince = 0.0
  private var random: UInt64
  public init(seed: UInt64) { random = seed ^ 0x4D55_5349_4342_4147 }
  @discardableResult public mutating func observe(_ desired: MusicMood, at time: Double) -> Bool {
    guard time.isFinite else { return false }
    if desired != candidate {
      candidate = desired
      candidateSince = time
    }
    guard desired != mood, time - candidateSince >= 8 else { return false }
    mood = desired
    return true
  }
  public mutating func start(in mood: MusicMood) {
    self.mood = mood
    candidate = mood
  }
  private mutating func roll(_ count: Int) -> Int {
    random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((random >> 32) % UInt64(max(1, count)))
  }
  public mutating func next(in tracks: [MusicTrack]) -> MusicTrack? {
    let allowed = tracks.filter { $0.mood == mood || mood.companions.contains($0.mood) }
    guard !allowed.isEmpty else { return nil }
    var eligible = allowed.filter { !recent.contains($0.id) }
    if eligible.isEmpty {
      let oldest = allowed.min {
        (recent.firstIndex(of: $0.id) ?? -1) < (recent.firstIndex(of: $1.id) ?? -1)
      }!
      eligible = [oldest]
    }
    let preferred = eligible.filter { $0.mood == mood }
    let pool = !preferred.isEmpty && roll(5) < 4 ? preferred : eligible
    let track = pool[roll(pool.count)]
    recent.removeAll { $0 == track.id }
    recent.append(track.id)
    if recent.count > 12 { recent.removeFirst(recent.count - 12) }
    return track
  }
  public static func crossfade(_ progress: Double) -> (outgoing: Float, incoming: Float) {
    let angle = min(1, max(0, progress)) * .pi / 2
    return (Float(cos(angle)), Float(sin(angle)))
  }
}

public enum SoundSurface: String, CaseIterable, Sendable {
  case grass, dirt, sand, snow, wood, stone, glass, foliage
  public init(_ block: Block) {
    switch block {
    case .grass: self = .grass
    case .dirt: self = .dirt
    case .sand: self = .sand
    case .snow: self = .snow
    case .glass: self = .glass
    case .wood, .birchWood, .spruceWood, .woodStairsEast, .woodStairsWest, .woodStairsSouth, .woodStairsNorth: self = .wood
    default:
      if block.isFoliage { self = .foliage } else { self = .stone }
    }
  }
  public static func material(_ item: InventoryItem) -> Self {
    switch item {
    case .baseball: .wood
    case .plant: .foliage
    case .block(let block): .init(block)
    }
  }
}

/// Cooldowns and a hard voice budget stop repeated impacts or crowded towns
/// from flooding RealityKit with audio entities. Lengths come from the assets,
/// so a long dinosaur roar is never cut at the old two-second timeout.
public struct SoundVoiceBudget: Sendable {
  public static let limit = 24
  private struct Voice: Sendable {
    let id: UInt64
    let event: String
    let expires: Double
    let priority: Int
  }
  private var voices: [Voice] = []
  private var lastEvent: [String: Double] = [:]
  private var sequence: UInt64 = 0
  public init() {}
  public var count: Int { voices.count }
  public mutating func expire(at time: Double) -> [UInt64] {
    let expired = voices.filter { $0.expires <= time }.map(\.id)
    voices.removeAll { $0.expires <= time }
    return expired
  }
  public mutating func admit(event: String, time: Double, duration: Double, priority: Int = 1)
    -> (id: UInt64, replaced: UInt64?)?
  {
    guard time.isFinite, duration.isFinite, duration > 0 else { return nil }
    let cooldown = event.hasPrefix("hit_") ? 0.12 : event.hasPrefix("step_") ? 0.08 : 0.045
    guard time - (lastEvent[event] ?? -.infinity) >= cooldown else { return nil }
    var replaced: UInt64?
    if voices.count >= Self.limit {
      guard let index = voices.indices.min(by: { voices[$0].priority < voices[$1].priority }),
        voices[index].priority <= priority
      else { return nil }
      replaced = voices.remove(at: index).id
    }
    lastEvent[event] = time
    if lastEvent.count > 256 { lastEvent = lastEvent.filter { time - $0.value < 2 } }
    sequence &+= 1
    voices.append(
      .init(id: sequence, event: event, expires: time + duration + 0.15, priority: priority))
    return (sequence, replaced)
  }
  public mutating func clear() {
    voices.removeAll()
    lastEvent.removeAll()
  }
}

public struct VehicleSoundState: Sendable {
  public let id: UInt64
  public let position: SIMD3<Float>
  public let speed: Float
  public let racing, occupied: Bool
  public init(id: UInt64, position: SIMD3<Float>, speed: Float, racing: Bool, occupied: Bool) {
    self.id=id; self.position=position; self.speed=speed; self.racing=racing; self.occupied=occupied
  }
}
