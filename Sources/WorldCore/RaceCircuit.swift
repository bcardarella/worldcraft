import Foundation
import simd

public enum CircuitLayout: Int, CaseIterable, Sendable {
  case speedway, grandPrix, technical, triOval, club, endurance
  public var name: String { switch self { case .speedway: "Sunset Speedway"; case .grandPrix: "Willow Grand Prix"; case .technical: "Crystal Hairpin Circuit"; case .triOval: "Thunder Tri-Oval"; case .club: "Juniper Club Circuit"; case .endurance: "Aurora Endurance Circuit" } }
}

/// Immutable circuit geometry. Curved road-course segments are shared, never
/// rebuilt during terrain sampling or a vehicle frame.
public struct RaceCircuit: Sendable {
  public let id: UInt64
  public let center: SIMD3<Float>
  public let straight, radius: Float
  public let layout: CircuitLayout
  public static let roadHalfWidth: Float = 9
  public init(id:UInt64,center:SIMD3<Float>,straight:Float=160,radius:Float=104,layout:CircuitLayout = .speedway) {
    self.id=id; self.center=center; self.straight=straight; self.radius=radius; self.layout=layout
  }
  private struct Segment: Sendable {
    let a, delta: SIMD2<Float>
    let length, start: Float
  }
  private static func road(_ points: [SIMD2<Float>], startZ: Float = 140) -> [Segment] {
    var samples: [SIMD2<Float>] = []
    for i in points.indices {
      let p=points[i], before=points[(i+points.count-1)%points.count], after=points[(i+1)%points.count]
      let a=p+(before-p)*0.18, b=p+(after-p)*0.18
      for j in 0...8 {
        let t=Float(j)/8
        samples.append(a*(1-t)*(1-t)+p*(2*t*(1-t))+b*t*t)
      }
    }
    // Start the timer in the middle of the long, flat pit straight.
    let crossing=samples.indices.first { i in
      let a=samples[i], b=samples[(i+1)%samples.count]
      return a.x<=0 && b.x>0 && a.y>startZ-10 && b.y>startZ-10
    }!
    samples=Array(samples[(crossing+1)...])+Array(samples[...crossing])
    samples.insert([0,startZ],at:0)
    var result:[Segment]=[], distance:Float=0
    for i in samples.indices {
      let a=samples[i], delta=samples[(i+1)%samples.count]-a, length=simd_length(delta)
      guard length>0.01 else { continue }
      result.append(.init(a:a,delta:delta,length:length,start:distance)); distance += length
    }
    return result
  }
  private static let grandPrix = road([[0,140],[205,140],[250,85],[220,-105],[85,-135],[40,-65],[-80,-65],[-115,-145],[-230,-120],[-260,0],[-180,140]])
  private static let technical = road([[0,140],[190,140],[244,72],[150,20],[232,-68],[162,-132],[42,-132],[42,-5],[-58,-5],[-58,-132],[-220,-132],[-250,-20],[-200,120],[-100,140]])
  private static let triOval = road([[0,104],[196,104],[275,20],[225,-135],[0,-164],[-225,-135],[-275,20],[-196,104]], startZ: 104)
  private static let club = road([[0,140],[208,140],[260,65],[170,-5],[258,-96],[190,-150],[62,-150],[-10,-80],[-100,-148],[-240,-135],[-265,-15],[-210,140]])
  private static let endurance = road([[0,140],[224,140],[265,55],[246,-140],[128,-155],[128,42],[34,42],[34,-150],[-88,-150],[-108,-32],[-235,-50],[-264,44],[-200,140]])
  private var segments:[Segment] {
    switch layout {
    case .speedway, .grandPrix: Self.grandPrix
    case .technical: Self.technical
    case .triOval: Self.triOval
    case .club: Self.club
    case .endurance: Self.endurance
    }
  }
  public var length:Float { layout == .speedway ? 4*straight+2 * .pi*radius : segments.last.map { $0.start+$0.length } ?? 0 }
  public var startZ:Float { layout == .speedway ? radius : layout == .triOval ? 104 : 140 }
  public var pitZ:Float { startZ+24 }
  public func pitPosition(_ index:Int) -> SIMD3<Float> { center+[Float(index*16-16),0,pitZ] }
  private func nearest(_ point: SIMD3<Float>) -> (Float,Float) {
    let p=SIMD2<Float>(point.x-center.x,point.z-center.z)
    var best=Float.infinity, progress:Float=0, signed:Float=0
    for s in segments {
      let end=s.a+s.delta
      let bx=max(0,max(min(s.a.x,end.x)-p.x,p.x-max(s.a.x,end.x)))
      let bz=max(0,max(min(s.a.y,end.y)-p.y,p.y-max(s.a.y,end.y)))
      if bx*bx+bz*bz>best { continue }
      let d=p-s.a
      let t=max(0,min(1,simd_dot(d,s.delta)/(s.length*s.length)))
      let residual=d-s.delta*t, square=simd_length_squared(residual)
      if square < best {
        best=square; progress=s.start+t*s.length
        signed=sqrt(square)*(s.delta.x*residual.y-s.delta.y*residual.x >= 0 ? 1:-1)
      }
    }
    return (signed,progress)
  }
  public func laneDistance(x:Float,z:Float) -> Float {
    if layout != .speedway { return nearest([x,center.y,z]).0 }
    let dx=max(0,abs(x-center.x)-straight),dz=z-center.z
    return sqrt(dx*dx+dz*dz)-radius
  }
  public func point(at distance:Float) -> SIMD3<Float> {
    let s=(distance.truncatingRemainder(dividingBy:length)+length).truncatingRemainder(dividingBy:length)
    if layout != .speedway {
      let segment=segments.first { $0.start+$0.length >= s } ?? segments[0]
      let p=segment.a+segment.delta*((s-segment.start)/segment.length)
      return center+[p.x,0,p.y]
    }
    if s<straight { return center+[s,0,radius] }
    if s<straight + .pi*radius { let a=(s-straight)/radius; return center+[straight+sin(a)*radius,0,cos(a)*radius] }
    if s<3*straight + .pi*radius { return center+[straight-(s-straight - .pi*radius),0,-radius] }
    if s<3*straight + 2 * .pi*radius { let a=(s-3*straight - .pi*radius)/radius; return center+[-straight-sin(a)*radius,0,-cos(a)*radius] }
    return center+[-straight+(s-3*straight-2 * .pi*radius),0,radius]
  }
  public func tangent(at distance:Float) -> SIMD3<Float> { simd_normalize(point(at:distance+0.5)-point(at:distance-0.5)) }
  public func point(at distance:Float,lane:Float) -> SIMD3<Float> {
    let forward=tangent(at:distance)
    return point(at:distance)+SIMD3<Float>(-forward.z,0,forward.x)*lane
  }
  public func progress(at point:SIMD3<Float>) -> Float {
    if layout != .speedway { return nearest(point).1 }
    let p=point-center
    if p.x>straight { return straight+atan2(p.x-straight,p.z)*radius }
    if p.x < -straight { return 3*straight + .pi*radius+atan2(-p.x-straight,-p.z)*radius }
    return p.z>=0 ? (p.x>=0 ? p.x:length+p.x):2*straight + .pi*radius-p.x
  }
}
