import Foundation

/// Persistent identity, rather than job or skin tone, seeds every independent trait.
public struct ResidentAppearance: Hashable, Sendable {
  public let role: ResidentRole
  public let habitat: SettlementHabitat
  public let skin: Int, hairColor: Int, hairstyle: Int, build: Int
  public let outfit: Int, feature: Int, accessory: Int, age: Int
  public init(id: UInt64, role: ResidentRole, habitat: SettlementHabitat) {
    self.role = role; self.habitat = habitat
    var random = AppearanceRandom(id ^ 0x5045_4F50_4C45)
    skin = random.pick(8); hairColor = random.pick(8); hairstyle = random.pick(7)
    build = random.pick(3); outfit = random.pick(4); feature = random.pick(5)
    accessory = random.pick(4); age = random.pick(4)
  }
}

public enum ResidentSculpture {
  public static func make(_ look: ResidentAppearance) -> ActorSculpture {
    if look.habitat == .solar {return sunDweller(look)}
    let width: Float = [0.34, 0.42, 0.52][look.build]
    let height: Float = [0.92, 1, 1.035][look.build]
    var body = ActorPart(.body)
    var head = ActorPart(.head, at: [0, 1.48, 0])
    var eyes = ActorPart(.eyes, at: [0, 0.028, -0.156])
    var mouth = ActorPart(.mouth, at: [0, -0.108, -0.157])
    var prop = ActorPart(.prop, at: [0, -0.47, -0.12])
    var arms = [ActorPart(.limb0), ActorPart(.limb1)]
    var legs = [ActorPart(.limb2), ActorPart(.limb3)]
    body.box([width, 0.43, 0.24], [0, 1.08, 0], 1)
    body.box([width * 0.9, 0.20, 0.26], [0, 0.84, 0], 1)
    body.box([0.15, 0.13, 0.15], [0, 1.35, 0], 0)
    // Collar, cuffs, belt, buckle and pockets give clothing actual voxel relief.
    for side: Float in [-1, 1] {
      body.box([0.12, 0.065, 0.035], [side * 0.075, 1.265, -0.133], 4)
      body.box([0.075, 0.075, 0.025], [side * width * 0.30, 0.98, -0.139], 11)
      body.box([0.075, 0.013, 0.031], [side * width * 0.30, 1.02, -0.141], 4)
    }
    body.box([width * 0.93, 0.055, 0.272], [0, 0.795, 0], 8)
    body.box([0.065, 0.045, 0.024], [0, 0.795, -0.151], 6)
    for y: Float in [1.18, 1.095, 1.01] { body.box([0.021, 0.021, 0.024], [0, y, -0.136], 6) }
    if look.outfit == 1 || look.role == .scholar {
      body.box([width * 0.94, 0.24, 0.27], [0, 0.70, 0], 1)
      body.box([width, 0.045, 0.28], [0, 0.588, 0], 11)
    }
    if look.outfit == 3 && ![.builder, .guard].contains(look.role) {
      body.box([width * 0.94, 0.24, 0.28], [0, 0.66, 0], 1)
      body.box([width * 1.03, 0.17, 0.31], [0, 0.475, 0], 1)
      body.box([width * 1.08, 0.041, 0.32], [0, 0.377, 0], 11)
      for side: Float in [-1, 1] { body.box([0.022, 0.33, 0.013], [side * width * 0.31, 0.57, -0.164], 11) }
    }
    if [.farmer, .baker, .builder, .gardener].contains(look.role) {
      body.box([width * 0.67, 0.39, 0.028], [0, 0.99, -0.158], 4)
      body.box([width * 0.67, 0.023, 0.035], [0, 0.805, -0.16], 11)
      body.box([0.15, 0.10, 0.026], [0, 0.94, -0.182], 11)
      for side: Float in [-1, 1] { body.box([0.036, 0.26, 0.032], [side * width * 0.26, 1.15, -0.148], 4) }
    }
    if look.role == .guard {
      body.box([width * 0.92, 0.28, 0.04], [0, 1.13, -0.145], 14)
      body.box([0.045, 0.20, 0.048], [0, 1.13, -0.15], 6)
      body.box([0.19, 0.045, 0.05], [0, 1.16, -0.155], 6)
    }
    if look.accessory == 2 || look.role == .merchant {
      for i in 0..<5 { body.box([0.063, 0.10, 0.031], [width * (Float(i) / 5 - 0.4), 1.25 - Float(i) * 0.09, -0.171], 8) }
      body.box([0.16, 0.20, 0.13], [width * 0.56, 0.82, 0.01], 8)
      body.box([0.18, 0.055, 0.145], [width * 0.56, 0.9, 0.01], 11)
      body.box([0.035, 0.038, 0.02], [width * 0.56, 0.88, -0.072], 6)
    }
    if look.accessory == 3 || look.role == .musician {
      body.box([0.19, 0.065, 0.20], [0, 1.33, 0], 11)
      body.box([0.09, 0.23, 0.035], [0.055, 1.19, -0.171], 11)
    }
    head.box([0.285, 0.285, 0.278], [0, 0.008, 0], 0)
    head.box([0.245, 0.12, 0.248], [0, -0.098, -0.012], 0)
    for side: Float in [-1, 1] {
      head.box([0.035, 0.10, 0.085], [side * 0.154, -0.006, 0.007], 0)
      head.box([0.018, 0.048, 0.05], [side * 0.172, -0.016, -0.008], 10)
      eyes.box([0.067, 0.047, 0.015], [side * 0.071, 0, 0], 5)
      eyes.box([0.032, 0.042, 0.021], [side * 0.067, -0.001, -0.01], 12)
      eyes.box([0.016, 0.031, 0.026], [side * 0.067, -0.003, -0.012], 7)
      eyes.box([0.010, 0.015, 0.031], [side * 0.067 + 0.007, 0.011, -0.013], 5)
      head.box([0.077, 0.019, 0.016], [side * 0.071, 0.078, -0.148], 3)
      if look.feature == 0 {
        for j in 0..<3 { head.box([0.010, 0.009, 0.012], [side * (0.084 + Float(j) * 0.016), -0.035 + Float(j % 2) * 0.009, -0.149], 10) }
      }
      if look.age == 3 { head.box([0.049, 0.009, 0.014], [side * 0.08, -0.012, -0.147], 10) }
    }
    head.box([look.feature == 1 ? 0.062 : 0.043, 0.074, 0.061], [0, -0.031, -0.158], 0)
    mouth.box([0.074, 0.019, 0.013], .zero, 10)
    if look.feature >= 3 {
      head.box([0.168, look.feature == 4 ? 0.095 : 0.036, 0.025], [0, -0.119, -0.144], 3)
      for side: Float in [-1, 1] { head.box([0.032, 0.073, 0.026], [side * 0.113, -0.077, -0.147], 3) }
      head.box([0.080, 0.016, 0.023], [0, -0.083, -0.167], 3)
    }
    // Seven distinct silhouettes, rather than swapping one hair block's color.
    if look.hairstyle != 6 {
      head.box([0.307, 0.075, 0.298], [0, 0.171, 0.009], 3)
      head.box([0.301, 0.19, 0.06], [0, 0.084, 0.134], 3)
    }
    switch look.hairstyle {
    case 0:
      head.box([0.21, 0.057, 0.06], [-0.046, 0.117, -0.135], 3)
      head.box([0.08, 0.055, 0.25], [0.11, 0.206, 0.01], 3)
    case 1:
      head.box([0.29, 0.032, 0.289], [0, 0.217, 0], 9)
    case 2:
      for x: Float in [-0.12, -0.04, 0.04, 0.12] { for z: Float in [-0.10, 0, 0.10] {
        head.box([0.085, 0.080, 0.09], [x, 0.214 + (abs(z) < 0.05 ? 0.02 : 0), z], abs(x) < 0.05 ? 9 : 3)
      } }
    case 3:
      for side: Float in [-1, 1] { head.box([0.063, 0.26, 0.267], [side * 0.151, 0.041, 0.029], 3) }
      head.box([0.19, 0.062, 0.043], [-0.04, 0.112, -0.139], 3)
    case 4:
      for i in 0..<5 { head.box([0.072, 0.095, 0.08], [Float(i % 2) * 0.028, 0.08 - Float(i) * 0.075, 0.188], i % 2 == 0 ? 3 : 9) }
      head.box([0.077, 0.024, 0.085], [0, -0.20, 0.188], 11)
    case 5:
      head.box([0.11, 0.09, 0.13], [0, 0.131, 0.215], 3)
      head.box([0.10, 0.24, 0.085], [0, 0.022, 0.25], 3)
      head.box([0.113, 0.032, 0.09], [0, 0.094, 0.224], 11)
    default:
      for side: Float in [-1, 1] { head.box([0.022, 0.135, 0.23], [side * 0.151, 0.072, 0.016], 3) }
      head.box([0.27, 0.065, 0.03], [0, 0.105, 0.151], 3)
    }
    if look.accessory == 1 || look.role == .scholar {
      for side: Float in [-1, 1] {
        for y: Float in [-0.006, 0.063] { head.box([0.096, 0.012, 0.017], [side * 0.071, y, -0.191], 6) }
        for dx: Float in [-0.048, 0.048] { head.box([0.012, 0.076, 0.017], [side * 0.071 + dx, 0.028, -0.191], 6) }
        head.box([0.014, 0.014, 0.20], [side * 0.15, 0.052, -0.095], 6)
      }
      head.box([0.047, 0.011, 0.021], [0, 0.04, -0.192], 6)
    }
    switch look.role {
    case .farmer, .gardener:
      if look.outfit != 3 {
        head.box([0.46, 0.043, 0.40], [0, 0.261, 0], 6)
        head.box([0.30, 0.12, 0.275], [0, 0.335, 0], 6)
        head.box([0.31, 0.035, 0.285], [0, 0.30, 0], 11)
      }
      prop.box([0.032, 0.45, 0.032], [0, 0.09, 0], 8)
      prop.box([0.19, 0.025, 0.075], [0.055, 0.30, 0], 14)
      if look.role == .gardener { for x: Float in [-0.018, 0.044, 0.105] { prop.box([0.025, 0.080, 0.025], [x, 0.27, -0.027], 14) } }
    case .baker:
      head.box([0.33, 0.075, 0.31], [0, 0.244, 0], 4)
      for x: Float in [-0.102, 0, 0.102] { head.box([0.112, 0.13, 0.29], [x, 0.341, 0], 4) }
      prop.box([0.27, 0.025, 0.18], [0, 0, -0.02], 14)
      prop.box([0.19, 0.068, 0.12], [0, 0.038, -0.025], 6)
      for x: Float in [-0.055, 0, 0.055] { prop.box([0.012, 0.012, 0.10], [x, 0.077, -0.025], 4) }
    case .builder:
      head.box([0.36, 0.04, 0.35], [0, 0.235, -0.012], 6)
      head.box([0.32, 0.104, 0.30], [0, 0.302, 0], 6)
      head.box([0.044, 0.028, 0.29], [0, 0.365, 0], 11)
      prop.box([0.033, 0.26, 0.033], [0, 0.055, 0], 8)
      prop.box([0.19, 0.075, 0.077], [0.03, 0.19, 0], 14)
    case .guard:
      head.box([0.34, 0.085, 0.31], [0, 0.232, 0], 14)
      head.box([0.21, 0.045, 0.28], [0, 0.295, 0], 14)
      head.box([0.035, 0.06, 0.30], [0, 0.292, 0], 11)
      prop.box([0.032, 0.47, 0.032], [0, 0.05, 0], 8)
      prop.box([0.083, 0.12, 0.044], [0, 0.345, 0], 14)
    case .scholar:
      prop.box([0.18, 0.245, 0.055], [0, 0.07, 0], 11)
      prop.box([0.15, 0.215, 0.047], [0.019, 0.07, -0.014], 4)
      prop.box([0.025, 0.16, 0.012], [0.03, 0.105, -0.042], 6)
    case .musician:
      prop.box([0.17, 0.18, 0.064], [0, 0.005, 0], 8)
      prop.box([0.125, 0.13, 0.07], [0, 0.14, 0], 6)
      prop.box([0.038, 0.28, 0.032], [0, 0.29, 0], 8)
      for x: Float in [-0.009, 0.009] { prop.box([0.003, 0.44, 0.009], [x, 0.16, -0.041], 4) }
    case .merchant:
      prop.box([0.15, 0.20, 0.035], .zero, 11)
      prop.box([0.118, 0.163, 0.012], [0, 0, -0.022], 4)
      for y: Float in [-0.04, 0.01, 0.06] { prop.box([0.073, 0.009, 0.008], [0, y, -0.032], 8) }
    }
    for i in 0..<2 {
      let side: Float = i == 0 ? -1 : 1
      arms[i].pivot = [side * (width / 2 + 0.073), 1.25, 0]
      arms[i].box([0.135, 0.24, 0.16], [0, -0.11, 0], 1)
      arms[i].box([0.12, 0.20, 0.14], [0, -0.31, 0], look.outfit == 2 ? 0 : 1)
      arms[i].box([0.133, 0.05, 0.15], [0, -0.40, 0], 11)
      arms[i].box([0.118, 0.11, 0.135], [0, -0.474, -0.003], 0)
      arms[i].box([0.039, 0.060, 0.075], [-side * 0.071, -0.47, -0.016], 0)
      if look.role == .guard { arms[i].box([0.17, 0.087, 0.19], [0, 0.009, 0], 14) }
      legs[i].pivot = [side * width * 0.265, 0.73, 0]
      legs[i].box([width * 0.39, 0.36, 0.20], [0, -0.18, 0], 2)
      legs[i].box([width * 0.35, 0.28, 0.18], [0, -0.49, 0], 2)
      legs[i].box([width * 0.40, 0.16, 0.215], [0, -0.62, -0.01], 8)
      legs[i].box([width * 0.43, 0.09, 0.28], [0, -0.682, -0.036], 8)
      legs[i].box([width * 0.44, 0.025, 0.285], [0, -0.718, -0.038], 7)
    }
    if look.habitat == .aquatic {
      for side: Float in [-1, 1] {
        head.box([0.14, 0.18, 0.053], [side * 0.208, 0.008, 0.038], 13)
        head.box([0.086, 0.086, 0.054], [side * 0.22, 0.116, 0.042], 11)
        for y: Float in [-0.070, -0.041, -0.012] { head.box([0.014, 0.009, 0.072], [side * 0.15, y, -0.018], 13) }
      }
      body.box([0.045, 0.34, 0.21], [0, 1.08, 0.208], 13)
      for i in legs.indices { legs[i].box([0.23, 0.042, 0.32], [0, -0.695, -0.21], 13) }
      body.box([0.115, 0.10, 0.022], [0, 1.16, -0.20], 13)
    } else if look.habitat == .solar {
      for side: Float in [-1, 1] {
        body.box([0.14, 0.07, 0.28], [side * width * 0.43, 1.30, 0], 14)
        body.box([0.025, 0.27, 0.017], [side * width * 0.40, 1.10, -0.163], 13)
      }
      head.box([0.32, 0.016, 0.08], [0, 0.102, -0.18], 14)
      body.box([0.12, 0.10, 0.032], [0, 1.16, -0.20], 13)
    }
    var parts = [body, head, eyes, mouth] + arms + legs + [prop]
    for i in parts.indices {
      parts[i].pivot *= [0.78,height,0.90]
      parts[i].boxes = parts[i].boxes.map { .init($0.size * [0.78, height, 0.90], $0.center * [0.78, height, 0.90], $0.color) }
    }
    let key = "person-\(look.role.rawValue)-\(look.habitat.rawValue)-\(look.hairstyle)-\(look.build)-\(look.outfit)-\(look.feature)-\(look.accessory)-\(look.age == 3)"
    return .init(name: "Resident", key: key, colors: palette(look), parts: parts)
  }

  private static func sunDweller(_ look:ResidentAppearance)->ActorSculpture {
    // Living volcanic stone: no skin, hair, human nose, clothes or human eyes.
    // Articulated joints retain the shared jobs, memory and crowd navigation.
    var body=ActorPart(.body),head=ActorPart(.head,at:[0,1.43,0])
    var eyes=ActorPart(.eyes,at:[0,0.025,-0.17]),mouth=ActorPart(.mouth,at:[0,-0.11,-0.16])
    let glow=SIMD3<Float>(1,0.24+Float(look.outfit)*0.09,0.025)
    let colors:[SIMD3<Float>]=[[0.07,0.06,0.08],[0.19,0.12,0.10],glow,[0.39,0.18,0.09],[0.42,0.37,0.34]] + Array(repeating:glow,count:11)
    for n in 0..<5 {
      let y=Float(n)*0.115+0.81,w:Float=n==2 ? 0.39:0.34
      body.box([w,0.102,0.27],[0,y,0],n%2)
      body.box([0.025,0.012,0.285],[Float((n+look.feature)%3-1)*0.06,y-0.05,0],2)
    }
    body.box([0.13,0.17,0.12],[0,1.1,-0.14],2)
    head.box([0.29,0.25,0.29],[0,0,0],0)
    head.box([0.23,0.10,0.25],[0,0.15,0.01],1)
    for side:Float in [-1,1] {
      head.box([0.055,0.18,0.075],[side*0.10,0.24,0.02],1)
      head.box([0.035,0.065,0.050],[side*0.10,0.34,0.02],2)
    }
    eyes.box([0.235,0.036,0.028],.zero,2)
    eyes.box([0.031,0.072,0.035],[0,0,0],0)
    mouth.box([0.08,0.012,0.022],.zero,3)
    var parts=[body,head,eyes,mouth,ActorPart(.prop)]
    for i in 0..<4 {
      let arm=i<2,side:Float=i%2==0 ? -1:1
      var limb=ActorPart([ActorJoint.limb0,.limb1,.limb2,.limb3][i],at:[side*(arm ? 0.23:0.10),arm ? 1.20:0.74,0])
      for n in 0..<3 {limb.box([arm ? 0.12:0.16,0.19,0.18],[0,-Float(n)*0.20-0.11,0],n%2)
        limb.box([0.08,0.015,0.19],[0,-Float(n)*0.20-0.01,0],2)}
      limb.box([arm ? 0.13:0.18,0.13,arm ? 0.17:0.28],[0,-0.65,arm ? 0:-0.055],0)
      parts.append(limb)
    }
    return .init(name:"Sun dweller",key:"sun-dweller-\(look.feature)-\(look.build)",colors:colors,parts:parts)
  }

  private static func palette(_ look: ResidentAppearance) -> [SIMD3<Float>] {
    var skin: SIMD3<Float> = [[0.98,0.79,0.64],[0.87,0.64,0.46],[0.72,0.48,0.32],[0.54,0.33,0.22],
      [0.36,0.22,0.17],[0.92,0.71,0.58],[0.64,0.42,0.32],[0.43,0.28,0.22]][look.skin]
    if look.habitat == .aquatic { skin = [[0.32,0.77,0.72],[0.34,0.67,0.83],[0.57,0.57,0.85],[0.27,0.58,0.60]][look.skin % 4] }
    if look.habitat == .solar { skin = [[0.57,0.31,0.23],[0.39,0.31,0.29],[0.75,0.43,0.25],[0.32,0.26,0.27]][look.skin % 4] }
    var hair: SIMD3<Float> = [[0.12,0.10,0.11],[0.28,0.17,0.10],[0.52,0.28,0.12],[0.83,0.64,0.31],
      [0.67,0.25,0.12],[0.79,0.76,0.70],[0.42,0.39,0.37],[0.21,0.17,0.27]][look.hairColor]
    if look.age == 3 { hair = hair * 0.45 + SIMD3<Float>(repeating: 0.42) }
    let uniforms: [SIMD3<Float>] = [[0.30,0.57,0.27],[0.80,0.34,0.22],[0.23,0.46,0.69],[0.51,0.31,0.62],
      [0.19,0.60,0.51],[0.26,0.35,0.54],[0.63,0.32,0.25],[0.72,0.32,0.51]]
    let base = uniforms[ResidentRole.allCases.firstIndex(of: look.role) ?? 0]
    let shirt = base * [0.82,1,1.08,0.95][look.outfit] + (look.outfit == 2 ? SIMD3<Float>(repeating: 0.07) : .zero)
    let accent: SIMD3<Float> = [[0.94,0.64,0.24],[0.36,0.67,0.68],[0.87,0.44,0.29],[0.64,0.43,0.73]][look.outfit]
    let trousers: SIMD3<Float> = [[0.20,0.26,0.31],[0.39,0.31,0.23],[0.27,0.33,0.25],[0.33,0.24,0.33]][look.outfit]
    let leather: SIMD3<Float> = look.outfit == 2 ? [0.17,0.16,0.19] : [0.29,0.19,0.14]
    return [skin, shirt, trousers, hair, [0.91,0.85,0.70], [0.97,0.96,0.87],
      [0.83,0.62,0.27], [0.095,0.095,0.105], leather, hair * 0.78 + SIMD3<Float>(repeating: 0.12),
      skin * [0.80,0.57,0.55], accent, [[0.24,0.40,0.26],[0.27,0.42,0.60],[0.39,0.26,0.16],[0.38,0.32,0.46]][look.skin % 4],
      look.habitat == .solar ? [1,0.52,0.13] : [0.35,0.82,0.82], [0.49,0.58,0.63], [1,1,1]]
  }
}
