import Foundation

public enum HayHay {
  public static let personality = "Hay Hay is a gentle enchanted stuffed donkey: soft grey fur, cream belly and muzzle, long ears and a pale blue bandana. Friendly, curious and affectionate. Lives in the upper sanctuary of Hay Hay's Castle until the player finds and befriends them. Enjoy petting, flowers and grass, remember kindness, follow a friend without crowding, and return to the castle to rest. Never hunt, attack, speak or craft."
  public static func id(in castle: WorldLandmark) -> UInt64 { castle.id ^ 0x4841595F48415921 }
  public static func spawn(in castle: WorldLandmark, position: SIMD3<Float>? = nil, block: (BlockPosition) -> Block) -> AnimalState? {
    let point = position ?? castle.petHome
    guard castle.kind == .castle, AnimalKind.hayHay.canStand(at:point,juvenile:false,block:block) else { return nil }
    let id = id(in:castle)
    return .init(id:id,kind:.hayHay,home:castle.petHome,position:point,heading:.pi,bond:.init(id:id))
  }
}

/// Reference-inspired, entirely solid voxel sculpture. Small layered tufts give
/// the grey plush a soft silhouette; the ivory tummy stays broad and rounded.
public enum HayHaySculpture {
  public static let colors: [SIMD3<Float>] = [
    [0.58,0.60,0.61], [0.72,0.74,0.74], [0.88,0.88,0.85], [0.98,0.95,0.86],
    [0.91,0.87,0.77], [0.12,0.12,0.13], [0.66,0.84,0.86], [0.82,0.92,0.92],
    [0.58,0.60,0.61], [0.72,0.74,0.74], [0.88,0.88,0.85], [0.98,0.95,0.86],
    [0.91,0.87,0.77], [0.12,0.12,0.13], [0.66,0.84,0.86], [0.82,0.92,0.92]
  ]
  public static func make(juvenile: Bool = false) -> ActorSculpture {
    var body = ActorPart(.body)
    var head = ActorPart(.head,at:[0,0.68,-0.04])
    var eyes = ActorPart(.eyes,at:[0,0.04,-0.19])
    var mouth = ActorPart(.mouth,at:[0,-0.105,-0.24])
    var tail = ActorPart(.tail,at:[0,0.22,0.20])
    var legs = (0..<4).map { ActorPart([ActorJoint.limb0,.limb1,.limb2,.limb3][$0]) }
    body.box([0.43,0.40,0.34],[0,0.35,0],0)
    body.box([0.48,0.30,0.29],[0,0.30,-0.03],1)
    // Cream cloth tummy with folds and a rounded lower hem.
    body.box([0.43,0.36,0.045],[0,0.32,-0.185],3)
    body.box([0.37,0.45,0.05],[0,0.32,-0.19],3)
    for i in 0..<4 { body.box([0.30-Float(i%2)*0.04,0.02,0.025],[0,0.17+Float(i)*0.085,-0.221],4) }
    head.box([0.38,0.34,0.33],[0,0,0],1)
    head.box([0.33,0.39,0.31],[0,0.015,0],1)
    head.box([0.30,0.185,0.11],[0,-0.105,-0.195],3)
    head.box([0.25,0.22,0.11],[0,-0.105,-0.198],3)
    for side: Float in [-1,1] {
      // Long upright ears, wider toward the tips, with ivory inner panels.
      head.box([0.105,0.23,0.095],[side*0.14,0.265,0.01],1)
      head.box([0.105,0.15,0.09],[side*0.19,0.41,0.01],1)
      head.box([0.065,0.19,0.018],[side*0.145,0.275,-0.045],3)
      head.box([0.066,0.12,0.018],[side*0.19,0.41,-0.04],3)
      eyes.box([0.037,0.048,0.028],[side*0.10,0,0],5)
      eyes.box([0.010,0.013,0.032],[side*0.10-0.007,0.012,-0.003],2)
      head.box([0.017,0.029,0.012],[side*0.072,-0.10,-0.257],5)
      mouth.box([0.035,0.012,0.016],[side*0.055,-0.055,-0.025],5)
      mouth.box([0.013,0.024,0.016],[side*0.073,-0.041,-0.024],5)
    }
    mouth.box([0.09,0.012,0.016],[0,-0.062,-0.025],5)
    // Fur stays bounded (72 tuft boxes) and shares one palette material/joint.
    for i in 0..<18 {
      let x = Float(i%6-3)*0.057+0.025, y = Float(i/6)*0.072+0.09
      head.box([0.043,0.059,0.020],[x,y,-0.174],i%3)
      head.box([0.052,0.064,0.020],[x,y-0.21,0.17],i%3)
      for side: Float in [-1,1] {
        body.box([0.021,0.058,0.043],[side*0.228,0.20+Float(i%6)*0.048,Float(i/6-1)*0.095],i%3)
      }
    }
    for i in 0..<4 {
      let side: Float = i%2 == 0 ? -1 : 1
      let arm = i >= 2
      legs[i].pivot = [side*(arm ? 0.25 : 0.17),arm ? 0.49 : 0.11,arm ? 0 : -0.015]
      legs[i].box(arm ? [0.13,0.22,0.15] : [0.19,0.15,0.24],arm ? [side*0.025,-0.04,0] : [0,-0.03,-0.035],1)
      legs[i].box(arm ? [0.09,0.10,0.019] : [0.14,0.08,0.02],arm ? [side*0.025,-0.08,-0.084] : [0,-0.035,-0.164],3)
    }
    body.box([0.35,0.055,0.34],[0,0.54,0],6)
    for i in 0..<4 { body.box([0.32-Float(i)*0.065,0.055,0.021],[0,0.51-Float(i)*0.048,-0.20],6) }
    body.box([0.048,0.035,0.022],[-0.04,0.46,-0.219],7)
    tail.box([0.055,0.22,0.055],[0,-0.07,0.03],0)
    tail.box([0.095,0.10,0.095],[0,-0.19,0.03],1)
    if juvenile { head.boxes = head.boxes.map { .init($0.size*1.08,$0.center*1.08,$0.color) } }
    return .init(name:"Hay Hay",key:"hay-hay-plush-v1-\(juvenile)",colors:colors,parts:[body,head,eyes,mouth]+legs+[tail])
  }
}
