import Foundation
import simd

extension SportsGroundMesher {
  /// Seats and clubhouse trim use static opaque terrain, with optional shared
  /// near-seat templates. Distant tiles retain the complete bowl, canopy
  /// and coloured seating rows, with no entities or animation per seat.
  static func grandstands(_ stadium: BaseballStadium, into w: inout Writer) {
    let home = stadium.field.homePlate
    func p(_ u: Float, _ v: Float, _ y: Float) -> SIMD3<Float> { [home.x+u,y,home.y-v] }
    func corner(_ angle:Float,_ d:Float,_ y:Float)->SIMD3<Float> {
      p(-cos(angle)*d,-sin(angle)*d,y)
    }
    let end=Float(BaseballStadium.wingLength)+0.5
    // Lower and upper tiers share their dimensions with the voxel sampler.
    // The middle and upper concourses remain wide, unobstructed walkways.
    if !w.tile.fullDetail {
      for row in BaseballStadium.rows {
        stadiumStrip(stadium,from:Float(row.distance)-0.5,to:Float(row.distance)+2.5,
          bottom:Float(row.height-1),top:Float(row.height),block:.limestone,into:&w)
      }
      for (a,b,h):(Float,Float,Float) in [(45.5,51.5,8),(69.5,75.5,14)] {
        stadiumStrip(stadium,from:a,to:b,bottom:h-1,top:h,block:.limestone,into:&w)
      }
      stadiumStrip(stadium,from:74.5,to:75.5,bottom:0,top:21,block:.brick,into:&w)
      stadiumStrip(stadium,from:51.5,to:75.5,bottom:21,top:22,block:.basalt,into:&w)
    }

    let individual = w.tile.size <= 2
    let sections: [(Float,Float)] = [(0,13),(19,61),(67,109),(115,157),(163,190)]
    for row in BaseballStadium.rows {
      let d=Float(row.distance)+1.3, y=Float(row.height)
      let color=row.height <= 8 ? 13:21
      for third in [false,true] {
        func q(_ a:Float,_ depth:Float,_ height:Float)->SIMD3<Float> {
          stadium.point(along:a,depth:depth,y:height,thirdBase:third)
        }
        let first=q(0,d-1,y),last=q(end,d+1,y+2)
        guard w.intersects(simd_min(first,last),simd_max(first,last)) else { continue }
        let forward:SIMD3<Float> = third ? [1,0,0]:[0,0,-1]
        if individual {
          // Only enumerate chairs in this tile, even in a thousands-seat bowl.
          let lo=third ? home.y-w.maximum.y:w.minimum.x-home.x
          let hi=third ? home.y-w.minimum.y:w.maximum.x-home.x
          let start=max(0,Int(floor((lo-1)/1.5))),finish=min(126,Int(ceil((hi+1)/1.5)))
          if start <= finish {
            for i in start...finish {
              let a=Float(i)*1.5+0.6
              guard !BaseballStadium.isAisle(a),a<190 else { continue }
              stadiumSeat(at:q(a,d,y),forward:forward,color:color,into:&w)
            }
          }
        } else {
          for (a,b) in sections {
            let low=q(a,d-0.5,y+0.55),high=q(b,d+0.55,y+0.8)
            w.box(low:simd_min(low,high),high:simd_max(low,high),block:.brick,tile:color)
            let back=q(a,d+0.45,y+0.75),backEnd=q(b,d+0.6,y+1.85)
            w.box(low:simd_min(back,backEnd),high:simd_max(back,backEnd),block:.brick,tile:color)
          }
        }
      }
      // The curved home-plate stand joins both baseline wings. Leave a radial
      // aisle through its centre, matching the collision terrace's aisle.
      let bounds=[corner(0,d+1,y),corner(.pi/2,d+1,y+2),p(0,0,y)]
      if w.intersects(bounds.reduce(SIMD3(repeating:.infinity),simd_min),bounds.reduce(SIMD3(repeating:-.infinity),simd_max)) {
        let count=max(8,Int(d * .pi/2 / (individual ? 1.5:4)))
        for i in 0..<count {
          let angle=(Float(i)+0.5)*Float.pi/2/Float(count)
          guard abs(cos(angle)-sin(angle))*d > 4 else { continue }
          let at=corner(angle,d,y),forward=SIMD3<Float>(cos(angle),0,-sin(angle))
          if individual { stadiumSeat(at:at,forward:forward,color:color,into:&w) }
          else {
            let a=Float(i)*Float.pi/2/Float(count),b=Float(i+1)*Float.pi/2/Float(count)
            w.quad([corner(b,d+0.5,y+0.7),corner(a,d+0.5,y+0.7),corner(a,d+0.5,y+1.85),corner(b,d+0.5,y+1.85)],tile:color)
            w.quad([corner(a,d-0.5,y+0.7),corner(a,d+0.5,y+0.7),corner(b,d+0.5,y+0.7),corner(b,d-0.5,y+0.7)],tile:color)
          }
        }
      }
    }

    for third in [false,true] {
      func q(_ a:Float,_ d:Float,_ y:Float)->SIMD3<Float> {
        stadium.point(along:a,depth:d,y:y,thirdBase:third)
      }
      func box(_ a:Float,_ b:Float,_ d:Float,_ e:Float,_ low:Float,_ high:Float,_ block:Block,_ tile:Int?=nil) {
        let p=q(a,d,low),r=q(b,e,high)
        w.box(low:simd_min(p,r),high:simd_max(p,r),block:block,tile:tile)
      }
      // Upper-deck fascia and handrails. Straight aisle rails run along one
      // edge, leaving the entire three-metre aisle free for walking.
      for (a,b) in sections { box(a,b,51.4,51.6,8,9.5,.brick,13) }
      for a in BaseballStadium.aisles {
        for (d,e,low,high):(Float,Float,Float,Float) in [(22,45,2.8,9.8),(52,69,10.8,15.8)] {
          w.beam(q(Float(a)-2.8,d,low),q(Float(a)-2.8,e,high),width:0.10,tile:3)
        }
      }
      // Thin roof trim and alternating structural ribs give the canopy a
      // readable silhouette without extra transparent or emissive materials.
      box(-0.5,190.5,51.25,51.5,20.8,22.15,.limestone,26)
      for a in stride(from:Float(0),through:190,by:16) {
        w.beam(q(a,52,22.1),q(a,75,22.1),width:0.24,tile:3)
        if !w.tile.fullDetail { box(a+7.5,a+8.5,72.5,73.5,0,21,.stone) }
      }
      if !w.tile.fullDetail {
        box(19.5,77.5,7.5,20.5,3,4,.basalt)
        box(19.5,20.5,7.5,20.5,0,3,.brick)
        box(76.5,77.5,7.5,20.5,0,3,.brick)
        box(19.5,77.5,19.5,20.5,0,3,.brick)
      }
      let facing:SIMD3<Float> = third ? [1,0,0]:[0,0,-1]
      // Entry signs face the field above the sunken team's staircase door.
      stadiumLabel(third ? "AWAY":"HOME",at:q(38,19.44,2.6),forward:facing,pixel:0.28,into:&w)
      stadiumLabel("LOCKERS",at:q(50.5,19.44,2.6),forward:facing,pixel:0.20,into:&w)
      // Interior details only exist in full voxel tiles, never hidden high
      // detail underneath a distant heightfield.
      if w.tile.fullDetail {
        let a=q(27,37,-12),b=q(85,66,-4)
        if w.intersects(simd_min(a,b),simd_max(a,b)) {
          for along in stride(from:Float(31),through:79,by:3) {
            box(along-0.5,along+1.5,62.43,62.48,-7.2,-7.05,.limestone,26)
            box(along+1.05,along+1.18,62.30,62.49,-9.5,-8.75,.basalt)
            for y:Float in [-10.4,-10.0] { box(along-0.2,along+0.6,62.40,62.46,y,y+0.10,.basalt) }
          }
          // Locker side banks, open shelf rails, and a team colour strip.
          for along:Float in [30.54,81.46] {
            for depth in stride(from:Float(41),through:62,by:3) {
              box(along-0.04,along+0.04,depth+0.3,depth+0.5,-9.5,-8.8,.basalt)
            }
          }
          box(28.55,83.45,64.43,64.48,-5.8,-5.4,.brick,third ? 21:13)
          stadiumLabel(third ? "AWAY":"HOME",at:q(50.5,64.40,-5.25),forward:facing,pixel:0.48,into:&w)
        }
      }
    }
  }

  private static func stadiumSeat(at p:SIMD3<Float>,forward:SIMD3<Float>,color:Int,into w:inout Writer) {
    guard w.intersects(p-[1,0,1],p+[1,2,1]) else {return}
    if w.instanceSeats {
      let instance = StadiumSeatInstance(position: p - [w.minimum.x, -Float(w.floor), w.minimum.y],
        forward: [forward.x, forward.z], color: UInt8(color))
      // Keep every potentially clipped chair on the original path. Extracting
      // a whole chair across a boundary would alter ownership and its UVs.
      if instance.isValid(in: w.tile) { w.mesh.stadiumSeats.append(instance); return }
    }
    let right=simd_cross(SIMD3<Float>(0,1,0),forward)
    for (center,size,tile) in [
      (p+[0,0.32,0],SIMD3<Float>(0.20,0.64,0.20),3),
      (p+[0,0.7,0],SIMD3<Float>(1.10,0.20,1.0),color),
      (p+[0,1.28,0]-forward*0.46,SIMD3<Float>(1.10,1.2,0.18),color)
    ] {
      for face in 0..<6 {
        w.quad(VoxelMesher.corners[face].map { q in
          center+right*((q.x-0.5)*size.x)+SIMD3<Float>(0,(q.y-0.5)*size.y,0)+forward*((q.z-0.5)*size.z)
        },tile:tile)
      }
    }
  }

  static func seatTemplate(color: UInt8) -> VoxelMesh {
    var writer = Writer(tile: .init(x: 0, z: 0, fullDetail: true), floor: 0, edits: [:])
    stadiumSeat(at: [8, 0, 8], forward: [0, 0, 1], color: Int(color), into: &writer)
    writer.mesh.positions = writer.mesh.positions.map { $0 - [8, 0, 8] }
    return writer.mesh
  }

  private static func stadiumStrip(_ s:BaseballStadium,from a:Float,to b:Float,
    bottom:Float,top:Float,block:Block,into w:inout Writer) {
    for third in [false,true] {
      let lo=s.point(along:-0.5,depth:a,y:bottom,thirdBase:third)
      let hi=s.point(along:190.5,depth:b,y:top,thirdBase:third)
      w.box(low:simd_min(lo,hi),high:simd_max(lo,hi),block:block)
    }
    let h=s.field.homePlate
    func p(_ angle:Float,_ radius:Float,_ y:Float)->SIMD3<Float> { [h.x-cos(angle)*radius,y,h.y+sin(angle)*radius] }
    for i in 0..<32 {
      let angle=Float(i)*Float.pi/64,next=Float(i+1)*Float.pi/64
      w.quad([p(angle,a,top),p(angle,b,top),p(next,b,top),p(next,a,top)],block:block)
      w.quad([p(angle,b,bottom),p(angle,a,bottom),p(next,a,bottom),p(next,b,bottom)],block:block)
      w.quad([p(angle,a,bottom),p(angle,a,top),p(next,a,top),p(next,a,bottom)],block:block)
      w.quad([p(next,b,bottom),p(next,b,top),p(angle,b,top),p(angle,b,bottom)],block:block)
    }
  }

  private static func stadiumLabel(_ text:String,at p:SIMD3<Float>,forward:SIMD3<Float>,pixel:Float,into w:inout Writer) {
    let glyphs:[Character:[String]] = [
      "A":["010","101","111","101","101"],"C":["111","100","100","100","111"],
      "E":["111","100","110","100","111"],"H":["101","101","111","101","101"],
      "K":["101","101","110","101","101"],"L":["100","100","100","100","111"],
      "M":["101","111","111","101","101"],"O":["111","101","101","101","111"],
      "R":["110","101","110","101","101"],"S":["111","100","111","001","111"],
      "W":["101","101","111","111","101"],"Y":["101","101","010","010","010"]]
    let right=simd_cross(SIMD3<Float>(0,1,0),forward)
    let origin=p-right*(Float(text.count*4-1)*pixel/2)
    for (letter,ch) in text.enumerated() {
      for (row,line) in (glyphs[ch] ?? []).enumerated() {
        for (col,value) in line.enumerated() where value == "1" {
          let at=origin+right*(Float(letter*4+col)*pixel)-SIMD3<Float>(0,Float(row)*pixel,0)
          let r=right*pixel*0.78,up=SIMD3<Float>(0,pixel*0.78,0)
          w.quad([at,at+r,at+r+up,at+up],tile:26)
        }
      }
    }
  }
}
