import Foundation

public struct MountProfile: Sendable {
  private struct HeadSeat:Sendable { let top, forward, modelHeight:Float }
  // These sculptures are immutable. Resolve once rather than rebuilding a
  // dinosaur every frame while looking for something to ride.
  private static let headSeats:[DinosaurKind:HeadSeat] = Dictionary(uniqueKeysWithValues:
    [DinosaurKind.trex,.brachiosaurus,.spinosaurus].map { kind in
      let shape=DinosaurSculpture.make(.init(kind:kind,color:.pink,id:0,juvenile:false))
      let head=shape.parts.first {$0.joint == .head}!
      let top=head.boxes.map {$0.center.y+$0.size.y/2}.max() ?? 0
      return (kind,HeadSeat(top:head.pivot.y+top,forward:-head.pivot.z,modelHeight:shape.bounds.maximum.y))
    })
  public let radius, height, seatHeight, speed: Float
  public let seatForward:Float
  public let swims: Bool
  public let isColossal: Bool
  public init(radius:Float,height:Float,seatHeight:Float,speed:Float,swims:Bool,isColossal:Bool=false,seatForward:Float=0) {
    self.radius=radius; self.height=height; self.seatHeight=seatHeight; self.speed=speed
    self.swims=swims; self.isColossal=isColossal;self.seatForward=seatForward
  }
  public static func colossal(heightMetres:Float) -> Self {
    // Match the actual adult sculpture instead of guessing a torso height.
    let head=headSeats[.trex]!,scale=heightMetres/head.modelHeight
    return .init(radius:heightMetres*0.27,height:WorldScale.blocks(heightMetres)+1.4,
      seatHeight:WorldScale.blocks(head.top*scale)+1.4,speed:12,swims:false,isColossal:true,
      seatForward:WorldScale.blocks(head.forward*scale))
  }
  public static func animal(_ kind: AnimalKind, baby: Bool) -> Self? {
    guard !baby, !kind.small, kind != .hayHay else { return nil }
    let size = kind.clearance
    let seat: Float = kind == .giraffe ? 3.2 : kind == .elephant ? 4.1 : WorldScale.blocks(size.height*0.70)
    return .init(radius:WorldScale.blocks(size.radius),height:max(WorldScale.blocks(size.height),seat+2.6),
      seatHeight:seat+1.4,speed:kind == .horse || kind == .zebra ? 15 : kind == .elephant ? 7 : 10,swims:kind.canSwim)
  }
  public static func dinosaur(_ kind: DinosaurKind, baby: Bool, scale:Float=1) -> Self? {
    guard !baby else { return nil }
    let seat: Float = switch kind {
    case .trex: 5.1; case .velociraptor: 2.9; case .brachiosaurus: 8.4
    case .spinosaurus: 7.1; case .parasaurolophus: 4.8; default: 3.8
    }
    var eye=seat,forward:Float=0
    if let head=headSeats[kind] {
      eye=WorldScale.blocks(head.top*scale)+1.4
      forward=WorldScale.blocks(head.forward*scale)
    }
    return .init(radius:kind.clearance.radius*scale,height:max(kind.clearance.height*scale,eye+0.3),
      seatHeight:eye,speed:kind.speed*1.5,swims:kind.canSwim,seatForward:forward)
  }
}
public struct MountCandidate: Sendable {
  public let id: UInt64
  public let name: String
  public let position: SIMD3<Float>
  public let heading: Float
  public let profile: MountProfile
  public init(id: UInt64, name: String, position: SIMD3<Float>, heading: Float, profile: MountProfile) {
    self.id=id; self.name=name; self.position=position; self.heading=heading; self.profile=profile
  }
}
public struct MountedRide: Sendable {
  public let id: UInt64
  public let name: String
  public let profile: MountProfile
  public let boardedAt: SIMD3<Float>
  public var position: SIMD3<Float>
  public var heading: Float
  public private(set) var velocity = SIMD3<Float>.zero
  public private(set) var grounded = true
  private var groundClock: Float = 0
  private var giantFloor: Float?
  public var eye: SIMD3<Float> { position+[-sin(heading)*profile.seatForward,profile.seatHeight,-cos(heading)*profile.seatForward] }
  public init(_ candidate: MountCandidate, boardedAt: SIMD3<Float>) {
    id=candidate.id; name=candidate.name; profile=candidate.profile
    position=candidate.position; heading=candidate.heading; self.boardedAt=boardedAt
  }
  public func clear(at point: SIMD3<Float>, block: (BlockPosition)->Block) -> Bool {
    if profile.isColossal {
      // Boarding checks the rider's seat only. A giant pushes through buildings;
      // scanning its entire skyscraper-sized volume would stall the main actor.
      let seat=eye+(point-position)-[0,PlayerPhysics.eyeHeight,0]
      let player=PlayerPhysics(position:seat)
      return !player.collides(at:seat,block:block)
    }
    let low=BlockPosition(point+[-profile.radius,0.04,-profile.radius])
    let high=BlockPosition(point+[profile.radius,profile.height,profile.radius])
    for x in low.x...high.x { for z in low.z...high.z { for y in low.y...high.y {
      let value=block(.init(x,y,z))
      if value.isSolid || value == .lava || (!profile.swims && value == .water) { return false }
    } } }
    return true
  }
  public mutating func update(seconds: Float, movement: SIMD3<Float>, sprint: Bool, jump: Bool,
    block: (BlockPosition)->Block, occupied: (SIMD3<Float>)->Bool = { _ in false }) {
    guard !profile.isColossal else { return }
    guard seconds.isFinite else { return }
    let duration=min(0.05,max(0,seconds)); guard duration>0 else { return }
    var horizontal=SIMD3<Float>(movement.x,0,movement.z)
    let length=sqrt(horizontal.x*horizontal.x+horizontal.z*horizontal.z)
    if length>1 { horizontal /= length }
    let target=horizontal*profile.speed*(sprint ? 1.5 : 1)
    velocity.x += (target.x-velocity.x)*min(1,duration*10)
    velocity.z += (target.z-velocity.z)*min(1,duration*10)
    if length>0.1 {
      let desired=atan2(-horizontal.x,-horizontal.z)
      let angle=atan2(sin(desired-heading),cos(desired-heading))
      heading += min(duration*4,max(-duration*4,angle))
    }
    if jump && grounded { velocity.y=7; grounded=false }
    let steps=max(1,Int(ceil(duration*120))),dt=duration/Float(steps)
    for _ in 0..<steps {
      let swimming=profile.swims && block(.init(position+[0,0.6,0])) == .water
      if swimming { velocity.y = movement.y*4 }
      else if !grounded { velocity.y=max(-28,velocity.y-24*dt) }
      for axis in [0,2] {
        var next=position; next[axis] += velocity[axis]*dt
        if clear(at:next,block:block) && !occupied(next) { position=next }
        else if grounded {
          next.y=floor(position.y+0.05)+1
          if next.y-position.y <= 1.05 && clear(at:next,block:block) && !occupied(next) { position=next }
          else { velocity[axis]=0 }
        } else { velocity[axis]=0 }
      }
      var supported=false
      if velocity.y <= 0 && !swimming {
        for drop: Float in [0,1] {
          let y=floor(position.y+0.05)-drop
          guard position.y-y <= 1.05, block(.init([position.x,y-0.1,position.z])).isSolid else { continue }
          let next=SIMD3<Float>(position.x,y,position.z)
          if clear(at:next,block:block) && !occupied(next) { position=next; supported=true; break }
        }
      }
      if supported { velocity.y=0; grounded=true }
      else {
        grounded=false
        let next=position+[0,velocity.y*dt,0]
        if clear(at:next,block:block) && !occupied(next) { position=next }
        else { velocity.y=0 }
      }
    }
  }
  /// Five height samples at 4 Hz, independent of visible mesh availability.
  /// Trees and buildings are handled by the actor's bounded destruction work.
  public mutating func updateColossal(seconds:Float,movement:SIMD3<Float>,sprint:Bool,
    ground:(Float,Float)->ColossalGround) {
    guard profile.isColossal,seconds.isFinite else { return }
    let dt=min(0.05,max(0,seconds)); guard dt>0 else { return }
    var direction=SIMD3<Float>(movement.x,0,movement.z)
    let length=sqrt(direction.x*direction.x+direction.z*direction.z)
    direction /= max(1,length)
    let target=direction*profile.speed*(sprint ? 1.5:1)
    velocity += (target-velocity)*min(1,dt*4)
    if length>0.05 {
      let angle=atan2(-direction.x,-direction.z)-heading
      heading += min(dt*0.8,max(-dt*0.8,atan2(sin(angle),cos(angle))))
    }
    groundClock += dt
    let next=position+velocity*dt
    if giantFloor == nil || groundClock>=0.25 {
      groundClock=0
      var low=Float.infinity,high = -Float.infinity
      for d:SIMD2<Float> in [[0,0],[-1,-1],[1,-1],[-1,1],[1,1]] {
        let probe=ground(next.x+d.x*profile.radius,next.z+d.y*profile.radius)
        guard probe.walkable else { giantFloor=nil; velocity = .zero; return }
        low=min(low,probe.height); high=max(high,probe.height)
      }
      guard high-low<=profile.radius,abs(high-position.y)<=profile.radius else {
        giantFloor=nil; velocity = .zero; return
      }
      giantFloor=high
    }
    position=next
    position.y += ((giantFloor ?? position.y)-position.y)*min(1,dt*5)
    velocity.y=0; grounded=true
  }
  public func dismount(block: (BlockPosition)->Block, occupied: (SIMD3<Float>)->Bool = { _ in false }) -> SIMD3<Float>? {
    // Search at the animal's feet, never drop the player from a dinosaur's back.
    for radius in [profile.radius+1.1,profile.radius+2.4,profile.radius+4] {
      for i in 0..<12 {
        let angle=heading+Float(i) * .pi/6
        let offsets:[Float] = profile.isColossal ? [0]+(1...24).flatMap { [Float($0),-Float($0)] } : [0,1,-1,2,-2,3,-3]
        for dy in offsets {
          let p=SIMD3<Float>(position.x+cos(angle)*radius,floor(position.y)+dy+0.02,position.z+sin(angle)*radius)
          if VehiclePhysics.safeFooting(at:p,block:block) && !occupied(p) { return p }
        }
      }
    }
    return nil
  }
}
