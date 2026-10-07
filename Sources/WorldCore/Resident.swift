import simd
import Foundation

public enum ResidentRole: String, CaseIterable, Codable, Sendable {
  case farmer, baker, builder, merchant, gardener, `guard`, scholar, musician
  public var work: String {
    switch self {
    case .farmer: "Tend crops and supply fresh food"
    case .baker: "Prepare bread and serve neighbors"
    case .builder: "Maintain houses and repair public spaces"
    case .merchant: "Stock a stall and help customers"
    case .gardener: "Care for flowers, trees and the park"
    case .guard: "Patrol the streets and reassure residents"
    case .scholar: "Study, teach and share discoveries"
    case .musician: "Practice and perform in the square"
    }
  }
}

public enum ResidentActivity: String, Codable, CaseIterable, Sendable {
  case work, eat, rest, socialize, stroll, help, greet, flee
  case defend, gather, craft, repair, askHelp
  public var label: String {
    switch self {
    case .work: "Working"
    case .eat: "Having a meal"
    case .rest: "Resting"
    case .socialize: "Catching up"
    case .stroll: "Taking a walk"
    case .help: "Helping a neighbor"
    case .greet: "Saying hello"
    case .flee: "Seeking safety"
    case .defend: "Protecting a home"
    case .gather: "Sourcing materials"
    case .craft: "Making repair supplies"
    case .repair: "Rebuilding a home"
    case .askHelp: "Asking neighbors for help"
    }
  }
}

public enum ConversationTone: String, Codable, CaseIterable, Sendable {
  case warm, practical, playful, reserved
}

public struct ResidentRelationship: Codable, Sendable, Equatable {
  public let otherID: UInt64
  public var affinity: Float
  public var trust: Float
  public var encounters: Int
  public var description: String {
    if trust > 0.75 && affinity > 0.65 { return "close friend" }
    if affinity > 0.45 { return "friend" }
    if affinity < -0.25 { return "strained relationship" }
    return encounters > 0 ? "acquaintance" : "neighbor"
  }
}

public struct ResidentMemory: Codable, Sendable, Equatable {
  public let event: String
  public let otherID: UInt64?
  public let time: Double
  public init(event: String, otherID: UInt64? = nil, time: Double) {
    self.event = event; self.otherID = otherID; self.time = time
  }
}

/// Persistent social state. Geometry, paths and network tasks never enter saves.
public struct ResidentRecord: Codable, Sendable {
  public let id: UInt64
  public var relationships: [ResidentRelationship]
  public var memories: [ResidentMemory]
  public var playerTrust: Float
  public var hunger: Float
  public var fatigue: Float
  public var loneliness: Float
  public var workSatisfaction: Float
  public var playerConversations: Int = 0
  public var agency: ResidentAgency? = nil
  public var isValid: Bool {
    relationships.count <= 12 && memories.count <= 8 && (agency?.isValid ?? true) && (0...1_000_000).contains(playerConversations)
      && [playerTrust, hunger, fatigue, loneliness, workSatisfaction].allSatisfy { $0.isFinite && (0...1).contains($0) }
      && relationships.allSatisfy { $0.otherID != id && $0.affinity.isFinite && (-1...1).contains($0.affinity) && $0.trust.isFinite && (0...1).contains($0.trust) && (0...1_000_000).contains($0.encounters) }
      && memories.allSatisfy { $0.event.count <= 180 && $0.time.isFinite && $0.time >= 0 }
  }
}

public struct ResidentState: Sendable {
  public let id: UInt64
  public let index: Int
  public let name: String
  public let habitat: SettlementHabitat
  public let role: ResidentRole
  public let personality: String
  public let home: SIMD3<Float>
  public let workplace: SIMD3<Float>
  public var position: SIMD3<Float>
  public var heading: Float = 0
  public var gait: Float = 0
  public var moving = false
  public private(set) var activity: ResidentActivity = .stroll
  public private(set) var partnerID: UInt64?
  public private(set) var tone: ConversationTone = .warm
  public private(set) var revision = 0
  public private(set) var lastDecision: Double = -.infinity
  public private(set) var activityProgress: Float = 0
  public var nextDecision: Double = 0
  public var record: ResidentRecord

  public init(index: Int, site: Settlement, saved: ResidentRecord? = nil, homeOverride: SIMD3<Float>? = nil,
    workplaceOverride: SIMD3<Float>? = nil) {
    self.index = index
    habitat = site.habitat
    id = Self.id(index: index, site: site)
    let first = ["Ada", "Rowan", "Mira", "Jules", "Ivo", "Nora", "Kai", "Esme", "Theo", "Lila", "Otis", "Wren", "Remy", "Cleo", "Finn", "Sage"]
    let last = ["Moss", "Reed", "Brook", "Vale", "Finch", "Ash", "Fern", "Stone"]
    name = first[(index + Int(site.id % UInt64(first.count))) % first.count] + " "
      + last[(index / first.count + Int((site.id >> 8) % UInt64(last.count))) % last.count]
    role = ResidentRole.allCases[(index + Int(site.id % 8)) % ResidentRole.allCases.count]
    personality = ["gregarious and generous", "quiet and curious", "diligent but enjoys company", "playful and adventurous", "patient and nurturing", "independent and practical"][Int((id >> 16) % 6)]
    home = homeOverride ?? site.meetingPoint(index: index, purpose: .home)
    workplace = workplaceOverride ?? site.meetingPoint(index: index, purpose: .work, near: home)
    position = home
    var relationships: [ResidentRelationship] = []
    for offset in [1, 2, site.population - 1] {
      let other = Self.id(index: (index + offset) % site.population, site: site)
      let pair = min(id, other) ^ (max(id, other) &* 0x9E37_79B1)
      relationships.append(.init(otherID: other, affinity: Float(pair % 100) / 100 - 0.2,
        trust: 0.4 + Float((pair >> 8) % 40) / 100, encounters: 0))
    }
    if let saved, saved.id == id, saved.isValid { record = saved }
    else {
      record = .init(id: id, relationships: relationships, memories: [], playerTrust: 0.5,
        hunger: Float(id % 45) / 100, fatigue: Float((id >> 8) % 45) / 100,
        loneliness: Float((id >> 16) % 60) / 100, workSatisfaction: Float((id >> 24) % 40) / 100)
    }
  }

  public var roleName: String {
    let index = ResidentRole.allCases.firstIndex(of: role) ?? 0
    switch habitat {
    case .surface: return role.rawValue.capitalized
    case .solar: return ["Ember grower", "Hearth cook", "Basalt mason", "Ore trader", "Crystal tender", "Heat warden", "Solar scholar", "Forge musician"][index]
    case .aquatic: return ["Kelp farmer", "Reef cook", "Shell builder", "Pearl trader", "Coral gardener", "Reef guardian", "Current scholar", "Tide singer"][index]
    }
  }
  public var workDescription: String {
    let index = ResidentRole.allCases.firstIndex(of: role) ?? 0
    switch habitat {
    case .surface: return role.work
    case .solar: return ["Tend sheltered geothermal food beds", "Cook meals using furnace heat", "Repair heat-resistant basalt homes", "Trade volcanic glass and ore", "Cultivate mineral crystal gardens", "Patrol safe streets beside molten vents", "Study convection in the lava seas", "Play music at the forge square"][index]
    case .aquatic: return ["Harvest kelp for the reef market", "Prepare seaweed meals for neighbors", "Maintain flooded shell homes and swim passages", "Trade pearls at the submerged market", "Nurture branching coral gardens", "Swim patrols around the reef", "Study currents and marine life", "Sing with friends in the underwater square"][index]
    }
  }

  public static func id(index: Int, site: Settlement) -> UInt64 {
    var value = site.id &+ UInt64(index + 1) &* 0x9E37_79B1_85EB_CA87
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
  public mutating func choose(_ action: ResidentActivity, partner: UInt64? = nil,
    tone: ConversationTone = .warm, time: Double) {
    activity = action; partnerID = partner; self.tone = tone
    revision &+= 1; lastDecision = time; activityProgress = 0
    nextDecision = time + 18 + Double(id % 9)
  }
  public mutating func reconsider(at time: Double) {
    revision &+= 1
    nextDecision = time
  }

  public mutating func advanceNeeds(seconds: Float, arrived: Bool, time: Double? = nil) {
    let dt = max(0, min(0.25, seconds))
    let previous = record
    record.hunger = min(1, record.hunger + dt / 240)
    record.fatigue = min(1, record.fatigue + dt / 420)
    record.loneliness = min(1, record.loneliness + dt / 220)
    record.workSatisfaction = max(0, record.workSatisfaction - dt / 400)
    if arrived {
      activityProgress += dt
      switch activity {
      case .eat: record.hunger = max(0, record.hunger - dt / 12)
      case .rest: record.fatigue = max(0, record.fatigue - dt / 22)
      case .work, .craft, .gather, .repair: record.workSatisfaction = min(1, record.workSatisfaction + dt / 25)
      case .socialize, .help, .greet: record.loneliness = max(0, record.loneliness - dt / 16)
      default: break
      }
    }
    guard let time, activity != .flee else { return }
    let urgent = (previous.hunger < 0.75 && record.hunger >= 0.75)
      || (previous.fatigue < 0.8 && record.fatigue >= 0.8)
      || (previous.loneliness < 0.75 && record.loneliness >= 0.75)
    let fulfilled = (activity == .eat && previous.hunger > 0.1 && record.hunger <= 0.1)
      || (activity == .rest && previous.fatigue > 0.1 && record.fatigue <= 0.1)
      || (activity == .work && previous.workSatisfaction < 0.85 && record.workSatisfaction >= 0.85)
      || (activity == .socialize && previous.loneliness > 0.1 && record.loneliness <= 0.1)
    if urgent || fulfilled {
      if fulfilled { remember("Finished \(activity.label.lowercased()); ready for something else", time: time) }
      reconsider(at: min(nextDecision, time + 0.25))
    }
  }

  public mutating func remember(_ event: String, other: UInt64? = nil, time: Double) {
    record.memories.append(.init(event: String(event.prefix(180)), otherID: other, time: time))
    if record.memories.count > 8 { record.memories.removeFirst(record.memories.count - 8) }
  }

  public mutating func meet(_ other: UInt64, helping: Bool, time: Double) {
    guard other != id else { return }
    if let i = record.relationships.firstIndex(where: { $0.otherID == other }) {
      record.relationships[i].affinity = min(1, record.relationships[i].affinity + (helping ? 0.07 : 0.035))
      record.relationships[i].trust = min(1, record.relationships[i].trust + (helping ? 0.05 : 0.015))
      record.relationships[i].encounters = min(1_000_000, record.relationships[i].encounters + 1)
    } else {
      if record.relationships.count == 12 { record.relationships.removeFirst() }
      record.relationships.append(.init(otherID: other, affinity: 0.15, trust: 0.45, encounters: 1))
    }
    remember(helping ? "Helped a neighbor with their work" : "Shared a friendly conversation", other: other, time: time)
    if record.agency == nil { record.agency = .init() }
    record.agency?.memory.remember(helping ? .helped : .socialized,
      helping ? "Worked together with this neighbor" : "Enjoyed a conversation with this neighbor", other: other,
      time: time, importance: helping ? 0.7 : 0.5)
  }

  /// Used only when remote decisions are unavailable; no rigid work timetable.
  public func localChoice(night: Bool, nearby: UInt64?) -> ResidentActivity {
    if record.hunger > 0.65 { return .eat }
    if record.fatigue > (night ? 0.40 : 0.8) { return .rest }
    if record.loneliness > 0.45 && nearby != nil { return .socialize }
    return record.workSatisfaction < 0.65 ? .work : .stroll
  }

  public func line(settlement: String, biome: String, familiar: Bool) -> String {
    if activity == .defend { return "Please stop damaging our home. We live here." }
    if activity == .repair { return "I'm patching our home with the supplies we've gathered." }
    if activity == .gather { return "We need materials for the repairs. I'm bringing back what I can find." }
    if activity == .craft { return "I'm making repair supplies from raw materials at the worksite." }
    if activity == .askHelp { return "I need a hand protecting and rebuilding our home." }
    if activity == .flee { return "Something big is coming. Let's get to safety!" }
    if record.hunger > 0.75 { return "I could use a bite to eat. Come along to the market?" }
    if record.fatigue > 0.75 { return "It's been a long day. I think I'll head home soon." }
    if let memory = record.memories.last, memory.event.contains("damaged") {
      return "Someone damaged the street. We'll have to find a way around it."
    }
    if habitat != .surface && record.playerConversations % 4 == 1 {
      return "I'm a \(roleName.lowercased()). \(workDescription). "
        + (habitat == .aquatic ? "Swim up through the roof openings to visit our neighbors." : "Keep to the basalt streets; the molten vents are lively today.")
    }
    let opening = familiar ? "Good to see you again! " : "Hello, I'm \(name). "
    if record.playerConversations % 4 == 1 {
      let detail: String = switch role {
      case .farmer: "I grow food for our market. A warm meal makes a long day better."
      case .baker: "I bake for the neighborhood. I like seeing everyone stop by for breakfast."
      case .builder: "I look after the houses here. Leave room for a path when you build!"
      case .merchant: "My stall keeps me busy, but I always make time for a good conversation."
      case .gardener: "I care for the gardens. The flowers in the \(biome.lowercased()) are my favorites."
      case .guard: "I watch the streets. If a T-rex wanders close, give it plenty of space."
      case .scholar: "I study the world around us. Every planet has something new to discover."
      case .musician: "I practice in the square. The whole town feels different when friends gather."
      }
      return detail
    }
    if record.playerConversations % 4 == 2 {
      return activity == .work ? "I'm in the middle of a job. Maybe we can take a walk once it's done."
        : "I'm \(activity.label.lowercased()) just now. What brings you to \(settlement)?"
    }
    switch tone {
    case .playful: return opening + "A \(role.rawValue) needs an adventure now and then. Have you explored the \(biome.lowercased())?"
    case .reserved: return opening + "I like the quiet corners of \(settlement)."
    case .practical: return opening + workDescription + " — that's my job here."
    case .warm: return opening + "Welcome to \(settlement). There's always room for another neighbor."
    }
  }
}

public enum MeetingPurpose { case home, work, meal, leisure }
extension Settlement {
  /// Public destinations lie on the street grid, with unique front-door offsets.
  public func meetingPoint(index: Int, purpose: MeetingPurpose, near home: SIMD3<Float>? = nil) -> SIMD3<Float> {
    let lots = max(1, radius / spacing)
    let baseCol = home.map { floorDivide(Int($0.x)-x,by:spacing) } ?? (index % (lots*2)-lots)
    let baseRow = home.map { floorDivide(Int($0.z)-z,by:spacing) } ?? ((index/(lots*2)) % (lots*2)-lots)
    // Daily errands stay in neighboring blocks instead of forcing everyone to
    // cross an entire city to reach a single shared destination.
    let col = min(lots-1,max(-lots,baseCol + (purpose == .work ? 1 : purpose == .leisure ? -1 : 0)))
    let row = min(lots-1,max(-lots,baseRow + (purpose == .meal ? 1 : 0)))
    let along = spacing/2 + (index % 3-1)*2
    let px = min(radius - 3, max(-radius + 3, col * spacing + along))
    let pedestrianOffset = habitat == .aquatic ? 0 : streetHalfWidth + max(1,sidewalkWidth/2)
    let pz = min(radius - 3, max(-radius + 3, row * spacing + pedestrianOffset))
    let depth: Float = habitat == .aquatic ? Float(2 + (index % 4) * 2) : 0
    var destination=center + [Float(px) + 0.5, depth, Float(pz) + 0.5]
    if let field=sportsGround(atX:Int(destination.x),z:Int(destination.z)) {
      // Errands belong on the pavement, never on a pitch, bench or grandstand.
      let candidates:[SIMD3<Float>]=[[Float(field.x0)-3,destination.y,destination.z],
        [Float(field.x1)+3,destination.y,destination.z],
        [destination.x,destination.y,Float(field.z0)-3],[destination.x,destination.y,Float(field.z1)+3]]
      destination=candidates.min {simd_distance_squared($0,destination)<simd_distance_squared($1,destination)}!
    }
    return destination
  }
}
