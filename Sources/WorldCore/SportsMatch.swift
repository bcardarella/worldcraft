import Foundation
import simd

public struct SportPlayer:Sendable {
  public let id:Int,team:Int
  public var position:SIMD3<Float>
  public var heading:Float=0,gait:Float=0,action:Float=0
  mutating func move(to target:SIMD3<Float>,speed:Float,seconds:Float) {
    var d=target-position;d.y=0
    let length=simd_length(d);guard length>0.01 else {return}
    let travel=min(length,speed*seconds)
    position += d/length*travel;heading=atan2(-d.x,-d.z);gait += travel*1.6
  }
}
public struct SportBall:Sendable {
  public var position,velocity:SIMD3<Float>
  public var bounced=false
  public init(position:SIMD3<Float>,velocity:SIMD3<Float> = .zero) {self.position=position;self.velocity=velocity}
  public mutating func advance(_ dt:Float,floor:Float,radius:Float) {
    velocity.y -= 19.62*dt;position += velocity*dt
    if position.y<floor+radius {
      position.y=floor+radius;bounced=true
      velocity.y=abs(velocity.y)>2 ? abs(velocity.y)*0.35:0
      velocity.x *= exp(-dt*1.4);velocity.z *= exp(-dt*1.4)
    }
  }
}

/// A condensed three-inning exhibition. Scores only change when runners
/// actually complete the bases. Fielders chase/catch hits and throw to first;
/// fly catches and force-outs are adjudicated from the play, not a score timer.
public struct BaseballMatch:Sendable {
  public enum Phase:Sendable {case ready,pitch,hit,returnBall,betweenPlays,finished}
  public let field:SportsGround,floor:Float
  public private(set) var players:[SportPlayer]=[]
  public private(set) var ball:SportBall
  public private(set) var score=[0,0],inning=1,batting=1,outs=0,strikes=0
  public private(set) var phase:Phase = .ready
  public private(set) var message="Play ball"
  public private(set) var homeRuns=0,scoredRuns=0
  public private(set) var souvenirs:[SIMD3<Float>]=[]
  private var clock:Float=0,seed:UInt64
  private var runners:[Runner]=[]
  private var nextRunnerID=10,hitHomeRun=false,hitFair=true,ballSecured=false
  private var pitchChoice:Float=0
  private var pendingRuns=0
  private struct Runner:Sendable {var player:SportPlayer;var base:Int;var target:Int;var startBase:Int}
  public init(field:SportsGround,floor:Float,seed:UInt64) {
    self.field=field;self.floor=floor;self.seed=seed
    ball = .init(position:[field.homePlate.x,floor+2.5,field.homePlate.y])
    resetFielders()
  }
  private func point(_ x:Float,_ z:Float,_ y:Float=0)->SIMD3<Float> {[field.homePlate.x+x,floor+y,field.homePlate.y-z]}
  private func base(_ n:Int)->SIMD3<Float> {
    let b=field.basePath
    switch n%4 {case 1:return point(b,0);case 2:return point(b,b);case 3:return point(0,b);default:return point(0,0)}
  }
  private mutating func random()->Float {seed=seed &* 6364136223846793005 &+ 1442695040888963407;return Float(seed>>40)/Float(1<<24)}
  private mutating func resetFielders() {
    let b=field.basePath,m=field.pitchingDistance/sqrt(2)
    let sites:[SIMD3<Float>]=[point(m,m),point(-2,-3),point(b+2,2),point(b*0.88,b*0.92),point(2,b+2),point(b*0.35,b*0.95),point(b*2.1,b*0.55),point(b*1.8,b*1.8),point(b*0.55,b*2.1)]
    players=sites.enumerated().map {.init(id:$0.offset,team:1-batting,position:$0.element)}
  }
  public var actors:[SportPlayer] {
    var result=players+runners.map(\.player)
    if phase == .ready || phase == .pitch {result.append(.init(id:999,team:batting,position:point(-1.4,0),heading:-.pi/4,action:phase == .pitch ? 1:0))}
    return result
  }
  public var label:String {"\(score[0]) – \(score[1]) · \(phase == .finished ? "FINAL":"Inning \(inning) · \(batting == 1 ? "Top":"Bottom") · \(outs) out · \(strikes) strike")\n\(message)"}
  public mutating func takeSouvenirs()->[SIMD3<Float>] {defer{souvenirs=[]};return souvenirs}
  public mutating func advance(seconds:Float) {
    guard seconds.isFinite,seconds>0,phase != .finished else {return}
    let steps=max(1,Int(ceil(min(0.25,seconds)*60))),dt=min(0.25,seconds)/Float(steps)
    for _ in 0..<steps {step(dt)}
  }
  private mutating func step(_ dt:Float) {
    clock += dt
    switch phase {
    case .ready:
      if clock>2 {
        let start=players[0].position+[0,2.7,0],end=point(0,0,2)
        ball = .init(position:start,velocity:(end-start)/0.75+[0,7.3575,0])
        pitchChoice=random();clock=0;phase = .pitch;message="Pitch"
      }
    case .pitch:
      ball.advance(dt,floor:floor,radius:0.074)
      if clock>=0.75 {
        if pitchChoice<0.55 {strikes+=1;message="Strike \(strikes)";if strikes>=3 {outs+=1;strikes=0;message="Strikeout"};finishPlay()}
        else {
          let angle:Float=(random()*1.30+0.135),speed:Float=24+random()*56
          let loft:Float=random()<0.55 ? 3+random()*10:18+random()*30
          hitFair=random()>0.10;hitHomeRun=false;ballSecured=false;pendingRuns=0
          ball = .init(position:point(0,0,2),velocity:[cos(angle)*speed,loft,(hitFair ? -1:1)*sin(angle)*speed])
          for i in runners.indices {runners[i].startBase=runners[i].base;runners[i].target=min(4,runners[i].base+1)}
          runners.append(.init(player:.init(id:nextRunnerID,team:batting,position:base(0)),base:0,target:1,startBase:0));nextRunnerID+=1
          phase = .hit;clock=0;message="Ball in play"
        }
      }
    case .hit:
      let before=ball.position
      ball.advance(dt,floor:floor,radius:0.074)
      let u=ball.position.x-field.homePlate.x,v=field.homePlate.y-ball.position.z
      let r=sqrt(u*u+v*v),fence=field.outfieldRadius(u:u,v:v)
      if !hitFair && clock>1.5 {
        runners.removeAll {$0.startBase==0}
        for i in runners.indices {runners[i].base=runners[i].startBase;runners[i].target=runners[i].base;runners[i].player.position=base(runners[i].base)}
        strikes=min(2,strikes+1);message="Foul ball";finishPlay();return
      }
      if hitFair && !hitHomeRun && r>fence && u>=0 && v>=0 {
        if !ball.bounced && ball.position.y>floor+4 {
          hitHomeRun=true;homeRuns+=1;message="HOME RUN!"
          for i in runners.indices {runners[i].target=4}
        } else {
          // A grounded ball at the fence stays in play; no phantom home run.
          ball.position=before;ball.velocity.x *= -0.30;ball.velocity.z *= -0.30
        }
      }
      if !hitHomeRun {
        let fielder=players.indices.dropFirst(2).min {simd_distance_squared(players[$0].position,ball.position)<simd_distance_squared(players[$1].position,ball.position)} ?? 2
        players[fielder].move(to:ball.position,speed:16,seconds:dt)
        if clock>0.35 && ball.position.y<floor+3.5 && simd_distance(SIMD2(players[fielder].position.x,players[fielder].position.z),SIMD2(ball.position.x,ball.position.z))<1.7 {
          if !ball.bounced {
            outs+=1;message="Caught out";runners.removeAll {$0.startBase==0}
            for i in runners.indices {runners[i].base=runners[i].startBase;runners[i].target=runners[i].base;runners[i].player.position=base(runners[i].base)}
            finishPlay();return
          }
          let delta=base(1)+[0,2,0]-ball.position
          let duration=max(0.3,simd_length(delta)/45)
          ball.velocity=delta/duration+[0,9.81*duration,0]
          ballSecured=true;clock=0;phase = .returnBall
        }
      } else if ball.position.y<=floor+0.08 && !ballSecured {
        souvenirs.append(ball.position);if souvenirs.count>8 {souvenirs.removeFirst()};ballSecured=true
      }
      moveRunners(dt)
      if hitHomeRun && runners.isEmpty && ballSecured {strikes=0;finishPlay()}
      else if clock>24 {strikes=0;message="Base hit";finishPlay()}
    case .returnBall:
      ball.advance(dt,floor:floor,radius:0.074);moveRunners(dt)
      if simd_distance(ball.position,base(1)+[0,2,0])<2.5 || clock>4 {
        if let i=runners.firstIndex(where:{$0.startBase==0 && $0.base==0}) {runners.remove(at:i);outs+=1;message="Out at first";if outs>=3 {pendingRuns=0;runners=[]}}
        else {message="Safe at first"}
        strikes=0;finishPlay()
      }
    case .betweenPlays:
      moveRunners(dt)
      guard clock>2.5,runners.allSatisfy({$0.base >= $0.target}) else {return}
      if outs>=3 {
        runners=[];outs=0;strikes=0
        if batting==0 {inning+=1};batting=1-batting
        if inning>3 {phase = .finished;message="Three-inning exhibition complete";return}
      }
      resetFielders();ball = .init(position:players[0].position+[0,2.7,0]);phase = .ready;clock=0
    case .finished:break
    }
  }
  private mutating func awardRuns() {score[batting]+=pendingRuns;scoredRuns+=pendingRuns;pendingRuns=0}
  private mutating func finishPlay() {
    // Ground-ball runs wait until the force play is resolved. A third out
    // before the batter reaches first erases runs from that same play.
    awardRuns()
    if outs>=3 {runners=[]}
    phase = .betweenPlays;clock=0
  }
  private mutating func moveRunners(_ dt:Float) {
    for i in runners.indices where runners[i].base<runners[i].target {
      let target=base(runners[i].base+1)
      runners[i].player.move(to:target,speed:12,seconds:dt)
      if simd_distance(runners[i].player.position,target)<0.12 {
        runners[i].base+=1
      }
    }
    // A runner reaching home during an uncaught fly waits for adjudication.
    if hitFair && (hitHomeRun || ball.bounced) {
      let runs=runners.filter {$0.base>=4}.count
      pendingRuns+=runs
      if hitHomeRun || phase == .betweenPlays {awardRuns()}
      runners.removeAll {$0.base>=4}
    }
  }
}

/// Full-ball goal-line crossing, including posts and crossbar. It is shared by
/// the match and tests; time/possession alone can never increment the scoreboard.
public enum SoccerRules {
  public static func goal(from:SIMD3<Float>,to:SIMD3<Float>,halfLength:Float,floor:Float,radius:Float=0.22)->Int? {
    for sign:Float in [-1,1] {
      let plane=sign*(halfLength+radius)
      guard from.z*sign<=abs(plane),to.z*sign>abs(plane) else {continue}
      let t=(plane-from.z)/(to.z-from.z),p=from+(to-from)*t
      if abs(p.x)+radius<WorldScale.blocks(7.32/2) && p.y+radius<floor+WorldScale.blocks(2.44) && p.y-radius>=floor-0.01 {return sign>0 ? 0:1}
    }
    return nil
  }
}
public struct SoccerMatch:Sendable {
  public let field:SportsGround,floor:Float
  public private(set) var players:[SportPlayer]=[]
  public private(set) var ball:SportBall
  public private(set) var score=[0,0],goals=0
  public private(set) var elapsed:Float=0
  public private(set) var message="Kick-off"
  private var kickCooldown:Float=0,restart:Float=0
  private var seed:UInt64
  private var lastTouch=0
  public init(field:SportsGround,floor:Float,seed:UInt64) {
    self.field=field;self.floor=floor;self.seed=seed
    ball = .init(position:[field.center.x,floor+0.22,field.center.y])
    for team in 0..<2 {for slot in 0..<11 {
      let sign:Float=team==0 ? 1:-1
      let x:Float=slot==0 ? 0:Float((slot-1)%4-2)*field.pitchHalfSize.x*0.42+field.pitchHalfSize.x*0.20
      let z:Float=slot==0 ? -field.pitchHalfSize.y+2:Float((slot-1)/4)*field.pitchHalfSize.y*0.28-field.pitchHalfSize.y*0.65
      players.append(.init(id:team*11+slot,team:team,position:[field.center.x+x,floor,field.center.y+z*sign]))
    }}
  }
  public var label:String {"\(score[0]) – \(score[1]) · \(Int(elapsed)/60):\(String(format:"%02d",Int(elapsed)%60))\(elapsed>=600 ? " · FINAL":"")\n\(message)"}
  public mutating func advance(seconds:Float) {
    guard seconds.isFinite,seconds>0,elapsed<600 else {return}
    let n=max(1,Int(ceil(min(0.25,seconds)*60))),dt=min(0.25,seconds)/Float(n)
    for _ in 0..<n {step(dt)}
  }
  private mutating func step(_ dt:Float) {
    elapsed+=dt;kickCooldown=max(0,kickCooldown-dt)
    if restart>0 {restart-=dt;return}
    let old=ball.position;ball.advance(dt,floor:floor,radius:0.22)
    let origin=SIMD3<Float>(field.center.x,0,field.center.y)
    if let team=SoccerRules.goal(from:old-origin,to:ball.position-origin,halfLength:field.pitchHalfSize.y,floor:floor) {
      score[team]+=1;goals+=1;message="GOAL · \(team==0 ? "Home":"Away")";restart=3
      ball = .init(position:origin+[0,floor+0.22,0]);lastTouch=1-team;kickCooldown=0.5;return
    }
    let relative=ball.position-origin
    if abs(relative.x)>field.pitchHalfSize.x+0.22 || abs(relative.z)>field.pitchHalfSize.y+0.22 {
      ball.position=origin+[min(field.pitchHalfSize.x,max(-field.pitchHalfSize.x,relative.x)),floor+0.22,min(field.pitchHalfSize.y-2,max(-field.pitchHalfSize.y+2,relative.z))]
      ball.velocity = .zero;message="Restart · \(lastTouch==0 ? "Away":"Home")";restart=1;kickCooldown=0;lastTouch=1-lastTouch
    }
    for team in 0..<2 {
      let members=players.indices.filter {players[$0].team==team}
      let chaser=members.dropFirst().min {simd_distance_squared(players[$0].position,ball.position)<simd_distance_squared(players[$1].position,ball.position)}!
      let sign:Float=team==0 ? 1:-1
      for i in members {
        let slot=i%11
        var target=players[i].position
        if slot==0 {target=origin+[max(-6,min(6,relative.x*0.4)),floor,(-field.pitchHalfSize.y+2)*sign]}
        else if i==chaser {target=ball.position+ball.velocity*0.16;target.y=floor}
        else {
          let x=Float((slot-1)%4-2)*field.pitchHalfSize.x*0.42+field.pitchHalfSize.x*0.20
          let z=(Float((slot-1)/4)*field.pitchHalfSize.y*0.32-field.pitchHalfSize.y*0.56)*sign
          target=origin+[max(-field.pitchHalfSize.x+3,min(field.pitchHalfSize.x-3,x+relative.x*0.22)),floor,max(-field.pitchHalfSize.y+4,min(field.pitchHalfSize.y-4,z+relative.z*0.52))]
        }
        // A small deterministic separation steers teammates out of each other's feet.
        for j in players.indices where j != i {
          let d=players[i].position-players[j].position,len=simd_length(d)
          if len<1.5 && len>0.001 {target += d/len*(1.5-len)*2}
        }
        players[i].move(to:target,speed:slot==0 ? 10:12,seconds:dt)
        players[i].action=max(0,players[i].action-dt*3)
        if kickCooldown==0 && ball.position.y<floor+(slot==0 ? 4:1.6) && simd_distance(ball.position,players[i].position+[0,0.5,0])<1.7 {
          seed=seed &* 6364136223846793005 &+ 1;let r=Float(seed>>40)/Float(1<<24)
          let nearGoal=(field.pitchHalfSize.y-relative.z*sign)<50
          var target=origin+[Float(r-0.5)*(nearGoal ? 10:field.pitchHalfSize.x),floor+0.4,sign*(field.pitchHalfSize.y+5)]
          if !nearGoal,let teammate=members.filter({$0 != i && $0%11 != 0 && (players[$0].position.z-players[i].position.z)*sign>3}).min(by:{simd_distance_squared(players[$0].position,target)<simd_distance_squared(players[$1].position,target)}) {target=players[teammate].position}
          let direction=simd_normalize(SIMD3<Float>(target.x-ball.position.x,0,target.z-ball.position.z))
          ball.velocity=direction*(nearGoal ? 37:27)+[0,nearGoal ? 4:2,0]
          kickCooldown=0.4;lastTouch=team;players[i].action=1;message=nearGoal ? "Shot":"Pass"
        }
      }
    }
  }
}

public struct BaseballThrow:Sendable {
  public private(set) var charge:Float=0
  public var strength:Float {min(1,charge/1.25)}
  public var accuracy:Float {max(0.2,1-abs(strength-0.78)*1.1-max(0,charge-1.7)*0.4)}
  public init() {}
  public mutating func hold(seconds:Float) {if seconds.isFinite {charge=min(3,charge+min(0.05,max(0,seconds)))}}
  public mutating func reset() {charge=0}
  public func velocity(direction:SIMD3<Float>,sequence:Int)->SIMD3<Float> {
    let spread=(1-accuracy)*0.1,phase=Float(sequence)*2.399963
    let aim=simd_normalize(direction+[cos(phase)*spread,sin(phase)*spread,0])
    return aim*WorldScale.blocks(7+strength*25)
  }
}

public enum AthleteSculpture {
  public static func make(team:Int,baseball:Bool,batting:Bool=false)->ActorSculpture {
    let jersey:SIMD3<Float>=team==0 ? [0.08,0.30,0.85]:[0.88,0.15,0.08]
    let colors:[SIMD3<Float>]=[[0.76,0.51,0.34],jersey,baseball ? [0.90,0.90,0.84]:jersey*0.65,
      [0.13,0.09,0.065],[0.94,0.93,0.87],[0.07,0.07,0.08],[0.55,0.29,0.11]] + Array(repeating:jersey,count:9)
    var body=ActorPart(.body),head=ActorPart(.head,at:[0,1.48,0]),eyes=ActorPart(.eyes,at:[0,0.035,-0.15])
    body.box([0.38,0.47,0.25],[0,1.08,0],1);body.box([0.34,0.22,0.24],[0,0.76,0],2)
    body.box([0.13,0.12,0.14],[0,1.36,0],0)
    for x:Float in [-0.035,0.035] {body.box([0.021,0.11,0.015],[x,1.11,0.132],4)}
    head.box([0.27,0.28,0.28],.zero,0);head.box([0.29,0.065,0.28],[0,0.145,0.015],baseball ? 1:3)
    if baseball {head.box([0.28,0.023,0.16],[0,0.115,-0.19],1)}
    for x:Float in [-0.065,0.065] {eyes.box([0.025,0.035,0.014],[x,0,0],5)}
    var parts=[body,head,eyes]
    for i in 0..<4 {
      let arm=i<2,side:Float=i%2==0 ? -1:1
      var limb=ActorPart([ActorJoint.limb0,.limb1,.limb2,.limb3][i],at:[side*(arm ? 0.25:0.10),arm ? 1.25:0.75,0])
      limb.box([arm ? 0.14:0.16,arm ? 0.25:0.36,0.18],[0,arm ? -0.12:-0.18,0],arm ? 1:2)
      limb.box([arm ? 0.12:0.14,arm ? 0.27:0.31,0.16],[0,arm ? -0.37:-0.50,0],arm ? 0:baseball ? 2:4)
      limb.box([arm ? 0.13:0.17,0.09,arm ? 0.14:0.27],[0,arm ? -0.52:-0.705,arm ? 0:-0.045],arm ? 0:5)
      if baseball && !batting && i==0 {limb.box([0.20,0.16,0.10],[0,-0.53,-0.09],6)}
      parts.append(limb)
    }
    var prop=ActorPart(.prop,at:[0,-0.52,0])
    if batting {prop.box([0.035,0.30,0.035],[0,0.13,0],6);prop.box([0.075,0.55,0.075],[0,0.52,0],6)}
    parts.append(prop)
    return .init(name:"Athlete",key:"athlete-\(team)-\(baseball)-\(batting)",colors:colors,parts:parts)
  }
}
