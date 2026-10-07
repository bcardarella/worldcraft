import Foundation
import XCTest
@testable import WorldCore

private final class RacingFixtureProtocol:URLProtocol,@unchecked Sendable {
  override class func canInit(with request:URLRequest)->Bool { true }
  override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
  override func startLoading() {
    var data=request.httpBody ?? Data()
    if data.isEmpty,let stream=request.httpBodyStream {
      stream.open(); defer { stream.close() }
      var buffer=[UInt8](repeating:0,count:4096)
      while stream.hasBytesAvailable {
        let count=stream.read(&buffer,maxLength:buffer.count)
        if count<=0 { break }; data.append(contentsOf:buffer.prefix(count))
      }
    }
    let payload=try! JSONSerialization.jsonObject(with:data) as! [String:Any]
    let questions=payload["questions"] as! [String:[String:Any]]
    XCTAssertLessThanOrEqual(questions.count,6)
    var answers:[String:Any]=[:]
    for (id,question) in questions {
      let options=question["criteria"] as! [String:String]
      let bad=request.value(forHTTPHeaderField:"Authorization") == "Bearer invalid-racer"
      let choice=bad ? "teleport":"cautious"
      let probabilities=options.mapValues { $0 == RacingTactic.cautious.description ? 1.0:0.0 }
      answers[id]=["type":"choice","choice":choice,"confidence":0.9,"probabilities":probabilities]
    }
    let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
    client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
    client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:["model":"jev-fixture","answers":answers]))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
final class RacingJevTests:XCTestCase {
  private func session()->URLSession {
    let config=URLSessionConfiguration.ephemeral; config.protocolClasses=[RacingFixtureProtocol.self]
    return URLSession(configuration:config)
  }
  private var observations:[RacerObservation] {
    let c=RaceCircuit(id:2,center:.zero)
    return (0..<10).map { .init(id:UInt64($0),circuit:c,physics:.init(position:c.point(at:Float($0)*20)),traffic:[],previous:.steady) }
  }
  func testJevSuppliesTypedTacticsWithBoundedBatchAndCadence() async {
    let session=session(); defer { session.invalidateAndCancel() }
    let service=RacingDecisionService(apiKey:"test-racer",session:session)
    let result=await service.decide(observations,time:0)
    XCTAssertEqual(result.count,6); XCTAssertTrue(result.values.allSatisfy { $0 == .cautious })
    let tooSoon=await service.decide(observations,time:0.1)
    XCTAssertTrue(tooSoon.isEmpty)
    let next=await service.decide(observations,time:4)
    XCTAssertEqual(next.count,6)
  }
  func testUnknownJevTacticCannotBecomeACarCommand() async {
    let session=session(); defer { session.invalidateAndCancel() }
    let result=await RacingDecisionService(apiKey:"invalid-racer",session:session).decide(observations,time:0)
    XCTAssertTrue(result.isEmpty)
  }
  func testDisabledJevLeavesLocalDriverAvailable() async {
    let result=await RacingDecisionService(apiKey:nil).decide(observations,time:0)
    XCTAssertTrue(result.isEmpty)
  }
}
