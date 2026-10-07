import Foundation

public struct DinosaurNestParent: Sendable {
  public let id:UInt64
  public let color:RexColor
  public let position,home:SIMD3<Float>
  public let heading,radius:Float
  public init?(_ rex:RexState) {
    guard rex.kind == .trex,!rex.baby else { return nil }
    id=rex.id; color=rex.color; position=rex.position; home=rex.home; heading=rex.heading; radius=2.5
  }
  public init(_ rex:ColossalRexState) {
    id=rex.site.id; color=rex.site.color; position=rex.position; home=rex.site.position
    heading=rex.heading; radius=rex.footprint+5
  }
  public var nestCenter:SIMD3<Float> { position+[sin(heading)*radius,0,cos(heading)*radius] }
}

public struct DinosaurEgg: Codable, Sendable {
  public let id: UInt64
  public let position: SIMD3<Float>
  public let color: Int
  public var incubation: Float = 0
  public let hatchAfter: Float
  public var hatched = false
  public var progress: Float { min(1,incubation/hatchAfter) }
  public var isValid: Bool {
    position.allFinite && RexColor(rawValue:color) != nil && incubation.isFinite
      && incubation >= 0 && hatchAfter.isFinite && (60...600).contains(hatchAfter)
  }
}
public struct DinosaurBrood: Codable, Sendable {
  public var wait: Float
  public var clutches = 0
  public var eggs: [DinosaurEgg] = []
  public init(parentID: UInt64) { wait = 70+Float(parentID%70) }
  public var isValid: Bool {
    wait.isFinite && (0...900).contains(wait) && (0...3).contains(clutches)
      && eggs.count <= 3 && eggs.allSatisfy(\.isValid) && Set(eggs.map(\.id)).count == eggs.count
  }
  public mutating func advance(seconds: Float, healthy: Bool) {
    guard seconds.isFinite else { return }
    let dt = min(0.25,max(0,seconds))
    if healthy { wait = max(0,wait-dt) }
    for i in eggs.indices where !eggs[i].hatched { eggs[i].incubation = min(eggs[i].hatchAfter,eggs[i].incubation+dt) }
  }
  @discardableResult public mutating func lay(parent: RexState, positions: [SIMD3<Float>]) -> Bool {
    guard let parent=DinosaurNestParent(parent) else { return false }
    return lay(parent:parent,positions:positions)
  }
  @discardableResult public mutating func lay(parent: DinosaurNestParent, positions: [SIMD3<Float>]) -> Bool {
    guard wait == 0, clutches < 3,
      eggs.allSatisfy(\.hatched), !positions.isEmpty else { return false }
    clutches += 1
    eggs = positions.prefix(2).enumerated().map { index,position in
      let id = (parent.id ^ 0x4547_4753_5452_4558) &+ UInt64(clutches*7+index) &* 0x9E37_79B1_85EB_CA87
      return .init(id:id,position:position,color:parent.color.rawValue,hatchAfter:120+Float(id%61))
    }
    wait = 600
    return true
  }
}
public struct HatchedDinosaur: Codable, Sendable {
  public let parentID, groupID: UInt64
  public let color: Int
  public init(parentID: UInt64, groupID: UInt64, color: Int) {
    self.parentID=parentID; self.groupID=groupID; self.color=color
  }
  public var isValid: Bool { RexColor(rawValue:color) != nil }
}
private extension SIMD3 where Scalar == Float {
  var allFinite: Bool { (0..<3).allSatisfy { self[$0].isFinite && abs(self[$0]) < 100_000_000 } }
}
