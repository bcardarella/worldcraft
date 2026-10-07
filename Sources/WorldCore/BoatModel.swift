import Foundation

/// Fine solid voxel strips shape the hull, cockpit and cloth. Models are metres,
/// prepared once per class, with one palette material per articulated part.
public enum BoatModel {
  public static let colors: [SIMD3<Float>] = [
    [0.94,0.95,0.89], [0.055,0.19,0.32], [0.62,0.40,0.20], [0.20,0.25,0.29],
    [0.88,0.92,0.90], [0.09,0.52,0.63], [0.13,0.23,0.29], [0.88,0.30,0.12],
    [0.71,0.74,0.73], [0.88,0.78,0.54]
  ]
  public static func parts(for kind: BoatKind) -> [VehicleModelPart] {
    if kind.isMotorized { return powerParts(kind) }
    let length=kind.length,beam=kind.beam,deck=kind.freeboard
    var hull=VehicleModelPart(name:"Hull")
    let step:Float=kind == .yacht || kind == .catamaran ? 0.30:0.16
    let slices=Int(ceil(length/step))
    for i in 0..<slices {
      let z = -length/2+(Float(i)+0.5)*length/Float(slices), t=z/(length/2)
      // Narrow bow, rounded quarters, shallow V bottom and fine sheer line.
      let width=max(0.10,beam*(t<0 ? sqrt(max(0,1-t*t)):1-0.32*t*t))
      let rise=pow(abs(t),3)*(kind == .dinghy ? 0.12:0.3)
      for layer in 0..<4 {
        let fraction=Float(layer)/4
        hull.box([width*(0.45+fraction*0.55),0.18,length/Float(slices)],
          [0,-0.45+fraction*0.60+rise,z],layer<2 ? 1:0)
      }
      for side:Float in [-1,1] {
        hull.box([0.10,deck+0.15,length/Float(slices)],[side*(width/2-0.05),deck/2+rise,z],0)
        hull.box([0.025,0.055,length/Float(slices)],[side*width/2,deck*0.4+rise,z],5)
        hull.box([0.09,0.045,length/Float(slices)],[side*(width/2-0.07),deck+rise+0.035,z],2)
      }
      if z < length*0.05 || z>length*0.43 {
        hull.box([max(0.05,width-0.16),0.065,length/Float(slices)],[0,deck-0.06+rise,z],2)
        if i%3==0 { hull.box([max(0.05,width-0.18),0.009,0.012],[0,deck-0.022+rise,z],9) }
      }
    }
    hull.box([beam*0.64,0.10,length*0.33],[0,deck-0.48,length*0.23],2)
    for side:Float in [-1,1] {
      hull.box([beam*0.20,0.10,length*0.33],[side*beam*0.30,deck-0.18,length*0.23],2)
      if kind != .dinghy {
        // Stanchions and continuous rails stay outside the cockpit view.
        for z in stride(from:-length*0.32,through:length*0.41,by:length/8) {
          hull.box([0.035,0.70,0.035],[side*beam*0.44,deck+0.35,z],8)
        }
        hull.box([0.025,0.025,length*0.73],[side*beam*0.44,deck+0.70,length*0.045],8)
        hull.box([0.14,0.22,0.14],[side*beam*0.25,deck+0.10,length*0.18],3)
        hull.box([0.30,0.09,0.10],[side*beam*0.25,deck+0.23,length*0.18],8)
      }
    }
    // Keel/counterweight, cabin with dark inset glazing, companionway and hatch.
    hull.box([0.14,kind.draft,kind.length*0.19],[0,-kind.draft/2,0],3)
    if kind != .dinghy {
      hull.box([beam*0.50,deck*0.6,length*0.32],[0,deck*1.26,-length*0.13],0)
      hull.box([beam*0.51,0.20,length*0.23],[0,deck*1.36,-length*0.15],6)
      hull.box([beam*0.53,0.08,length*0.33],[0,deck*1.61,-length*0.13],0)
      hull.box([beam*0.23,0.48,0.025],[0,deck+0.12,length*0.031],3)
      hull.box([beam*0.20,0.025,length*0.08],[0,deck*1.66,-length*0.07],5)
      hull.box([0.06,0.65,0.06],[0,deck+0.3,length*0.27],8)
      // Low helm ring leaves the horizon and bow visible.
      for i in 0..<16 {
        let a=Float(i)*2 * .pi/16
        hull.box([0.04,0.04,0.04],[sin(a)*0.25,deck+0.52+cos(a)*0.25,length*0.27],2)
      }
    } else {
      hull.box([beam*0.86,0.10,0.24],[0,deck-0.06,0.5],2)
    }
    let mastZ = -length*0.13
    hull.box([0.08,kind.mastHeight,0.08],[0,deck+kind.mastHeight/2,mastZ],8)
    for side:Float in [-1,1] {
      // Rigging is a stepped solid cable, with no alpha texture overdraw.
      for i in 0..<20 {
        let t=(Float(i)+0.5)/20
        hull.box([0.025,kind.mastHeight/20,0.025],[side*beam*0.40*(1-t),deck+t*kind.mastHeight,mastZ],3)
      }
    }
    var mainsail=VehicleModelPart(name:"Mainsail",pivot:[0,deck+0.85,mastZ])
    let sailHeight=kind.mastHeight-1.05,sailFoot=length*0.47
    for i in 0..<32 {
      let t=(Float(i)+0.5)/32, width=sailFoot*(1-t)
      // Camber gives cloth volume and catches changing light; a reef stripe
      // distinguishes the three classes without additional materials.
      mainsail.box([0.035,sailHeight/32,width],[sin(t * .pi)*0.08,sailHeight*t,width/2],i==8 || i==9 ? 5:4)
    }
    mainsail.box([0.065,0.065,sailFoot],[0,0,sailFoot/2],8)
    var jib=VehicleModelPart(name:"Jib",pivot:[0,deck+0.20,-length*0.44])
    for i in 0..<24 {
      let t=(Float(i)+0.5)/24,span=length*0.29*(1-t)
      jib.box([0.03,(kind.mastHeight-0.7)/24,span],[0.04*sin(t * .pi),t*(kind.mastHeight-0.7),length*0.31*t+span/2],i<3 ? 5:4)
    }
    var rudder=VehicleModelPart(name:"Rudder",pivot:[0,-0.10,length*0.47])
    rudder.box([0.10,kind.draft*0.7,0.36],[0,-kind.draft*0.3,0.04],3)
    if kind == .dinghy { rudder.box([0.045,0.045,0.9],[0,deck+0.1,-0.3],2) }
    var pennant=VehicleModelPart(name:"Wind pennant",pivot:[0,deck+kind.mastHeight+0.2,mastZ])
    for i in 0..<6 { pennant.box([0.035,0.30*(1-Float(i)/6),0.1],[0,0,Float(i)*0.1],7) }
    if kind == .catamaran {
      hull.boxes = hull.boxes.flatMap { b in
        if b.center.y>deck-0.08 {return [b]}
        return [-1,1].map { side in
          ActorBox(b.size*[0.30,1,1],b.center*[0.30,1,1]+[Float(side)*beam*0.34,0,0],b.color)
        }
      }
      hull.box([beam*0.8,0.12,length*0.56],[0,deck-0.08,length*0.04],0)
    }
    if kind == .cutter {
      hull.box([0.15,0.15,length*0.22],[0,deck+0.3,-length*0.52],2)
      for i in 0..<18 {
        let t=(Float(i)+0.5)/18
        jib.box([0.03,0.4,(1-t)*1.5],[0,t*7,-1.9+t*2.3],9)
      }
    }
    return [hull,mainsail,jib,rudder,pennant]
  }
  private static func powerParts(_ kind:BoatKind)->[VehicleModelPart] {
    let l=kind.length,b=kind.beam,d=kind.freeboard
    var hull=VehicleModelPart(name:"Hull")
    let count=kind == .megaYacht ? 100:40
    for i in 0..<count {
      let t=(Float(i)+0.5)/Float(count),z=(t-0.5)*l
      let width=b*(t<0.3 ? max(0.12,sqrt(t/0.3)):1-0.15*pow((t-0.3)/0.7,2))
      hull.box([width,0.3,l/Float(count)],[0,-0.05,z],kind == .jetSki ? 7:1)
      hull.box([width*0.85,d+0.15,l/Float(count)],[0,d/2,z],0)
      hull.box([width*0.9,0.06,l/Float(count)],[0,d+0.06,z],2)
    }
    if kind == .jetSki {
      hull.box([0.40,0.25,1.45],[0,0.57,0.3],3)
      hull.box([0.65,0.06,0.08],[0,0.84,-0.50],3)
      hull.box([0.1,0.3,0.1],[0,0.68,-0.55],8)
    } else if kind == .motorboat {
      hull.box([b*0.7,0.25,0.9],[0,d+0.15,0.8],4)
      hull.box([b*0.8,0.4,0.12],[0,d+0.36,-0.25],6)
      hull.box([0.5,0.8,0.7],[0,-0.05,l*0.53],3)
      hull.box([0.09,0.6,0.09],[0.45,d+0.3,0.1],8)
    } else {
      // Three stepped decks, a raised bridge, aft lounge and rooftop pool.
      for level in 0..<3 {
        let y=d+Float(level)*2.0, length=l*(0.62-Float(level)*0.12)
        hull.box([b*0.74,1.6,length],[0,y+0.8,-l*0.10],0)
        hull.box([b*0.75,0.65,length*0.91],[0,y+1.04,-l*0.10],6)
        hull.box([b*0.85,0.18,length+1.8],[0,y+1.7,-l*0.10],0)
      }
      // Open bridge above the upper forward glazing; no opaque panel at eye level.
      hull.box([b*0.36,0.6,1.1],[0,d+6.3,-l*0.17],3)
      hull.box([b*0.42,0.25,l*0.12],[0,d+0.6,l*0.32],5)
      for side:Float in [-1,1] {
        hull.box([1.0,0.35,l*0.14],[side*b*0.32,d+0.5,l*0.3],4)
        for j in 0..<16 {hull.box([0.055,0.9,0.055],[side*b*0.45,d+0.5,-l*0.3+Float(j)*l*0.05],8)}
        hull.box([0.04,0.04,l*0.76],[side*b*0.45,d+0.95,l*0.05],8)
      }
      hull.box([0.15,3,0.15],[0,d+6.8,l*0.08],8)
      hull.box([2,0.18,0.25],[0,d+8,l*0.08],0)
    }
    return [hull]
  }
}

public actor BoatMeshPreparation {
  public static let shared=BoatMeshPreparation()
  private var cache:[BoatKind:PreparedVehicleModel]=[:]
  public func prepare(_ kind:BoatKind)->PreparedVehicleModel {
    if let result=cache[kind] {return result}
    let parts=BoatModel.parts(for:kind)
    let meshes=parts.map { part in
      var mesh=VoxelMesh()
      for b in part.boxes { mesh.appendBox(size:b.size,center:b.center,material:UInt32(b.color)) }
      return PackedTerrainMesh(ActorPalette.textured(mesh))
    }
    let result=PreparedVehicleModel(parts:parts,meshes:meshes);cache[kind]=result;return result
  }
}
