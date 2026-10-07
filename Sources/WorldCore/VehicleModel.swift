import Foundation

public struct VehicleModelPart: Sendable {
  public let name: String
  public var pivot: SIMD3<Float> = .zero
  public var boxes: [ActorBox] = []
  mutating func box(_ size: SIMD3<Float>, _ center: SIMD3<Float>, _ material: Int) {
    boxes.append(.init(size, center, material))
  }
}
public struct PreparedVehicleModel: Sendable {
  public let parts: [VehicleModelPart]
  public let meshes: [PackedTerrainMesh]
}

/// 2–5 cm voxel details on shared body panels, rather than terrain-sized cubes.
/// All positions are metres; the collision profile remains in world blocks.
public enum VehicleModel {
  public static func parts(for kind: VehicleKind) -> [VehicleModelPart] {
    let w = WorldScale.metres(kind.halfWidth), l = WorldScale.metres(kind.halfLength)
    let h = WorldScale.metres(kind.height), axle = WorldScale.metres(kind.wheelbase / 2)
    var body = VehicleModelPart(name: "Body"), windows = VehicleModelPart(name: "Windows")
    let front: Float = -0.43, back: Float = kind == .pickup ? 0.20 : kind == .compact ? l-0.15 : l-0.29
    let roof = h - 0.045, belt = h*0.55, seat = WorldScale.metres(kind.seatHeight)
    // Low chassis leaves the wheel wells open; side panels stop at each arch.
    body.box([w*1.70,0.13,l*1.85], [0,0.31,0], 2)
    body.box([w*1.76,0.17,l*1.94], [0,0.41,0], 0)
    for side: Float in [-1,1] {
      body.box([0.055,0.10,l*1.89], [side*(w-0.042),0.47,0], 0)
      body.box([0.045,belt-0.52,max(0.1,axle*2-0.45)], [side*(w-0.04),(belt+0.52)/2,0], 0)
      body.box([0.025,0.022,l*1.82], [side*(w-0.007),belt-0.015,0], kind == .luxury ? 4:7)
      // Stepped arch lips follow the tyres with small, solid voxels.
      for z in [-axle,axle] { for i in -5...5 {
        let dz=Float(i)*0.045, y=0.25+sqrt(max(0,0.26*0.26-dz*dz))
        body.box([0.065,0.055,0.045],[side*(w-0.028),y,z+dz],0)
      } }
      for z in [front,back] {
        body.box([0.045,roof-belt,0.05],[side*(w-0.062),(roof+belt)/2,z],0)
      }
      let cabinMid=(front+back)/2
      if kind != .pickup { body.box([0.035,roof-belt,0.055],[side*(w-0.06),(roof+belt)/2,cabinMid],7) }
      if kind != .deliveryVan {
        windows.box([0.018,roof-belt-0.065,back-front-0.05],[side*(w-0.057),(roof+belt)/2,cabinMid],1)
      } else {
        windows.box([0.018,roof-belt-0.075,0.56],[side*(w-0.057),(roof+belt)/2,front+0.31],1)
        body.box([0.045,roof-belt,max(0.1,back-front-0.64)],[side*(w-0.057),(roof+belt)/2,(front+0.64+back)/2],0)
        // Cargo-door seams, utility stripe and inset latch.
        body.box([0.020,roof-0.57,0.014],[side*(w-0.020),(roof+0.57)/2,0.40],7)
        body.box([0.022,0.09,l*1.5],[side*(w-0.018),0.62,0.12],8)
      }
      for z in [Float(0.05),back-0.10] where z > front && z < back {
        body.box([0.026,belt-0.44,0.013],[side*(w-0.009),(belt+0.44)/2,z],7)
        body.box([0.032,0.025,0.10],[side*(w-0.019),belt-0.075,z-0.075],4)
      }
      // Mirrors stay within the physical width of the car.
      body.box([0.07,0.045,0.04],[side*(w-0.04),belt+0.075,front+0.10],0)
      body.box([0.012,0.035,0.043],[side*(w-0.001),belt+0.075,front+0.115],4)
      body.box([w*0.62,0.13,0.39],[side*w*0.43,seat-0.45,0.23],6)
      body.box([w*0.64,0.37,0.10],[side*w*0.43,seat-0.29,0.43],6)
      body.box([w*0.35,0.09,0.085],[side*w*0.43,seat-0.055,0.43],6)
      for stitch in 0..<5 { body.box([w*0.5,0.008,0.012],[side*w*0.43,seat-0.43+Float(stitch)*0.055,0.373],kind == .luxury ? 4:7) }
    }
    body.box([w*1.82,0.05,back-front+0.09],[0,roof,(back+front)/2],0)
    // Layered bonnet contours and bumper bevels catch light at fine voxel steps.
    let hoodSteps=max(1,Int(ceil((l+front-0.04)/0.04)))
    for i in 0..<hoodSteps {
      let f=Float(i)/Float(hoodSteps), z = -l+0.04+Float(i)*0.04
      let width=w*1.84 - (1-f)*(kind.sporting ? 0.16:0.07)
      body.box([width,0.045,0.04],[0,belt-0.04-(1-f)*(kind.sporting ? 0.11:0.055),z],0)
    }
    for end: Float in [-1,1] {
      body.box([w*1.75,0.075,0.045],[0,0.36,end*(l-0.045)],kind == .luxury ? 4:7)
      body.box([0.22,0.065,0.018],[0,0.46,end*(l-0.014)],4)
      for side: Float in [-1,1] {
        for row in 0..<2 { for column in 0..<4 {
          body.box([0.034,0.024,0.024],[side*(w*0.52+Float(column)*0.036),belt-0.12+Float(row)*0.03,end*(l-0.014)],end<0 ? 3:5)
        } }
      }
    }
    for i in -5...5 {
      body.box([kind == .luxury ? 0.018:0.032,0.105,0.025],[Float(i)*0.035,belt-0.13,-l+0.008],kind == .luxury ? 4:7)
    }
    for i in 0..<6 {
      let y=belt+0.032+Float(i)*(roof-belt-0.07)/6
      windows.box([w*1.73,(roof-belt-0.06)/6,0.016],[0,y,front-0.025],1)
    }
    if kind != .deliveryVan { windows.box([w*1.70,roof-belt-0.06,0.018],[0,(roof+belt)/2,back+0.022],1) }
    if kind == .pickup {
      let bedLength=l-back-0.12, mid=(back+l-0.12)/2
      body.box([w*1.71,0.035,bedLength],[0,0.53,mid],7)
      for side: Float in [-1,1] { body.box([0.06,0.29,bedLength],[side*(w-0.06),0.67,mid],0) }
      body.box([w*1.8,0.29,0.05],[0,0.67,l-0.08],0)
      for z in stride(from: back+0.08, through:l-0.18, by:0.12) { body.box([w*1.5,0.017,0.021],[0,0.56,z],4) }
      // Toolbox and strapped construction timber distinguish the work truck.
      body.box([w*1.45,0.20,0.21],[0,0.66,back+0.18],4)
      for x: Float in [-0.11,0,0.11] { body.box([0.09,0.08,bedLength*0.65],[x,0.60,mid+0.12],6) }
    } else if kind == .deliveryVan {
      body.box([w*1.84,roof-0.52,0.055],[0,(roof+0.52)/2,l-0.10],0)
      body.box([0.014,roof-0.54,0.022],[0,(roof+0.54)/2,l-0.062],7)
      for side: Float in [-1,1] { body.box([0.025,0.12,0.025],[side*0.055,0.81,l-0.04],4) }
      // A roof rack and ladder, built from slim voxel rungs.
      for x: Float in [-w*0.55,w*0.55] { body.box([0.025,0.025,l*1.14],[x,h-0.015,0.15],4) }
      for z in stride(from:-l*0.45,through:l*0.6,by:0.14) { body.box([w*1.15,0.024,0.025],[0,h-0.014,z],4) }
    } else {
      let rearLength=max(0.10,l-back-0.05)
      body.box([w*1.8,0.06,rearLength],[0,belt-0.055,back+rearLength/2],0)
      if kind == .compact { for i in 0..<5 { body.box([w*1.80,0.038,0.04],[0,belt+Float(i)*0.052,l-0.10-Float(i)*0.033],0) } }
    }
    if kind.sporting {
      body.box([w*1.91,0.026,0.19],[0,0.30,-l+0.11],7)
      for side: Float in [-1,1] {
        body.box([0.034,0.24,0.044],[side*w*0.64,belt+0.07,l-0.18],4)
        body.box([0.06,0.015,0.38],[side*0.14,belt-0.025,-l*0.67],3)
        body.box([0.06,0.012,back-front],[side*0.14,roof+0.03,(back+front)/2],3)
      }
      body.box([w*1.94,0.035,0.16],[0,belt+0.20,l-0.18],kind == .race ? 0:7)
    }
    body.box([w*1.66,0.075,0.12],[0,seat-0.35,front+0.08],7)
    for i in 0..<4 { body.box([0.018,0.025,0.015],[-w*0.40+Float(i)*0.025,seat-0.30,front+0.14],8) }
    // Lower, smaller and further from the eye: the road occupies the view,
    // while the physical wheel remains visible when looking down at the dash.
    var steering = VehicleModelPart(name:"Steering wheel",pivot:[-w*0.41,seat-0.30,front+0.12])
    for y: Float in [-0.07,0.07] { steering.box([0.14,0.015,0.015],[0,y,0],2) }
    for x: Float in [-0.07,0.07] { steering.box([0.015,0.14,0.015],[x,0,0],2) }
    steering.box([0.13,0.018,0.018],.zero,4)
    var parts=[body,windows,steering]
    for side in 0..<2 { for front in 0..<2 {
      let sign: Float=side == 0 ? -1:1
      var wheel=VehicleModelPart(name:"\(front == 0 ? "Front" : "Rear") wheel \(side)",pivot:[sign*(w-0.09),0.24,front == 0 ? -axle:axle])
      for row in -6...6 {
        let y=Float(row)*0.032, depth=(sqrt(max(0,0.208*0.208-y*y))/0.025).rounded(.down)*0.05
        wheel.box([0.17,0.032,max(0.05,depth)],[0,y,0],2)
      }
      // Small stepped hubs, spokes and lug nuts remain solid voxel geometry.
      for row in -3...3 {
        let y=Float(row)*0.027, depth=sqrt(max(0,0.10*0.10-y*y))*2
        wheel.box([0.018,0.027,max(0.025,depth)],[sign*0.091,y,0],4)
      }
      for i in 0..<8 {
        let angle=Float(i) * .pi / 4, y=sin(angle)*0.075, z=cos(angle)*0.075
        wheel.box([0.019,0.022,0.022],[sign*0.105,y,z],7)
      }
      parts.append(wheel)
    } }
    return parts
  }
}

/// Shared immutable geometry prepared away from the scene/update executor.
public actor VehicleMeshPreparation {
  public static let shared = VehicleMeshPreparation()
  private var cache: [VehicleKind:PreparedVehicleModel] = [:]
  public func prepare(_ kind: VehicleKind) -> PreparedVehicleModel {
    if let cached=cache[kind] { return cached }
    let parts=VehicleModel.parts(for:kind)
    let meshes=parts.map { part in
      var mesh=VoxelMesh()
      for box in part.boxes { mesh.appendBox(size:box.size,center:box.center,material:UInt32(box.color)) }
      return PackedTerrainMesh(mesh)
    }
    let result=PreparedVehicleModel(parts:parts,meshes:meshes); cache[kind]=result
    return result
  }
}
