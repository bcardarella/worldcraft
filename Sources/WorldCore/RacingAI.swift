import Foundation
import simd
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RacingTactic: String, CaseIterable, Codable, Sendable {
  case push, steady, cautious, passLeft, passRight, yield
  public var description: String {
    switch self {
    case .push: "Use the available grip and clear road to close the gap; still brake for corners"
    case .steady: "Hold a predictable centre line at a sustainable competitive pace"
    case .cautious: "Leave extra braking distance and reduce speed through corners"
    case .passLeft: "Overtake a slower car using the clear left side of the road"
    case .passRight: "Overtake a slower car using the clear right side of the road"
    case .yield: "Ease off and leave room for a nearby car to pass safely"
    }
  }
}
public struct RacerObservation: Encodable, Sendable {
  public let id: UInt64
  public let circuit: UInt64
  public let layout: String
  public let temperament: String
  public let speed: Float
  public let cornerSeverity: Float
  public let gapAhead, speedAhead, gapBehind: Float
  public let leftClear, rightClear: Bool
  public let previousTactic: RacingTactic
  public init(id:UInt64,circuit:RaceCircuit,physics:VehiclePhysics,traffic:[VehicleTraffic],previous:RacingTactic) {
    self.id=id; self.circuit=circuit.id; layout=circuit.layout.name; speed=max(0,physics.speed)
    temperament=["Patient, smooth and consistent","Ambitious; take clean passing opportunities","Careful under pressure, confident on straights"][Int(id%3)]
    previousTactic=previous
    let progress=circuit.progress(at:physics.position), direction=circuit.tangent(at:progress)
    cornerSeverity=1-simd_dot(direction,circuit.tangent(at:progress+max(12,speed*1.3)))
    var ahead:Float=200, behind:Float=200, aheadSpeed:Float=48, left=true, right=true
    for other in traffic where other.id != id && abs(other.position.y-physics.position.y)<4 {
      let relative=other.position-physics.position, forward=simd_dot(relative,direction)
      let lateral=simd_dot(relative,SIMD3<Float>(-direction.z,0,direction.x))
      if abs(lateral)<2.8 && forward>0 && forward<ahead { ahead=forward; aheadSpeed=simd_length(other.velocity) }
      if abs(lateral)<5 && forward<0 { behind=min(behind,-forward) }
      if forward > -8 && forward < max(16,speed) {
        if lateral<0 && lateral > -7 { left=false }
        if lateral>=0 && lateral<7 { right=false }
      }
    }
    gapAhead=ahead; speedAhead=aheadSpeed; gapBehind=behind; leftClear=left; rightClear=right
  }
  public var options: [String:String] {
    let permitted=RacingTactic.allCases.filter { tactic in
      switch tactic {
      case .passLeft: leftClear && gapAhead<70 && cornerSeverity<0.8
      case .passRight: rightClear && gapAhead<70 && cornerSeverity<0.8
      case .push: gapAhead>12
      default: true
      }
    }
    return Dictionary(uniqueKeysWithValues:permitted.map { ($0.rawValue,$0.description) })
  }
}
public struct JevRacingRequest: Encodable, Sendable {
  public struct Question: Encodable, Sendable {
    let type = "choice"
    let instructions: String
    let criteria: [String:String]
  }
  public let model = "jev-latest"
  public let state: [String:RacerObservation]
  public let questions: [String:Question]
  public init(observations:[RacerObservation]) {
    let batch=observations.prefix(6)
    state=Dictionary(batch.map { (String($0.id),$0) },uniquingKeysWith:{first,_ in first})
    questions=Dictionary(batch.map { observation in
      ("racer_\(observation.id)",Question(instructions:"For the racer in state['\(observation.id)'], choose the best available racing tactic for the next few seconds. Use their temperament, speed, upcoming corner severity, gaps and clear passing lanes. Aim for a quick clean lap. Commit to an ongoing safe overtake; yield when crowded. Never intentionally hit another car. Distances and speeds are in half-metre blocks and blocks per second. A local driver handles every steering and braking update and vetoes unsafe moves.",criteria:observation.options))
    },uniquingKeysWith:{first,_ in first})
  }
}

/// Bounded, actor-isolated network work. Responses are proposals, never steering
/// commands. The render frame continues using the last safe decision.
public actor RacingDecisionService {
  private let client: JevNPCClient?
  private var budget=NPCRequestBudget()
  public init(apiKey:String?, session:URLSession = .shared) { client=apiKey.map { JevNPCClient(apiKey:$0,session:session) } }
  public func decide(_ observations:[RacerObservation],time:Double) async -> [UInt64:RacingTactic] {
    guard let client,!observations.isEmpty,budget.begin(at:time) else { return [:] }
    let start=Date()
    do {
      let request=JevRacingRequest(observations:observations)
      let result=try await client.decide(request)
      try Task.checkCancellation()
      var accepted:[UInt64:RacingTactic]=[:]
      for o in observations.prefix(6) {
        guard let answer=result.answers["racer_\(o.id)"], answer.accepts(options:Set(o.options.keys)),
          let tactic=RacingTactic(rawValue:answer.choice) else { continue }
        accepted[o.id]=tactic
      }
      budget.complete(at:time+Date().timeIntervalSince(start))
      print("WORLDCRAFT_RACING model=\(result.model) latency_ms=\(Int(Date().timeIntervalSince(start)*1000)) accepted=\(accepted.count) rejected=\(min(6,observations.count)-accepted.count)")
      return accepted
    } catch {
      let retry:Double?
      if case JevServiceError.http(_,let delay)=error { retry=delay } else { retry=nil }
      budget.fail(at:time+Date().timeIntervalSince(start),retryAfter:retry)
      return [:]
    }
  }
}

public struct RaceDriver: Sendable {
  public private(set) var lane:Float=0
  private var stuck:Float=0
  private var reversing:Float=0
  private var recoveryLane:Float=0
  private var recoveryTime:Float=0
  public init() {}
  public mutating func controls(physics:VehiclePhysics,circuit:RaceCircuit,tactic:RacingTactic,
    observation:RacerObservation,seconds:Float) -> (throttle:Float,steering:Float) {
    let dt=min(0.05,max(0,seconds)), progress=circuit.progress(at:physics.position)
    recoveryTime=max(0,recoveryTime-dt)
    // A parked car is a local navigation problem. Jev still chooses racing
    // tactics, but lack of a passing decision cannot deadlock the motor.
    if observation.speedAhead<2,observation.gapAhead<max(28,abs(physics.speed)*1.5),
      recoveryTime==0,observation.cornerSeverity<0.65 {
      if observation.leftClear { recoveryLane = -3.8; recoveryTime=3 }
      else if observation.rightClear { recoveryLane = 3.8; recoveryTime=3 }
    }
    var desiredLane:Float = tactic == .passLeft && observation.leftClear ? -3.2
      : tactic == .passRight && observation.rightClear ? 3.2 : tactic == .yield && observation.rightClear ? 3.2 : 0
    if recoveryTime>0 && desiredLane==0 { desiredLane=recoveryLane }
    if abs(circuit.laneDistance(x:physics.position.x,z:physics.position.z))>8 { desiredLane=0 }
    lane += (desiredLane-lane)*min(1,dt*1.4)
    let lookahead=max(7,abs(physics.speed)*0.42), target=circuit.point(at:progress+lookahead,lane:lane)
    let d=target-physics.position, wanted=atan2(-d.x,-d.z)
    let angle=atan2(sin(wanted-physics.heading),cos(wanted-physics.heading))
    let steer=physics.steeringInput(wheelAngle:-atan2(2*physics.kind.wheelbase*sin(angle),max(4,simd_length(d))))
    var speed:Float = tactic == .push ? 43 : tactic == .cautious ? 25 : tactic == .yield ? 21:36
    // Brake in advance using the tightest bend in the stopping horizon.
    for ahead:Float in [8,20,40,65] {
      let a=circuit.tangent(at:progress+ahead), b=circuit.tangent(at:progress+ahead+8)
      let turn=acos(max(-1,min(1,simd_dot(a,b))))/8
      let cornerSpeed=sqrt(7/max(0.006,turn))
      speed=min(speed,sqrt(cornerSpeed*cornerSpeed+20*max(0,ahead-8)))
    }
    if observation.gapAhead<max(10,physics.speed*0.9) && abs(lane)<2.8 {
      speed=min(speed,max(0,observation.speedAhead+(observation.gapAhead-9)*0.8))
    }
    if abs(angle)>1 { speed=min(speed,8) }
    if abs(physics.speed)<0.5 && (speed>3 || observation.gapAhead<12) { stuck+=dt } else { stuck=0 }
    if stuck>2 { reversing=1.1; stuck=0 }
    if reversing>0 { reversing-=dt; return (-0.45,-steer) }
    return (max(-1,min(1,(speed-physics.speed)*0.22)),steer)
  }
}
