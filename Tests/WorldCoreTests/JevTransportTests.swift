import Foundation
import XCTest
@testable import WorldCore

/// This protocol intercepts every request; tests never contact TypeSafe or use
/// an account key. Distinct fake credentials select independent fixtures.
private final class JevFixtureProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    XCTAssertEqual(request.timeoutInterval, 4)
    let key = request.value(forHTTPHeaderField: "Authorization")
    if key == "Bearer test-cancel" { return }
    var status = 200
    var headers = ["Content-Type": "application/json"]
    let data: Data
    switch key {
    case "Bearer test-rate-limit":
      status = 429; headers["Retry-After"] = "30"
      data = Data(#"{"error":"rate limit"}"#.utf8)
    case "Bearer test-invalid": data = Data("invalid JSON".utf8)
    default:
      XCTAssertEqual(key, "Bearer test-success")
      var body = request.httpBody ?? Data()
      if body.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
          let count = stream.read(&buffer, maxLength: buffer.count)
          guard count > 0 else { break }
          body.append(contentsOf: buffer.prefix(count))
        }
      }
      let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
      XCTAssertEqual(payload?["model"] as? String, "jev-latest")
      XCTAssertNotNil(payload?["state"])
      XCTAssertNotNil(payload?["questions"])
      data = Data(#"{"model":"jev-1.13.0","answers":{"action_1":{"type":"choice","choice":"eat","confidence":0.9,"probabilities":{"eat":0.95,"work":0.05}}},"usage":{"input_tokens":90,"output_tokens":10}}"#.utf8)
    }
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

final class JevTransportTests: XCTestCase {
  private func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [JevFixtureProtocol.self]
    return URLSession(configuration: config)
  }
  private var request: JevNPCRequest {
    .init(settlement: "Test village", biome: "Meadow", dayFraction: 0.4, contexts: [:], options: [:])
  }
  func testAuthenticatedRequestAndDocumentedChoiceResponse() async throws {
    let session = session(); defer { session.invalidateAndCancel() }
    let response = try await JevNPCClient(apiKey: " test-success \n", session: session).decide(request)
    XCTAssertEqual(response.model, "jev-1.13.0")
    XCTAssertEqual(response.usage?["input_tokens"], 90)
    XCTAssertEqual(response.action(for: 1, options: ["eat": .init(activity: .eat, description: "Eat"),
      "work": .init(activity: .work, description: "Work")])?.activity, .eat)
  }
  func testRateLimitPreservesRetryDelayWithoutDecodingErrorBody() async {
    let session = session(); defer { session.invalidateAndCancel() }
    do {
      _ = try await JevNPCClient(apiKey: "test-rate-limit", session: session).decide(request)
      XCTFail("Expected rate limit")
    } catch JevServiceError.http(let status, let retry) {
      XCTAssertEqual(status, 429); XCTAssertEqual(retry, 30)
    } catch { XCTFail("Unexpected error: \(error)") }
  }
  func testMalformedResponseBecomesLocalFallbackError() async {
    let session = session(); defer { session.invalidateAndCancel() }
    do {
      _ = try await JevNPCClient(apiKey: "test-invalid", session: session).decide(request)
      XCTFail("Expected invalid response")
    } catch JevServiceError.invalidResponse { }
    catch { XCTFail("Unexpected error: \(error)") }
  }
  func testCancellationStopsSuspendedRequest() async {
    let session = session(); defer { session.invalidateAndCancel() }
    let client = JevNPCClient(apiKey: "test-cancel", session: session)
    let request = request
    let task = Task { try await client.decide(request) }
    await Task.yield()
    task.cancel()
    do { _ = try await task.value; XCTFail("Expected cancellation") }
    catch is CancellationError { }
    catch let error as URLError { XCTAssertEqual(error.code, .cancelled) }
    catch { XCTFail("Unexpected error: \(error)") }
  }
}
