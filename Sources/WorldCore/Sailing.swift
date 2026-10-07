import Foundation
import simd

public enum BoatKind: Int, CaseIterable, Codable, Sendable {
  case dinghy, sloop, yacht, cutter, catamaran, motorboat, megaYacht, jetSki
  public var name: String { ["Sailing dinghy", "Coastal sloop", "Grand sailing yacht", "Classic cutter", "Cruising catamaran", "Motor launch", "Expedition mega yacht", "Jet ski"][rawValue] }
  public var isMotorized:Bool { self == .motorboat || self == .megaYacht || self == .jetSki }
  // Hull dimensions, draft and all force calculations are SI; positions are blocks.
  public var length: Float { [4.2,9,18,12,13,7,38,3.2][rawValue] }
  public var beam: Float { [1.65,3.1,5.2,3.7,6.4,2.5,8.2,1.15][rawValue] }
  public var draft: Float { [0.55,1.3,2.1,1.65,1.1,0.65,3.2,0.3][rawValue] }
  public var freeboard: Float { [0.32,0.65,1.15,0.8,1,0.65,2.2,0.3][rawValue] }
  public var mass: Float { [220,3_800,24_000,7_500,9_200,1_600,220_000,340][rawValue] }
  public var sailArea: Float { [9,48,190,88,90,0,0,0][rawValue] }
  public var mastHeight: Float { [5.2,11,20,14,15,0,0,0][rawValue] }
  public var engineSpeed:Float { self == .megaYacht ? 10 : self == .jetSki ? 22 : self == .motorboat ? 18 : self == .dinghy ? 1.25:1.9 }
  public var hullSpeed: Float { 1.34 * sqrt(length * 3.28084) * 0.514444 }
  public var helm: SIMD3<Float> {
    if self == .megaYacht {return [0,freeboard+7.3,-length*0.12]}
    if self == .jetSki {return [0,1.35,0.3]}
    if self == .motorboat {return [0.45,1.7,0.5]}
    return [0,freeboard+(self == .dinghy ? 0.60:1.25),length*0.31]
  }
}

public struct SailingControls: Sendable {
  public var rudder: Float
  public var sheet: Float
  /// Explicit harbour auxiliary: oars for the dinghy, a slow docking motor for yachts.
  public var auxiliary: Float
  public init(rudder: Float = 0, sheet: Float = 0, auxiliary: Float = 0) {
    self.rudder = rudder; self.sheet = sheet; self.auxiliary = auxiliary
  }
}

public struct BoatRecord: Codable, Sendable {
  public let id: UInt64
  public let marina: UInt64
  public var physics: SailingPhysics
  public init(id: UInt64, marina: UInt64, physics: SailingPhysics) {
    self.id=id; self.marina=marina; self.physics=physics
  }
  public var isValid: Bool { physics.isValid }
}

/// A displacement hull driven by apparent-wind lift/drag and water-relative
/// resistance. No forward "sailing throttle"; pointing into the wind luffs the
/// sail. Fixed substeps bound collision travel without replaying missed frames.
public struct SailingPhysics: Codable, Sendable {
  public var kind: BoatKind
  public var position: SIMD3<Float>
  public var heading: Float
  public private(set) var velocity = SIMD3<Float>.zero // metres/second
  public private(set) var yawRate: Float = 0
  public var anchored = true
  public var sailRaised = false
  public var automaticTrim = true
  public private(set) var sheetAngle: Float = 0.35
  public private(set) var boomAngle: Float = 0
  public private(set) var heel: Float = 0
  public private(set) var pitch: Float = 0
  public private(set) var luffing = false
  public private(set) var grounded = false
  public private(set) var windAngle: Float = 0
  public private(set) var windSpeed: Float = 0
  public init(kind: BoatKind, position: SIMD3<Float>, heading: Float) {
    self.kind=kind; self.position=position; self.heading=heading
  }
  public var isValid: Bool {
    (0..<3).allSatisfy { position[$0].isFinite && abs(position[$0]) < 100_000_000
      && velocity[$0].isFinite && abs(velocity[$0]) < 100 }
      && [heading,yawRate,sheetAngle,boomAngle,heel,pitch,windAngle,windSpeed].allSatisfy(\.isFinite)
      && (0...Float.pi/2).contains(sheetAngle) && abs(heel) < 1 && abs(pitch) < 1
  }
  public var speed: Float { simd_length(velocity) }
  public var forward: SIMD3<Float> { [-sin(heading),0,-cos(heading)] }
  public var right: SIMD3<Float> { [cos(heading),0,-sin(heading)] }
  public func worldPoint(_ metres: SIMD3<Float>) -> SIMD3<Float> {
    position + WorldScale.blocks(1) * (right * metres.x + [0,metres.y,0] - forward * metres.z)
  }
  /// Keep the viewer upright; hull heel and wave pitch never force headset roll.
  public var eye: SIMD3<Float> { worldPoint(kind.helm) }
  public var pointOfSail: String {
    let angle=abs(windAngle)*180 / .pi
    if anchored { return "Anchored" }
    if grounded { return "Shallow water / hull contact" }
    if kind.isMotorized {return "Under power"}
    if !sailRaised { return "Sails lowered" }
    if luffing { return "Sails luffing · bear away or trim" }
    return angle < 60 ? "Close hauled" : angle < 80 ? "Close reach" : angle < 110 ? "Beam reach" : angle < 155 ? "Broad reach" : "Running"
  }
  public mutating func moor() { anchored=true; sailRaised=false; velocity = .zero; yawRate=0 }

  public mutating func update(deltaTime: Float, controls: SailingControls,
    wind: SIMD3<Float>, current: SIMD3<Float>, water: WaterSample,
    navigable: (SIMD3<Float>, Float, BoatKind) -> Bool = { _,_,_ in true }) {
    guard deltaTime.isFinite, deltaTime > 0, isValid,
      (0..<3).allSatisfy({ wind[$0].isFinite && current[$0].isFinite }), water.height.isFinite else { return }
    let dt=min(deltaTime,0.05), steps=max(1,Int(ceil(dt*120))), h=dt/Float(steps)
    let rudder=controls.rudder.isFinite ? min(1,max(-1,controls.rudder)):0
    let auxiliary=controls.auxiliary.isFinite ? min(1,max(-1,controls.auxiliary)):0
    if controls.sheet.isFinite && abs(controls.sheet)>0.05 {
      automaticTrim=false
      sheetAngle=min(.pi/2,max(0.035,sheetAngle-controls.sheet*dt*0.8))
    }
    grounded=false
    for _ in 0..<steps {
      let f=forward,r=right, apparent=SIMD3(wind.x,0,wind.z)-velocity
      let aws=simd_length(apparent)
      windSpeed=aws
      windAngle=atan2(simd_dot(-apparent,r),simd_dot(-apparent,f))
      let beta=abs(windAngle)
      // A small angle of attack generates lift; easing to the apparent wind
      // luffs, oversheeting stalls. Downwind the sail operates on drag.
      if automaticTrim { sheetAngle=max(0.035,min(.pi/2,beta-0.28)) }
      let alpha=max(0,beta-sheetAngle)
      let noGo=smoothstep(0.62,0.82,beta)
      let lift=sin(2*min(.pi/2,alpha))*1.25
      let drag=0.018+1.35*pow(sin(min(.pi/2,alpha)),2)
      luffing=sailRaised && (beta<0.70 || alpha<0.055 || aws<0.3)
      var force=SIMD3<Float>.zero
      if sailRaised && !kind.isMotorized && aws>0.01 {
        let air=apparent/aws
        var liftDirection=SIMD3<Float>(-air.z,0,air.x)
        if simd_dot(liftDirection,f)<0 { liftDirection = -liftDirection }
        force=(liftDirection*lift*noGo + air*drag) * (0.5*1.225*aws*aws*kind.sailArea)
        // Flapping head-to-wind cloth retains a little drag, never thrust.
      }
      let relative=velocity-current
      let ahead=simd_dot(relative,f), sideways=simd_dot(relative,r)
      let waveDrag=kind.isMotorized ? Float(0) : pow(max(0,abs(ahead)/kind.hullSpeed-0.75),3)*1.7
      force -= f * kind.mass * ahead * (0.025+abs(ahead)*(kind.isMotorized ? 0.004:0.018)+waveDrag)
      // The submerged keel/centreboard resists leeway, not ground-relative drift.
      force -= r * kind.mass * sideways * (1.4+abs(sideways)*1.1)
      if abs(auxiliary)>0.02 {
        let limit=kind.engineSpeed*(auxiliary<0 ? 0.35:1)
        let opposing=ahead*auxiliary<0
        let power:Float=kind == .jetSki ? 4.5:kind == .motorboat ? 3:kind == .megaYacht ? 0.8:0.45
        force += f * kind.mass * auxiliary * (opposing ? 1:max(0,1-abs(ahead)/limit)) * power
      }
      let targetHeel=max(-0.45,min(0.45,-simd_dot(force,r)/kind.mass*(kind == .dinghy ? 0.5:0.32)))
      heel += (targetHeel-heel)*min(1,h*2.5)
      let side:Float=simd_dot(apparent,r)>=0 ? 1:-1
      let targetBoom=sailRaised ? side*sheetAngle:0
      boomAngle += (targetBoom-boomAngle)*min(1,h*3.5)
      if anchored { velocity = .zero; yawRate=0; continue }
      velocity += force/kind.mass*h
      // Rudder authority depends on flow; no stationary spin or reverse-steer bug.
      let targetYaw = max(-0.8,min(0.8,-rudder * ahead / kind.length * (kind == .jetSki ? 0.32:0.9)))
      yawRate += (targetYaw-yawRate)*min(1,h*2)
      let candidateHeading=heading+yawRate*h
      let candidate=position+velocity*WorldScale.blocks(h)
      if navigable(candidate,candidateHeading,kind) {
        position=candidate; heading=atan2(sin(candidateHeading),cos(candidateHeading))
      } else {
        // Slide along a bank or pontoon rather than becoming glued to it.
        grounded=true
        let x=position+SIMD3<Float>(candidate.x-position.x,0,0)
        let z=position+SIMD3<Float>(0,0,candidate.z-position.z)
        if navigable(x,heading,kind) { position=x; velocity.z *= 0.2 }
        else if navigable(z,heading,kind) { position=z; velocity.x *= 0.2 }
        else { velocity *= 0.2 }
        yawRate *= 0.5
      }
    }
    position.y += (water.height-position.y)*min(1,dt*5)
    let waveSlope=simd_dot(SIMD3(water.normal.x,0,water.normal.z),forward)
    pitch += (max(-0.15,min(0.15,waveSlope))-pitch)*min(1,dt*3)
  }

  /// Hull and keel sample fixed points, independent of rendered/loaded chunks.
  public static func isNavigable(position: SIMD3<Float>, heading: Float, kind: BoatKind,
    column: (Int,Int) -> TerrainColumn, block: (BlockPosition) -> Block) -> Bool {
    let f=SIMD3<Float>(-sin(heading),0,-cos(heading)),r=SIMD3<Float>(cos(heading),0,-sin(heading))
    for fore:Float in [-0.43,0,0.43] { for side:Float in [-0.43,0,0.43] {
      let p=position + (f*fore*kind.length+r*side*kind.beam)*WorldScale.blocks(1)
      let x=Int(floor(p.x)),z=Int(floor(p.z)), c=column(x,z)
      guard let body=c.water,body.kind != .lava,
        Float(c.height+1) < min(body.level,position.y)-WorldScale.blocks(kind.draft) else { return false }
      for y in Int(floor(position.y-WorldScale.blocks(kind.draft)))...Int(ceil(position.y+WorldScale.blocks(max(1.3,kind.freeboard+0.5)))) {
        if block(.init(x,y,z)).isSolid { return false }
      }
    } }
    return true
  }

  /// Prefer a dock or shore; otherwise a clear water exit starts swimming.
  public func exitPosition(block: (BlockPosition)->Block,
    water: (Int,Int)->WaterBody?, occupied:(SIMD3<Float>)->Bool = { _ in false }) -> SIMD3<Float>? {
    var swimming: SIMD3<Float>?
    for extra:Float in [0.6,1.2,2,3] { for side:Float in [-1,1] { for fore:Float in [0,0.3,-0.3] {
      let p=worldPoint([side*(kind.beam/2+extra),0,kind.length*fore])
      for y in stride(from:Int(floor(position.y))+5,through:Int(floor(position.y))-2,by:-1) {
        let feet=SIMD3<Float>(p.x,Float(y)+0.01,p.z)
        if VehiclePhysics.safeFooting(at:feet,block:block) && !occupied(feet) { return feet }
      }
      if swimming == nil, let body=water(Int(floor(p.x)),Int(floor(p.z))),body.kind != .lava {
        let feet=SIMD3<Float>(p.x,body.level-WorldScale.blocks(0.8),p.z)
        if !occupied(feet) && !PlayerPhysics(position:feet).collides(at:feet,block:block) { swimming=feet }
      }
    } } }
    return swimming
  }
}
