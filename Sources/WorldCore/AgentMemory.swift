import Foundation

public enum ExperienceKind: String, Codable, CaseIterable, Sendable {
  case homeDamaged, helped, refusedHelp, repaired, foundMaterial, failedRoute
  case foundFood, foundWater, foundShelter, fedByPlayer, hunted, danger, migrated
  case socialized, metPlayer
}

public struct Experience: Codable, Equatable, Sendable {
  public let kind: ExperienceKind
  public var detail: String
  public var point: BlockPosition?
  public var other: UInt64?
  public var time: Double
  public var importance: Float
  public var occurrences: Int
  public var isValid: Bool {
    detail.count <= 180 && time.isFinite && (0..<1_000_000_000).contains(time)
      && importance.isFinite && (0...1).contains(importance) && (1...100_000).contains(occurrences)
      && (point.map { abs(Double($0.x)) < 100_000_000 && abs(Double($0.z)) < 100_000_000
        && (ChunkData.minimumY..<ChunkData.height).contains($0.y) } ?? true)
  }
}

/// Important autobiographical facts outlive routine observations. Repeated
/// experiences consolidate; retrieval supplies only relevant memories to models.
public struct AgentMemory: Codable, Equatable, Sendable {
  public private(set) var experiences: [Experience] = []
  public init() {}
  public var isValid: Bool { experiences.count <= 32 && experiences.allSatisfy(\.isValid) }
  public mutating func remember(_ kind: ExperienceKind, _ detail: String, at point: BlockPosition? = nil,
    other: UInt64? = nil, time: Double, importance: Float = 0.5) {
    let entry = Experience(kind: kind, detail: String(detail.prefix(180)), point: point, other: other,
      time: time, importance: importance, occurrences: 1)
    guard entry.isValid else { return }
    if let i = experiences.firstIndex(where: { $0.kind == kind && $0.point == point && $0.other == other }) {
      experiences[i].time = time; experiences[i].detail = entry.detail
      experiences[i].importance = max(experiences[i].importance, importance)
      experiences[i].occurrences = min(100_000, experiences[i].occurrences + 1)
    } else { experiences.append(entry) }
    if experiences.count > 32 {
      let least = experiences.indices.min { score(experiences[$0], time: time) < score(experiences[$1], time: time) }!
      experiences.remove(at: least)
    }
  }
  public func recall(time: Double, relevant: Set<ExperienceKind> = [], limit: Int = 6) -> [Experience] {
    experiences.sorted {
      score($0, time: time) + (relevant.contains($0.kind) ? 2 : 0)
        > score($1, time: time) + (relevant.contains($1.kind) ? 2 : 0)
    }.prefix(max(0, min(12, limit))).map { $0 }
  }
  private func score(_ item: Experience, time: Double) -> Double {
    Double(item.importance) * 3 + 1 / (1 + max(0, time - item.time) / 240)
      + min(0.5, Double(item.occurrences) * 0.03)
  }
}

public enum AgencyPriority: String, CaseIterable, Codable, Sendable {
  case safety, defendHome, recruitHelp, gather, craft, repair, food, water, shelter, sleep, migrate, socialize
}
public enum MaterialPolicy: String, CaseIterable, Codable, Sendable { case exact, craftFirst, suitableSubstitutes }
public enum SocialApproach: String, CaseIterable, Codable, Sendable { case independent, askFriends, askSkilledNeighbors, avoidConflict }

/// A model's concise actionable plan, never its private reasoning transcript.
/// Models can advise only these capabilities; the simulation owns execution.
public struct AgencyPlan: Codable, Equatable, Sendable {
  public var priorities: [AgencyPriority]
  public var materials: MaterialPolicy
  public var social: SocialApproach
  public var summary: String
  public init(priorities: [AgencyPriority], materials: MaterialPolicy = .craftFirst,
    social: SocialApproach = .askFriends, summary: String) {
    self.priorities = priorities; self.materials = materials; self.social = social; self.summary = summary
  }
  public var isValid: Bool {
    !priorities.isEmpty && priorities.count <= 5 && Set(priorities).count == priorities.count
      && !summary.isEmpty && summary.count <= 220 && !summary.contains("\u{0000}")
  }
}

public struct ResidentAgency: Codable, Sendable {
  public var memory = AgentMemory()
  public var plan: AgencyPlan?
  public var plannedIncident: UUID?
  public var plannedAt: Double?
  public var helpingHome: UInt64?
  public var invitationHome: UInt64?
  public var invitedBy: UInt64?
  public var cargo: MaterialAmount?
  public init() {}
  public var isValid: Bool {
    memory.isValid && (plan?.isValid ?? true) && (cargo.map { $0.isValid && $0.count <= 8 } ?? true)
      && (plannedAt.map { $0.isFinite && (0..<1_000_000_000).contains($0) } ?? true)
  }
}

public struct ReasoningSituation: Encodable, Sendable {
  public let actor: String
  public let kind: String
  public let problem: String
  public let facts: [String]
  public let memories: [String]
  public let availableActions: [String]
  public init(actor: String, kind: String, problem: String, facts: [String], memories: [String], availableActions: [String]) {
    self.actor = String(actor.prefix(80)); self.kind = String(kind.prefix(40)); self.problem = String(problem.prefix(220))
    self.facts = facts.prefix(14).map { String($0.prefix(220)) }
    self.memories = memories.prefix(8).map { String($0.prefix(180)) }
    self.availableActions = availableActions.prefix(16).map { String($0.prefix(120)) }
  }
}
