import Foundation
import WorldCore

/// One planner and one spending ledger for the entire application, shared by
/// villagers and wildlife. Payload preparation, budgeting and persistence share the simulation executor; no provider work executes in a RealityKit frame.
@SimulationActor final class DeliberationService {
  private var client: ReasoningPlanner?
  private var task: Task<Void, Never>?
  private var requestID: UUID?
  private var nextBudgetCheck: Double = 0
  private var budget: ReasoningBudget
  private let defaults: UserDefaults
  var hourlyLimit: Double = 0.05
  private(set) var status = "Reasoning ready when needed"
  private(set) var completed = 0
  var spent: Double { budget.spent(at: Date().timeIntervalSince1970) }
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let charges = defaults.data(forKey: "worldcraft.reasoningCharges").flatMap {
      try? JSONDecoder().decode([ReasoningCharge].self, from: $0)
    } ?? []
    budget = .init(charges: charges)
  }
  func configure(key: String?, enabled: Bool, hourlyLimit: Double) {
    suspend()
    nextBudgetCheck = 0
    client = enabled ? key.map { ReasoningPlanner(apiKey: $0) } : nil
    self.hourlyLimit = min(0.2, max(0, hourlyLimit))
    status = client == nil ? "Reasoning offline · Jev/local choices continue" : "Qwen3.5-Flash ready · $\(String(format: "%.2f", self.hourlyLimit))/hour cap"
  }
  @discardableResult func request(_ situation: ReasoningSituation, apply: @escaping @SimulationActor (AgencyPlan) -> Void) -> Bool {
    let now = Date().timeIntervalSince1970
    guard task == nil, let client, now >= budget.nextAllowed, now >= nextBudgetCheck, spent < hourlyLimit,
      let payload = try? ReasoningPlanner.payload(for: situation) else { return false }
    guard let id = budget.begin(at: now, reservation: ReasoningPlanner.maximumCost(payloadBytes: payload.count), hourlyLimit: hourlyLimit) else {
      nextBudgetCheck = now + 30
      if spent >= hourlyLimit * 0.9 { status = "Reasoning budget reserved · Jev continues" }
      return false
    }
    persist(); requestID = id
    status = "Planning for \(situation.actor)…"
    task = Task { [weak self] in
      do {
        let receipt = try await client.plan(payload: payload)
        guard let self, self.requestID == id, !Task.isCancelled else { return }
        self.budget.complete(id, actualCost: receipt.cost); self.persist()
        self.task = nil; self.requestID = nil; self.completed += 1
        self.status = "Qwen3.5-Flash · \(self.completed) plans · $\(String(format: "%.3f", self.spent)) this hour"
        apply(receipt.plan)
        print("WORLDCRAFT_REASONING model=\(ReasoningPlanner.model) input_tokens=\(receipt.inputTokens) output_tokens=\(receipt.outputTokens) hour_usd=\(String(format: "%.5f", self.spent)) cap_usd=\(self.hourlyLimit)")
      } catch {
        guard let self, self.requestID == id else { return }
        let service = error as? PlannerError
        var delay: Double?
        if case .http(let code, let retry) = service { delay = code == 401 || code == 403 ? 900 : retry }
        self.budget.fail(id, at: Date().timeIntervalSince1970, retryAfter: delay); self.persist()
        self.task = nil; self.requestID = nil
        self.status = "Jev continues · " + (service?.description ?? "Reasoning connection unavailable")
      }
    }
    return true
  }
  func suspend() {
    task?.cancel(); task = nil
    if let requestID { budget.fail(requestID, at: Date().timeIntervalSince1970); persist() }
    requestID = nil
  }
  private func persist() {
    if let data = try? JSONEncoder().encode(budget.charges) { defaults.set(data, forKey: "worldcraft.reasoningCharges") }
  }
}
