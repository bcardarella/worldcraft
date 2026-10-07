import Foundation
import simd

/// Value-only carrier pose shared by presentation and the life actor. Geometry
/// offsets are metres; world positions are blocks. No network decision is needed
/// to keep a passenger fixed to a moving vehicle.
public struct CompanionCarrier: Sendable {
  public enum Kind: Sendable, Equatable { case car(VehicleKind), boat(BoatKind) }
  public let id: UInt64
  public let kind: Kind
  public var position: SIMD3<Float>
  public var heading: Float
  public var heel: Float
  public var pitch: Float
  public var journey: UInt64 = 0
  public init(id: UInt64, kind: Kind, position: SIMD3<Float>, heading: Float, heel: Float = 0, pitch: Float = 0) {
    self.id=id; self.kind=kind; self.position=position; self.heading=heading; self.heel=heel; self.pitch=pitch
  }
  public var capacity: Int {
    switch kind {
    case .car: return 1
    case .boat(let boat):
      switch boat {
      case .dinghy: return 3
      case .sloop: return 4
      case .cutter: return 6
      case .yacht, .catamaran: return 8
      case .motorboat: return 2
      case .megaYacht: return 16
      case .jetSki: return 1
      }
    }
  }
  public var rotation: simd_quatf {
    let yaw=simd_quatf(angle:heading,axis:[0,1,0])
    // The jet-ski companion clings to the upright rider, whose head/body are
    // deliberately not rolled by the wave simulation.
    if kind == .boat(.jetSki) { return yaw }
    return yaw * simd_quatf(angle:heel,axis:[0,0,1]) * simd_quatf(angle:pitch,axis:[1,0,0])
  }
  public func passenger(ordinal: Int) -> CompanionPassenger { .init(carrier:self,ordinal:ordinal) }
  private static let plushBounds=HayHaySculpture.make().bounds
  fileprivate func seat(_ ordinal: Int) -> (point: SIMD3<Float>, scale: Float) {
    guard ordinal>=0,ordinal<capacity else { return (.zero,1) }
    switch kind {
    case .car(let car):
      let w=WorldScale.metres(car.halfWidth),h=WorldScale.metres(car.height)
      let cushion=WorldScale.metres(car.seatHeight)-0.385
      let base=cushion+0.025
      // A plush tucks into the seat; its long ears must clear even a coupe roof.
      let scale=min(0.65,(h-0.09-base)/Self.plushBounds.maximum.y,
        w*0.62/(Self.plushBounds.maximum.x-Self.plushBounds.minimum.x))
      return ([w*0.43,base,0.20],scale)
    case .boat(let boat):
      let side:Float=ordinal%2 == 0 ? 1:-1, row=Float(ordinal/2)
      switch boat {
      case .jetSki: return (boat.helm+[0,-0.65,0.28],0.55)
      case .megaYacht:
        return ([side*boat.beam*0.26,boat.freeboard+5.81,-boat.length*0.12+row*0.65],0.70)
      case .motorboat:
        return ([-boat.beam*0.20,boat.freeboard+0.30,0.55+Float(ordinal)*0.48],0.60)
      case .dinghy:
        if ordinal == 2 { return ([0,boat.freeboard+0.015,0.5],0.60) }
        return ([side*boat.beam*0.30,boat.freeboard-0.105,boat.length*0.23],0.60)
      default:
        let base=boat.freeboard+(boat == .catamaran ? 0.015:-0.105)
        let scale=min(0.75,(boat.freeboard+0.77-base)/Self.plushBounds.maximum.y)
        return ([side*boat.beam*0.30,base,boat.length*(0.10+row*0.06)],scale)
      }
    }
  }
  /// Exit placement must avoid the physical vehicle as well as terrain voxels.
  public func obstructsCompanion(at feet: SIMD3<Float>) -> Bool {
    let q=simd_quatf(angle:heading,axis:[0,1,0]).inverse.act(feet-position)
    let radius=WorldScale.blocks(AnimalKind.hayHay.clearance.radius)
    let height=WorldScale.blocks(AnimalKind.hayHay.clearance.height)
    let width:Float,length:Float,bottom:Float,top:Float
    switch kind {
    case .car(let car): width=car.halfWidth; length=car.halfLength; bottom=0; top=car.height
    case .boat(let boat):
      width=WorldScale.blocks(boat.beam/2); length=WorldScale.blocks(boat.length/2)
      bottom = -WorldScale.blocks(boat.draft); top=WorldScale.blocks(boat.freeboard+(boat == .megaYacht ? 6:1))
    }
    return abs(q.x)<width+radius && abs(q.z)<length+radius && q.y<top && q.y+height>bottom
  }
}

/// Kept until a safe disembarkation point is found. Extra companions remain
/// owned and aboard, but do not pile overlapping rigs into a single seat.
public struct CompanionPassenger: Sendable {
  public var carrier: CompanionCarrier
  public let ordinal: Int
  public var visible: Bool { ordinal>=0 && ordinal<carrier.capacity }
  public var clinging: Bool { carrier.kind == .boat(.jetSki) }
  public var scale: Float { carrier.seat(ordinal).scale }
  public var position: SIMD3<Float> { carrier.position+carrier.rotation.act(carrier.seat(ordinal).point*WorldScale.blocks(1)) }
  public var rotation: simd_quatf { carrier.rotation }
}

/// Ownership is independent of the bounded active population and travels with
/// the player across planets. Finding another Hay Hay never replaces an old one.
public struct HayHayCollection: Codable, Sendable {
  public private(set) var ids: [UInt64] = []
  public private(set) var lockedCastles: Set<UInt64> = []
  public init() {}
  public var count: Int { ids.count }
  public var activeIDs: [UInt64] { Array(ids.suffix(16)) }
  public var isValid: Bool { Set(ids).count == ids.count }
  public static func companion(id: UInt64, at point: SIMD3<Float>) -> AnimalState {
    var pet = AnimalState(id: id, kind: .hayHay, home: point, position: point, heading: 0)
    pet.bond = AnimalBond(id: id); pet.bond.befriended = true
    pet.collectedCompanion = true
    return pet
  }
  public mutating func rearm(castle: WorldLandmark, player: SIMD3<Float>) {
    let d=player-castle.petHome
    if d.x*d.x+d.y*d.y+d.z*d.z > 24*24 { lockedCastles.remove(castle.id) }
  }
  @discardableResult public mutating func collect(castle: WorldLandmark) -> UInt64? {
    guard castle.kind == .castle, !lockedCastles.contains(castle.id) else { return nil }
    let id = (castle.id ^ 0x4841_5943_4F4C_4C45) &+ UInt64(ids.count+1) &* 0x9E37_79B1_85EB_CA87
    guard !ids.contains(id) else { return nil }
    ids.append(id); lockedCastles.insert(castle.id); return id
  }
  /// A clear landing beside the player. Never teleport a pet into water,
  /// walls, another pet, or unloaded chunks (the caller marks those solid).
  public static func landing(near player: SIMD3<Float>, ordinal: Int,
    occupied: [SIMD3<Float>], occupiedSpace: (SIMD3<Float>)->Bool = { _ in false },
    block: (BlockPosition)->Block) -> SIMD3<Float>? {
    for ring in 0..<4 { for i in 0..<12 {
      let angle=Float((i+ordinal*5)%12) * .pi/6
      let radius=Float(3+ring*2)
      for dy: Float in [0,1,-1,2,-2,3,-3,4,-4] {
        let p=SIMD3<Float>(player.x+cos(angle)*radius,floor(player.y)+dy,player.z+sin(angle)*radius)
        guard !occupiedSpace(p), AnimalKind.hayHay.canStand(at:p,juvenile:false,block:block),
          occupied.allSatisfy({ let d=$0-p; return d.x*d.x+d.z*d.z>1.5 || abs(d.y)>3 }) else { continue }
        return p
      }
    } }
    return nil
  }
}
