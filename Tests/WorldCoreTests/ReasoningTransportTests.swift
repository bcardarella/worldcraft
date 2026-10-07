import Foundation
import XCTest
@testable import WorldCore

private final class PlannerFixtureProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
    XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.timeoutInterval, 18)
    let key = request.value(forHTTPHeaderField: "Authorization")
    if key == "Bearer fixture-cancel" { return }
    let limited = key == "Bearer fixture-limit"
    let plan = #"{"priorities":["safety","recruitHelp","gather","repair"],"materials":"suitableSubstitutes","social":"askFriends","summary":"Ask trusted neighbors for help and gather suitable supplies."}"#
    let response: [String: Any] = ["choices": [["message": ["content": plan], "finish_reason": "stop"]],
      "usage": ["prompt_tokens": 350, "completion_tokens": 600, "cost": 0.00018]]
    let data = limited ? Data("rate limited".utf8) : try! JSONSerialization.data(withJSONObject: response)
    let http = HTTPURLResponse(url: request.url!, statusCode: limited ? 429 : 200,
      httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Retry-After": "120"])!
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
  }
}

final class ReasoningTransportTests: XCTestCase {
  private var context: ReasoningSituation {
    .init(actor: "Rowan", kind: "villager", problem: "Home damaged", facts: ["Two missing bricks; empty stockpile"],
      memories: ["My neighbor helped me before"], availableActions: ["Ask neighbor for help", "Gather stone"])
  }
  private func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PlannerFixtureProtocol.self]
    return URLSession(configuration: config)
  }
  func testPayloadEnablesReasoningAndStrictPlansWithProviderPriceCeilings() throws {
    let data = try ReasoningPlanner.payload(for: context)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(body["model"] as? String, "qwen/qwen3.5-flash-02-23")
    XCTAssertEqual(body["max_tokens"] as? Int, 2_048)
    let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
    XCTAssertEqual(reasoning["enabled"] as? Bool, true); XCTAssertEqual(reasoning["exclude"] as? Bool, true)
    let provider = try XCTUnwrap(body["provider"] as? [String: Any])
    XCTAssertEqual(provider["require_parameters"] as? Bool, true)
    let prices = try XCTUnwrap(provider["max_price"] as? [String: Double])
    XCTAssertEqual(prices["prompt"], ReasoningPlanner.inputPriceCeiling)
    XCTAssertEqual(prices["completion"], ReasoningPlanner.outputPriceCeiling)
    XCTAssertEqual(prices["request"], 0)
    let format = try XCTUnwrap(body["response_format"] as? [String: Any])
    XCTAssertEqual(format["type"] as? String, "json_schema")
    XCTAssertGreaterThan(ReasoningPlanner.maximumCost(payloadBytes: data.count), 0.0008)
    XCTAssertLessThan(ReasoningPlanner.maximumCost(payloadBytes: 24_000), 0.004)
  }
  func testAuthenticatedReasoningTransportReturnsTypedPlanAndBillableUsage() async throws {
    let session = session(); defer { session.invalidateAndCancel() }
    let response = try await ReasoningPlanner(apiKey: "fixture-success", session: session).plan(payload: ReasoningPlanner.payload(for: context))
    XCTAssertEqual(response.plan.priorities, [.safety, .recruitHelp, .gather, .repair])
    XCTAssertEqual(response.plan.materials, .suitableSubstitutes)
    XCTAssertEqual(response.outputTokens, 600); XCTAssertEqual(response.cost, 0.00018)
  }
  func testInvalidTruncatedAndInventedPlansAreRejected() throws {
    let invalid = [
      #"{"priorities":["teleportSupplies"],"materials":"exact","social":"independent","summary":"Done"}"#,
      #"{"priorities":["repair","repair"],"materials":"exact","social":"independent","summary":"Done"}"#,
      #"{"priorities":[],"materials":"exact","social":"independent","summary":"Done"}"#,
      "```json\n{}\n```"
    ]
    for plan in invalid {
      let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": plan], "finish_reason": "stop"]]])
      XCTAssertThrowsError(try ReasoningPlanner.decode(response))
    }
    let plan = String(decoding: try JSONEncoder().encode(AgencyPlan(priorities: [.repair], summary: "Gather then repair")), as: UTF8.self)
    let truncated = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": plan], "finish_reason": "length"]]])
    XCTAssertThrowsError(try ReasoningPlanner.decode(truncated))
    XCTAssertThrowsError(try ReasoningPlanner.decode(Data(repeating: 32, count: 131_073)))
  }
  func testRateLimitRetainsRetryDelayAndReservedCost() async throws {
    let session = session(); defer { session.invalidateAndCancel() }
    var budget = ReasoningBudget()
    let id = try XCTUnwrap(budget.begin(at: 100, reservation: 0.003))
    do {
      _ = try await ReasoningPlanner(apiKey: "fixture-limit", session: session).plan(payload: ReasoningPlanner.payload(for: context))
      XCTFail("Expected rate limit")
    } catch PlannerError.http(let status, let delay) {
      XCTAssertEqual(status, 429); XCTAssertEqual(delay, 120)
      budget.fail(id, at: 101, retryAfter: delay)
      XCTAssertNil(budget.begin(at: 220, reservation: 0.001))
      XCTAssertEqual(budget.spent(at: 220), 0.003)
    }
  }
  func testCancellationAndMissingCredentialsDoNotProducePlans() async throws {
    let session = session(); defer { session.invalidateAndCancel() }
    let payload = try ReasoningPlanner.payload(for: context)
    let task = Task { try await ReasoningPlanner(apiKey: "fixture-cancel", session: session).plan(payload: payload) }
    await Task.yield(); task.cancel()
    do { _ = try await task.value; XCTFail("Expected cancellation") }
    catch is CancellationError { }
    catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
    do { _ = try await ReasoningPlanner(apiKey: "", session: session).plan(payload: payload); XCTFail("Missing key") }
    catch PlannerError.missingKey { }
  }
}
