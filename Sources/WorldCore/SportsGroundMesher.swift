import Foundation
import simd

/// Permanent field furniture and painted surfaces join the static terrain mesh.
/// Optional stadium chairs share templates in tile-sized groups. Neither path
/// creates per-chair entities, alpha net textures, or frame updates.
/// Field references: IFAB Law 1; Little League Major/Minor field layout;
/// MLB field dimensions. Measurements are converted through WorldScale.
public enum SportsGroundMesher {
  public static func build(_ tile: TerrainTile, terrain: TerrainGenerator,
    edits: [BlockPosition: Block] = [:], instanceSeats: Bool = false) -> VoxelMesh {
    let region = SettlementGenerator.regionSize
    var sites: [Settlement] = []
    for z in floorDivide(tile.z*16,by:region)...floorDivide(tile.z*16+tile.blockSize-1,by:region) {
      for x in floorDivide(tile.x*16,by:region)...floorDivide(tile.x*16+tile.blockSize-1,by:region) {
        if let site = SettlementGenerator.site(in:.init(x,z),terrain:terrain) { sites.append(site) }
      }
    }
    return build(tile, sites: sites, edits: edits, instanceSeats: instanceSeats)
  }

  static func build(_ tile: TerrainTile, sites: [Settlement],
    edits: [BlockPosition: Block] = [:], instanceSeats: Bool = false) -> VoxelMesh {
    var mesh = VoxelMesh()
    for site in sites {
      for field in site.sportsGrounds where field.overlaps(x:tile.x*16,z:tile.z*16,width:tile.blockSize) {
        mesh.append(build(field, floor:site.floor, tile:tile, edits:edits, instanceSeats: instanceSeats))
      }
    }
    return mesh
  }

  public static func build(_ field: SportsGround, floor: Int, tile: TerrainTile,
    edits: [BlockPosition: Block] = [:], instanceSeats: Bool = false) -> VoxelMesh {
    guard field.overlaps(x:tile.x*16,z:tile.z*16,width:tile.blockSize) else { return .init() }
    var writer = Writer(tile:tile, floor:floor, edits:edits, instanceSeats: instanceSeats)
    if field.kind == .soccer { soccer(field, into:&writer) }
    else { baseball(field, into:&writer) }
    return writer.mesh
  }

  private static func soccer(_ field: SportsGround, into w: inout Writer) {
    let c = field.center, h = field.pitchHalfSize
    func p(_ x: Float, _ z: Float, _ y: Float = 0.04) -> SIMD3<Float> { [c.x+x,y,c.y+z] }
    // Alternating mower passes, with thin white paint above a level grass deck.
    let stripe = h.y*2/12
    for i in 0..<12 where i%2 == 1 {
      w.flat(x0:c.x-h.x,x1:c.x+h.x,z0:c.y-h.y+Float(i)*stripe,
        z1:c.y-h.y+Float(i+1)*stripe,y:0.018,block:.grass,shade:1)
    }
    w.rectangle(center:c,half:h)
    w.line(p(-h.x,0),p(h.x,0))
    w.arc(center:c,radius:WorldScale.blocks(9.15),from:0,to:2*Float.pi)
    w.disc(center:c,radius:0.22)
    let goalHalf = WorldScale.blocks(7.32)/2, goalHeight = WorldScale.blocks(2.44)
    // Regulations measure the clear opening, not the centres of the posts.
    let postX = goalHalf+0.11, crossbarY = goalHeight+0.11
    for sign: Float in [-1,1] {
      let end = sign*h.y
      for (depth, halfWidth): (Float,Float) in [(33,goalHalf+33),(11,goalHalf+11)] {
        w.line(p(-halfWidth,end),p(-halfWidth,end-sign*depth))
        w.line(p(halfWidth,end),p(halfWidth,end-sign*depth))
        w.line(p(-halfWidth,end-sign*depth),p(halfWidth,end-sign*depth))
      }
      let spot = SIMD2(c.x,c.y+end-sign*22)
      w.disc(center:spot,radius:0.22)
      // Only the portion of the penalty arc outside the penalty area is painted.
      let alpha = acos(Float(11)/18.3)
      let facing = sign > 0 ? -Float.pi/2 : Float.pi/2
      w.arc(center:spot,radius:18.3,from:facing-alpha,to:facing+alpha)
      let back = end+sign*4.4
      for side: Float in [-1,1] {
        w.beam(p(side*postX,end,0),p(side*postX,end,crossbarY),width:0.22,tile:26)
        w.beam(p(side*postX,back,0),p(side*postX,back,goalHeight-0.3),width:0.12,tile:26)
        w.beam(p(side*postX,end,crossbarY),p(side*postX,back,goalHeight-0.3),width:0.12,tile:26)
        w.net(p(side*postX,end,0),p(side*postX,back,0),height:goalHeight-0.3)
      }
      w.beam(p(-postX,end,crossbarY),p(postX,end,crossbarY),width:0.22,tile:26)
      w.net(p(-postX,back,0),p(postX,back,0),height:goalHeight-0.3)
      // Roof strings make the net visibly three dimensional from above.
      for x in stride(from:-goalHalf,through:goalHalf,by:w.netSpacing) {
        w.beam(p(x,end,crossbarY),p(x,back,goalHeight-0.3),width:0.035,tile:26)
      }
      for side: Float in [-1,1] {
        let corner = SIMD2(c.x+side*h.x,c.y+end)
        let start: Float = side < 0 ? (sign < 0 ? 0 : -.pi/2) : (sign < 0 ? .pi/2 : .pi)
        w.arc(center:corner,radius:2,from:start,to:start+Float.pi/2)
        let flag = p(side*(h.x+0.6),end+sign*0.6,0)
        w.beam(flag,flag+[0,3.2,0],width:0.10,tile:26)
        w.box(low:flag+[0,2.25,-0.03],high:flag+[1.1,3.2,0.03],block:.brick,tile:21)
      }
    }
    // Covered team benches and technical boxes, set back from the touchline.
    for sign: Float in [-1,1] {
      let a = p(h.x+4,sign*50,0)
      w.box(low:a+[0,0,0],high:a+[3,0.8,12],block:.wood)
      w.box(low:a+[0,0.8,11.7],high:a+[3,2.3,12],block:.wood)
      w.box(low:a+[-0.4,4.8,-0.4],high:a+[4,5.1,12.4],block:.basalt)
      for dz: Float in [0,12] { w.beam(a+[3.5,0,dz],a+[3.5,4.8,dz],width:0.2,tile:3) }
      w.rectangle(center:[a.x+1.7,a.z+6],half:[3.3,8],width:0.16)
    }
    w.scoreboard(at:p(0,-h.y-10,0))
  }

  private static func baseball(_ field: SportsGround, into w: inout Writer) {
    let home = field.homePlate, b = field.basePath
    func p(_ u: Float, _ v: Float, _ y: Float = 0.04) -> SIMD3<Float> { [home.x+u,y,home.y-v] }
    // Local patches keep mower shading out of the dirt, warning track and edits.
    let x0 = max(field.x0,Int(w.minimum.x)), x1 = min(field.x1,Int(w.maximum.x)-1)
    let z0 = max(field.z0,Int(w.minimum.y)), z1 = min(field.z1,Int(w.maximum.y)-1)
    if x0 <= x1 && z0 <= z1 {
      for z in stride(from:floorDivide(z0,by:4)*4,through:z1,by:4) {
        for x in stride(from:floorDivide(x0,by:4)*4,through:x1,by:4) {
          let u = Float(x)+2-home.x, v = home.y-Float(z)-2
          guard u > 4, v > 4, Int((u+v)/14)%2 == 1,
            (u*u+v*v).squareRoot() < field.outfieldRadius(u:u,v:v)-8,
            [SIMD2<Float>(0.01,0.01),[3.99,0.01],[3.99,3.99],[0.01,3.99],[2,2]].allSatisfy({
              field.surface(x:Float(x)+$0.x,z:Float(z)+$0.y) == .grass
            }) else { continue }
          w.flat(x0:Float(x),x1:Float(x+4),z0:Float(z),z1:Float(z+4),y:0.018,block:.grass,shade:1)
        }
      }
    }
    // Foul lines continue through first/third base to their yellow foul poles.
    w.line(p(0,0),p(field.foulDistance,0))
    w.line(p(0,0),p(0,field.foulDistance))
    let halfBase = WorldScale.blocks((field.senior ? 18:15)*0.0254)/2
    for (u,v): (Float,Float) in [(b,0),(b,b),(0,b)] {
      w.box(low:p(u-halfBase,v+halfBase,0.035),high:p(u+halfBase,v-halfBase,0.15),block:.limestone,tile:26)
    }
    // White pentagonal home plate, pointed toward the catcher.
    let right = SIMD2<Float>(1,1)/Float(2).squareRoot()
    let forward = SIMD2<Float>(1,-1)/Float(2).squareRoot()
    func plate(_ x:Float,_ z:Float) -> SIMD3<Float> {
      let q = home+right*x+forward*z; return [q.x,0.055,q.y]
    }
    w.quad([plate(-0.43,0.43),plate(0.43,0.43),plate(0.43,0),plate(-0.43,0)],tile:26,paint:true)
    w.quad([plate(-0.43,0),plate(0.43,0),plate(0,-0.43),plate(0,-0.43)],tile:26,paint:true)
    for side: Float in [-1,1] {
      let box = home+right*(side*1.55)
      let a = SIMD3<Float>(box.x,0.045,box.y)
      let r = SIMD3<Float>(right.x,0,right.y)*0.6
      let f = SIMD3<Float>(forward.x,0,forward.y)*1.8
      w.line(a-r-f,a+r-f); w.line(a+r-f,a+r+f)
      w.line(a+r+f,a-r+f); w.line(a-r+f,a-r-f)
    }
    // Low rounded dirt mound and white pitching rubber at the measured distance.
    let mound = field.pitchingDistance/Float(2).squareRoot()
    let top: Float = field.senior ? 0.508 : 0.30
    let c = SIMD2(home.x+mound,home.y-mound)
    for i in 0..<48 {
      let a = Float(i)*2 * .pi/48, d = Float(i+1)*2 * .pi/48
      func ring(_ angle:Float,_ radius:Float,_ y:Float)->SIMD3<Float> {
        [c.x+cos(angle)*radius,y,c.y+sin(angle)*radius]
      }
      w.quad([ring(a,5.49,0.025),ring(d,5.49,0.025),ring(d,2,top),ring(a,2,top)],block:.dirt,paint:true)
      w.quad([[c.x,top,c.y],ring(a,2,top),ring(d,2,top),ring(d,2,top)],block:.dirt,paint:true)
    }
    let rubber = p(mound,mound,top+0.02)
    let r = SIMD3(right.x,0,right.y)*WorldScale.blocks(0.6096)/2
    let f = SIMD3(forward.x,0,forward.y)*WorldScale.blocks(0.1524)/2
    w.quad([rubber-r-f,rubber+r-f,rubber+r+f,rubber-r+f],tile:26,paint:true)
    for (u,v): (Float,Float) in [(field.foulDistance,0),(0,field.foulDistance)] {
      w.beam(p(u,v,0),p(u,v,field.senior ? 18:10),width:0.22,tile:25)
    }
    // Cap the padded outfield wall; its curved silhouette is also retained in LOD.
    for i in 0..<64 {
      let a = Float(i)*Float.pi/128, d = Float(i+1)*Float.pi/128
      func edge(_ angle:Float,_ y:Float)->SIMD3<Float> {
        let r = field.outfieldRadius(u:cos(angle),v:sin(angle))
        return p(cos(angle)*r,sin(angle)*r,y)
      }
      w.beam(edge(a,4.05),edge(d,4.05),width:0.20,tile:25)
      if !w.tile.fullDetail { w.quad([edge(a,0),edge(d,0),edge(d,4),edge(a,4)],block:.basalt) }
    }
    // Backstop screen and wings behind home, safely outside fair territory.
    let screen = [p(-12,20,0),p(-12,0,0),p(0,-12,0),p(20,-12,0)]
    for i in 0..<screen.count-1 { w.net(screen[i],screen[i+1],height:12,tile:3) }
    for q in screen { w.beam(q,q+[0,12,0],width:0.18,tile:3) }
    for swap in [false,true] {
      func dugout(_ u:Float,_ v:Float,_ y:Float)->SIMD3<Float> { swap ? p(v,u,y):p(u,v,y) }
      if !field.hasStadium {
        let a=dugout(11,-13,5), e=dugout(b+13,-6,5.35)
        w.box(low:simd_min(a,e),high:simd_max(a,e),block:.basalt)
        for along in [Float(12),b+12] {
          w.beam(dugout(along,-7,0),dugout(along,-7,5),width:0.2,tile:3)
        }
      }
      let ca=dugout(b-8,-4,0.04), cb=dugout(b+8,-2,0.04)
      w.rectangle(center:[(ca.x+cb.x)/2,(ca.z+cb.z)/2],half:[abs(ca.x-cb.x)/2,abs(ca.z-cb.z)/2])
    }
    let scoreDistance = field.outfieldRadius(u:1,v:1)/Float(2).squareRoot()+12
    w.scoreboard(at:p(scoreDistance,scoreDistance,0))
    if let stadium = field.stadium { grandstands(stadium, into:&w) }
  }

  struct Writer {
    let tile: TerrainTile
    let floor: Int
    let minimum, maximum: SIMD2<Float>
    let holes: [BlockPosition]
    let instanceSeats: Bool
    var mesh = VoxelMesh()
    var netSpacing: Float { tile.size >= 8 ? 1.5 : 0.5 }
    init(tile:TerrainTile,floor:Int,edits:[BlockPosition:Block],instanceSeats:Bool=false) {
      self.tile=tile; self.floor=floor
      self.instanceSeats = instanceSeats && tile.fullDetail
      minimum=[Float(tile.x*16),Float(tile.z*16)]
      maximum=minimum+SIMD2(repeating:Float(tile.blockSize))
      holes=edits.keys.filter { $0.y == floor-1 && tile.contains($0.chunk) }
    }
    func intersects(_ low:SIMD3<Float>,_ high:SIMD3<Float>)->Bool {
      high.x>minimum.x && low.x<maximum.x && high.z>minimum.y && low.z<maximum.y
    }
    // Clip actual polygons rather than their bounds. This preserves arcs and
    // diagonal lines at chunk seams and emits each piece in its owning tile.
    func clip(_ polygon:[SIMD3<Float>],axis:Int,edge:Float,greater:Bool)->[SIMD3<Float>] {
      guard var previous=polygon.last else {return []}
      var output:[SIMD3<Float>]=[]
      var wasInside=greater ? previous[axis]>=edge:previous[axis]<=edge
      for point in polygon {
        let inside=greater ? point[axis]>=edge:point[axis]<=edge
        if inside != wasInside {
          let t=(edge-previous[axis])/(point[axis]-previous[axis])
          output.append(previous+(point-previous)*t)
        }
        if inside {output.append(point)}
        previous=point; wasInside=inside
      }
      return output
    }
    mutating func quad(_ points:[SIMD3<Float>],block:Block = .limestone,tile:Int?=nil,shade:Int=0,paint:Bool=false) {
      let low=points.reduce(SIMD3<Float>(repeating:.infinity),simd_min)
      let high=points.reduce(SIMD3<Float>(repeating:-.infinity),simd_max)
      guard high.x>minimum.x && low.x<maximum.x && high.z>minimum.y && low.z<maximum.y else {return}
      var polygon=points
      for (axis,lo,hi) in [(0,minimum.x,maximum.x),(2,minimum.y,maximum.y)] {
        polygon=clip(polygon,axis:axis,edge:lo,greater:true)
        polygon=clip(polygon,axis:axis,edge:hi,greater:false)
      }
      guard polygon.count>=3 else {return}
      var pieces=[polygon]
      if paint {
        for hole in holes where Float(hole.x+1)>low.x && Float(hole.x)<high.x && Float(hole.z+1)>low.z && Float(hole.z)<high.z {
          var next:[[SIMD3<Float>]]=[]
          for var piece in pieces {
            for (axis,edge,greater) in [(0,Float(hole.x),false),(0,Float(hole.x+1),true),(2,Float(hole.z),false),(2,Float(hole.z+1),true)] {
              let outside=clip(piece,axis:axis,edge:edge,greater:greater)
              if outside.count>=3 {next.append(outside)}
              piece=clip(piece,axis:axis,edge:edge,greater:!greater)
            }
          }
          pieces=next
        }
      }
      let origin=SIMD3<Float>(minimum.x,-Float(floor),minimum.y)
      for raw in pieces {
        var piece:[SIMD3<Float>]=[]
        for point in raw where piece.last.map({simd_distance_squared($0,point)>0.00000001}) ?? true {piece.append(point)}
        if piece.count>1,simd_distance_squared(piece[0],piece[piece.count-1])<0.00000001 {piece.removeLast()}
        // Pair fan triangles into quads: the terrain packer shares this layout.
        var i=1
        while i+1<piece.count {
          let j=min(i+2,piece.count-1)
          var q=[piece[0],piece[i],piece[i+1],piece[j]]
          var n=simd_cross(q[1]-q[0],q[2]-q[0])
          if simd_length_squared(n)<0.00000001 {i+=2;continue}
          if paint && n.y<0 {
            q = j == i+1 ? [q[0],q[2],q[1],q[1]] : [q[0],q[3],q[2],q[1]]
            n = -n
          }
          n=simd_normalize(n)
          mesh.appendQuad(q.map{$0-origin},normal:n,block:block,face:abs(n.y)>0.5 ? 2:0,
            tileIndex:tile,materialIndex:0,occlusion:shade)
          i+=2
        }
      }
    }
    mutating func flat(x0:Float,x1:Float,z0:Float,z1:Float,y:Float,block:Block,shade:Int=0) {
      // Atlas tiles cannot repeat across a large quad. Match the underlying
      // terrain's texel density instead of stretching one grass tile across an
      // entire mower pass. Clip first: a job only visits its own small patch.
      let low=simd_max(SIMD2(x0,z0),minimum),high=simd_min(SIMD2(x1,z1),maximum)
      guard high.x>low.x && high.y>low.y else {return}
      let step=Float(tile.sampleStride)
      for z in stride(from:Foundation.floor(low.y/step)*step,to:high.y,by:step) {
        for x in stride(from:Foundation.floor(low.x/step)*step,to:high.x,by:step) {
          let a=simd_max(low,SIMD2(x,z)),b=simd_min(high,SIMD2(x+step,z+step))
          quad([[a.x,y,b.y],[b.x,y,b.y],[b.x,y,a.y],[a.x,y,a.y]],block:block,shade:shade,paint:true)
        }
      }
    }
    mutating func line(_ a:SIMD3<Float>,_ b:SIMD3<Float>,width:Float=0.20) {
      guard intersects(simd_min(a,b)-SIMD3(repeating:width),simd_max(a,b)+SIMD3(repeating:width)) else {return}
      let d=b-a, length=simd_length(SIMD2(d.x,d.z))
      guard length>0.0001 else {return}
      let side=SIMD3<Float>(-d.z,0,d.x)*(width/2/length)
      quad([a-side,b-side,b+side,a+side],tile:26,paint:true)
    }
    mutating func rectangle(center:SIMD2<Float>,half:SIMD2<Float>,width:Float=0.20) {
      let a=SIMD3<Float>(center.x-half.x,0.045,center.y-half.y),b=a+[half.x*2,0,0]
      let c=b+[0,0,half.y*2],d=a+[0,0,half.y*2]
      line(a,b,width:width);line(b,c,width:width);line(c,d,width:width);line(d,a,width:width)
    }
    mutating func arc(center:SIMD2<Float>,radius:Float,from:Float,to:Float) {
      let count=max(8,Int((to-from)*radius/0.9))
      for i in 0..<count {
        let a=from+(to-from)*Float(i)/Float(count),b=from+(to-from)*Float(i+1)/Float(count)
        line([center.x+cos(a)*radius,0.046,center.y+sin(a)*radius],
          [center.x+cos(b)*radius,0.046,center.y+sin(b)*radius])
      }
    }
    mutating func disc(center:SIMD2<Float>,radius:Float) {
      for i in 0..<12 {
        let a=Float(i)*2 * .pi/12,b=Float(i+1)*2 * .pi/12
        let q=SIMD3<Float>(center.x,0.05,center.y)
        quad([q,q+[cos(a)*radius,0,sin(a)*radius],q+[cos(b)*radius,0,sin(b)*radius],q],tile:26,paint:true)
      }
    }
    mutating func box(low:SIMD3<Float>,high:SIMD3<Float>,block:Block,tile:Int?=nil) {
      guard intersects(low,high) else {return}
      for face in 0..<6 {quad(VoxelMesher.corners[face].map{low+$0*(high-low)},block:block,tile:tile)}
    }
    mutating func beam(_ a:SIMD3<Float>,_ b:SIMD3<Float>,width:Float,tile:Int) {
      guard intersects(simd_min(a,b)-SIMD3(repeating:width),simd_max(a,b)+SIMD3(repeating:width)) else {return}
      let length=simd_length(b-a)
      guard length>0.0001 else {return}
      let axis=(b-a)/length
      let u=simd_normalize(simd_cross(axis,abs(axis.y)<0.95 ? SIMD3<Float>(0,1,0):[1,0,0]))*width/2
      let v=simd_normalize(simd_cross(axis,u))*width/2
      let corners=[a-u-v,a+u-v,a+u+v,a-u+v,b-u-v,b+u-v,b+u+v,b-u+v]
      for face in [[0,3,2,1],[4,5,6,7],[0,1,5,4],[1,2,6,5],[2,3,7,6],[3,0,4,7]] {
        quad(face.map{corners[$0]},tile:tile)
      }
    }
    mutating func net(_ a:SIMD3<Float>,_ b:SIMD3<Float>,height:Float,tile:Int=26) {
      guard intersects(simd_min(a,b)-SIMD3(repeating:0.1),simd_max(a,b)+[0.1,height,0.1]) else {return}
      let steps=max(1,Int(ceil(simd_distance(a,b)/netSpacing)))
      for i in 0...steps {
        let q=a+(b-a)*(Float(i)/Float(steps))
        beam(q,q+[0,height,0],width:0.035,tile:tile)
      }
      for y in stride(from:Float(0),through:height,by:netSpacing) {beam(a+[0,y,0],b+[0,y,0],width:0.035,tile:tile)}
    }
    mutating func scoreboard(at a:SIMD3<Float>) {
      guard intersects(a+[-10,0,-0.4],a+[10,10,0.1]) else {return}
      box(low:a+[-10,5,-0.4],high:a+[10,10,0],block:.basalt)
      for x:Float in [-8,8] {beam(a+[x,0,-0.2],a+[x,5,-0.2],width:0.35,tile:3)}
      let glyphs:[Character:[String]]=[
        "H":["101","101","111","101","101"],"O":["111","101","101","101","111"],
        "M":["101","111","111","101","101"],"E":["111","100","110","100","111"],
        "A":["010","101","111","101","101"],"W":["101","101","111","111","101"],
        "Y":["101","101","010","010","010"]]
      for (label,x) in [("HOME",Float(-8.5)),("AWAY",Float(1.5))] {
        for (i,ch) in label.enumerated() {
          for (row,line) in (glyphs[ch] ?? []).enumerated() {
            for (col,pixel) in line.enumerated() where pixel == "1" {
              let p=a+[x+Float(i*4+col)*0.43,9.4-Float(row)*0.3,0.015]
              box(low:p,high:p+[0.32,0.23,0.03],block:.limestone,tile:26)
            }
          }
        }
        let zero=a+[x+2.5,5.6,0.025]
        for (lo,hi) in [(SIMD3<Float>(0,0,0),SIMD3<Float>(2,0.23,0.04)),([0,1.8,0],[2,2.03,0.04]),([0,0,0],[0.23,2,0.04]),([1.77,0,0],[2,2,0.04])] {
          box(low:zero+lo,high:zero+hi,block:.limestone,tile:25)
        }
      }
    }
  }
}
