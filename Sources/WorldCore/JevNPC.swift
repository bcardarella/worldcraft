import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct NPCDecisionOption: Sendable, Equatable {
  public let activity: ResidentActivity
  public let partnerID: UInt64?
  public let description: String
  public let job: ResidentJob?
  public init(activity: ResidentActivity, partnerID: UInt64? = nil, job: ResidentJob? = nil, description: String) {
    self.activity = activity; self.partnerID = partnerID; self.job = job; self.description = description
  }
}

public struct NPCDecisionContext: Encodable, Sendable {
  public let name: String
  public let role: String
  public let responsibilities: String
  public let personality: String
  public let currentActivity: String
  public let currentSituation: String
  public let playerRelationship: String
  public let hunger: String
  public let tiredness: String
  public let socialNeed: String
  public let workFulfillment: String
  public let recentExperiences: [String]
  public let nearbyPeople: [String]
  public let longTermMemory: [String]
  public let longerPlan: String?

  public init(resident: ResidentState, neighbors: [ResidentState], arrived: Bool = true, pathBlocked: Bool = false, waitingForPassage: Bool = false) {
    name = resident.name; role = resident.roleName; responsibilities = resident.workDescription
    personality = resident.personality; currentActivity = resident.activity.rawValue
    currentSituation = waitingForPassage ? "Waiting my turn for a doorway or staircase. Let the current walker clear it; do not push through. I can keep my destination or choose a different activity if my needs are urgent." : pathBlocked ? "Cannot reach the current destination; choose another activity"
      : arrived ? "At the destination and engaged in the current activity" : "Still on the way to the current activity"
    playerRelationship = resident.record.playerTrust > 0.7 ? "familiar and trusted visitor"
      : resident.record.playerTrust < 0.3 ? "wary of this visitor" : "a visitor I am getting to know"
    func need(_ value: Float) -> String { value > 0.75 ? "urgent" : value > 0.45 ? "moderate" : "low" }
    hunger = need(resident.record.hunger); tiredness = need(resident.record.fatigue)
    socialNeed = need(resident.record.loneliness)
    workFulfillment = resident.record.workSatisfaction > 0.65 ? "satisfied with recent work" : "still has work they want to do"
    recentExperiences = resident.record.memories.suffix(5).map(\.event)
    longTermMemory = resident.record.agency?.memory.recall(time: max(0, resident.lastDecision)).map(\.detail) ?? []
    longerPlan = resident.record.agency?.plan.map {
      "\($0.summary) Priorities: \($0.priorities.map(\.rawValue).joined(separator: ", ")). Materials: \($0.materials.rawValue). Social approach: \($0.social.rawValue)."
    }
    nearbyPeople = neighbors.prefix(5).map { other in
      let relation = resident.record.relationships.first(where: { $0.otherID == other.id })?.description ?? "neighbor"
      let coworker = other.role == resident.role ? ", fellow \(other.roleName)" : ""
      return "\(other.name) [\(other.id)]: \(relation)\(coworker), \(other.activity.label.lowercased())"
    }
  }
}

public struct JevNPCRequest: Encodable, Sendable {
  public struct State: Encodable, Sendable {
    public let settlement: String
    public let surroundings: String
    public let timeOfDay: String
    public let residents: [String: NPCDecisionContext]
  }
  public struct Question: Encodable, Sendable {
    public let type = "choice"
    public let instructions: String
    public let criteria: [String: String]
  }
  public let model: String
  public let state: State
  public let questions: [String: Question]

  public init(model: String = "jev-latest", settlement: String, biome: String,
    dayFraction: Double, contexts: [UInt64: NPCDecisionContext],
    options: [UInt64: [String: NPCDecisionOption]]) {
    self.model = model
    let hour = dayFraction * 24
    let time = hour < 6 || hour >= 21 ? "night" : hour < 11 ? "morning" : hour < 17 ? "afternoon" : "evening"
    state = .init(settlement: settlement, surroundings: biome, timeOfDay: time,
      residents: Dictionary(uniqueKeysWithValues: contexts.map { (String($0.key), $0.value) }))
    var questions: [String: Question] = [:]
    for id in contexts.keys.sorted() {
      guard let choices = options[id], !choices.isEmpty else { continue }
      // TypeSafe does not pass question IDs to its model. Identify the exact
      // resident explicitly; each independent question uses the same state.
      questions["action_\(id)"] = .init(instructions:
        "For state.residents['\(id)'], which available activity would this person naturally choose next? Consider this person's needs, personality, responsibilities, recent experiences and relationships. Prefer finishing purposeful activities unless a need, blocked route, invitation or recent experience warrants a change. Avoid repeating a greeting immediately after talking to the player. Time of day is context, not a mandatory schedule. Each choice describes an available, executable activity. Choose one activity for this resident only.",
        criteria: choices.mapValues(\.description))
      questions["tone_\(id)"] = .init(instructions:
        "For state.residents['\(id)'], which conversational manner best fits their current personality, needs and recent experiences?",
        criteria: ["warm": "Friendly, welcoming and caring", "practical": "Focused on useful work and concrete plans",
          "playful": "Lighthearted, curious and cheerful", "reserved": "Quiet, thoughtful or wanting some space"])
    }
    self.questions = questions
  }
}

public struct JevNPCResponse: Decodable, Sendable {
  public struct Choice: Decodable, Sendable {
    public let type: String
    public let choice: String
    public let confidence: Double
    public let probabilities: [String: Double]
    public func accepts(options: Set<String>, minimumConfidence: Double = 0.35) -> Bool {
      guard type == "choice", options.contains(choice), confidence.isFinite,
        (minimumConfidence...1).contains(confidence), Set(probabilities.keys) == options,
        probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
        abs(probabilities.values.reduce(0, +) - 1) < 0.02,
        let selected = probabilities[choice], selected > 0,
        selected + 0.000_001 >= (probabilities.values.max() ?? 1) else { return false }
      return true
    }
  }
  public let model: String
  public let answers: [String: Choice]
  public let usage: [String: Int]?

  public func action(for id: UInt64, options: [String: NPCDecisionOption]) -> NPCDecisionOption? {
    guard let answer = answers["action_\(id)"], answer.accepts(options: Set(options.keys)) else { return nil }
    return options[answer.choice]
  }
  public func tone(for id: UInt64) -> ConversationTone {
    guard let answer = answers["tone_\(id)"],
      answer.accepts(options: Set(ConversationTone.allCases.map(\.rawValue))) else { return .warm }
    return ConversationTone(rawValue: answer.choice) ?? .warm
  }
}

public enum JevServiceError: Error, Sendable {
  case missingKey, invalidResponse, http(status: Int, retryAfter: Double?)
  public var description: String {
    switch self {
    case .missingKey: "Add a TypeSafe key in settings"
    case .invalidResponse: "Jev returned an invalid decision"
    case .http(let status, _): status == 401 || status == 403 ? "Check the TypeSafe key" : "Jev HTTP \(status)"
    }
  }
}

public actor JevNPCClient {
  private let apiKey: String
  private let session: URLSession
  public init(apiKey: String, session: URLSession = .shared) {
    self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    self.session = session
  }
  public func decide(_ payload: JevNPCRequest) async throws -> JevNPCResponse {
    try await send(payload)
  }
  public func decide(_ payload: JevAnimalRequest) async throws -> JevNPCResponse {
    try await send(payload)
  }
  public func decide(_ payload: JevRacingRequest) async throws -> JevNPCResponse { try await send(payload) }
  private func send<T: Encodable & Sendable>(_ payload: T) async throws -> JevNPCResponse {
    guard !apiKey.isEmpty else { throw JevServiceError.missingKey }
    try Task.checkCancellation()
    var request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 4
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(payload)
    let (data, response) = try await session.data(for: request)
    try Task.checkCancellation()
    guard let response = response as? HTTPURLResponse else { throw JevServiceError.invalidResponse }
    guard (200..<300).contains(response.statusCode) else {
      let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
      throw JevServiceError.http(status: response.statusCode, retryAfter: retry)
    }
    guard data.count <= 262_144 else { throw JevServiceError.invalidResponse }
    do { return try JSONDecoder().decode(JevNPCResponse.self, from: data) }
    catch { throw JevServiceError.invalidResponse }
  }
}

/// Network cadence is independent of simulation cadence. One bounded batch can
/// be in flight; retries never occupy the frame loop or grow a request queue.
public struct NPCRequestBudget: Sendable {
  public private(set) var nextAllowed: Double = 0
  public private(set) var failures = 0
  public private(set) var inFlight = false
  public init() {}
  public mutating func begin(at time: Double) -> Bool {
    guard time >= nextAllowed && !inFlight else { return false }
    inFlight = true; nextAllowed = time + 3
    return true
  }
  public mutating func complete(at time: Double) {
    inFlight = false; failures = 0; nextAllowed = max(nextAllowed, time + 0.1)
  }
  public mutating func fail(at time: Double, retryAfter: Double? = nil) {
    inFlight = false; failures = min(6, failures + 1)
    let serverDelay = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
    nextAllowed = time + min(300, max(serverDelay, min(60, pow(2, Double(failures)))))
  }
}
