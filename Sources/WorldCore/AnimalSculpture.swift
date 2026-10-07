import Foundation

public struct AnimalAppearance: Hashable, Sendable {
  public let kind: AnimalKind
  public let coat: Int
  public let markings: Int
  public let shape: Int
  public let juvenile: Bool
  public init(kind: AnimalKind, id: UInt64, juvenile: Bool) {
    self.kind = kind; self.juvenile = juvenile
    var random = AppearanceRandom(id ^ 0x414E_494D_414C)
    coat = random.pick(6); markings = random.pick(4); shape = random.pick(3)
  }
}

public enum AnimalSculpture {
  private struct Proportions {
    var width: Float, legs: Float, height: Float, length: Float, face: Float, muzzle: Float
    init(_ w: Float, _ l: Float, _ h: Float, _ d: Float, _ f: Float, _ m: Float) {
      width = w; legs = l; height = h; length = d; face = f; muzzle = m
    }
  }
  public static func make(_ look: AnimalAppearance) -> ActorSculpture {
    let kind = look.kind
    if kind == .hayHay { return HayHaySculpture.make(juvenile: look.juvenile) }
    if kind == .dog { return DogSculpture.make(juvenile: look.juvenile) }
    var p: Proportions = switch kind {
    case .sheep: .init(0.66, 0.40, 0.54, 0.94, 0.31, 0.36)
    case .fox: .init(0.34, 0.41, 0.32, 0.78, 0.25, 0.36)
    case .deer: .init(0.46, 0.84, 0.47, 1.13, 0.28, 0.40)
    case .rabbit: .init(0.32, 0.16, 0.32, 0.47, 0.27, 0.23)
    case .cow: .init(0.73, 0.54, 0.65, 1.29, 0.43, 0.46)
    case .pig: .init(0.59, 0.29, 0.49, 0.96, 0.37, 0.40)
    case .horse, .zebra: .init(0.53, 0.83, 0.53, 1.24, 0.38, 0.55)
    case .goat: .init(0.39, 0.51, 0.43, 0.76, 0.27, 0.35)
    case .wolf: .init(0.43, 0.52, 0.47, 0.94, 0.32, 0.41)
    case .bear: .init(0.78, 0.43, 0.73, 1.18, 0.48, 0.40)
    case .chicken: .init(0.32, 0.20, 0.37, 0.40, 0.21, 0.19)
    case .duck: .init(0.36, 0.16, 0.35, 0.58, 0.24, 0.24)
    case .frog: .init(0.32, 0.08, 0.19, 0.39, 0.29, 0.20)
    case .parrot: .init(0.27, 0.14, 0.43, 0.31, 0.27, 0.23)
    case .camel: .init(0.63, 0.83, 0.55, 1.31, 0.32, 0.47)
    case .penguin: .init(0.38, 0.09, 0.65, 0.32, 0.29, 0.28)
    case .fish: .init(0.16, 0, 0.33, 0.56, 0.19, 0.18)
    case .panda: .init(0.77, 0.34, 0.70, 1.06, 0.51, 0.40)
    case .elephant: .init(1.15, 1.02, 1.13, 1.80, 0.76, 0.70)
    case .giraffe: .init(0.59, 1.03, 0.56, 1.18, 0.33, 0.46)
    case .tortoise: .init(0.55, 0.11, 0.36, 0.73, 0.19, 0.23)
    case .otter: .init(0.31, 0.12, 0.27, 0.78, 0.26, 0.28)
    case .boar: .init(0.62, 0.37, 0.53, 1.02, 0.38, 0.46)
    case .hayHay: .init(0.48, 0.15, 0.43, 0.34, 0.38, 0.39)
    case .dog: .init(0.32, 0.43, 0.31, 0.77, 0.275, 0.30) // Dedicated builder above.
    }
    if look.juvenile { p.legs *= 0.72; p.height *= 0.90; p.face *= 1.18; p.muzzle *= 0.85 }
    let bird = [.chicken, .duck, .parrot, .penguin].contains(kind)
    var body = ActorPart(.body)
    let middle = p.legs + p.height / 2
    var headHeight = p.legs + p.height * 0.88
    if [.deer, .horse, .zebra, .camel].contains(kind) { headHeight += 0.25 }
    if kind == .giraffe { headHeight += look.juvenile ? 0.62 : 1.11 }
    if bird { headHeight = p.legs + p.height + p.face * 0.27 }
    if kind == .fish { headHeight = p.height / 2 }
    var head = ActorPart(.head, at: [0, headHeight, -p.length * (bird ? 0.28 : 0.47)])
    var eyes = ActorPart(.eyes)
    var mouth = ActorPart(.mouth)
    var tail = ActorPart(.tail, at: [0, middle + p.height * 0.18, p.length * 0.46])
    var limbs = (0..<4).map { ActorPart([ActorJoint.limb0, .limb1, .limb2, .limb3][$0]) }
    let face = p.face, front = -p.muzzle * 0.68
    // Stepped shoulders and haunches soften the cuboid silhouette without
    // smoothing away the voxel edges. Fixed coat detail stays in these meshes.
    body.box([p.width, p.height * 0.78, p.length * 0.89], [0, middle, 0], 0)
    body.box([p.width * 0.79, p.height, p.length * 0.74], [0, middle, 0], 0)
    body.box([p.width * 0.73, p.height * 0.22, p.length * 0.73], [0, p.legs + p.height * 0.08, -0.025], 2)
    if headHeight > p.legs + p.height {
      let neck = headHeight - middle
      body.box([face * 0.82, neck, face * 0.91], [0, middle + neck / 2, -p.length * 0.37], 0)
      body.box([face * 0.65, neck * 0.91, 0.065], [0, middle + neck / 2, -p.length * 0.37 - face * 0.47], 2)
    }
    head.box([face, face * 0.79, p.muzzle * 0.73], [0, 0, -p.muzzle * 0.08], 0)
    head.box([face * 0.83, face, p.muzzle * 0.56], [0, 0.01, -p.muzzle * 0.03], 0)
    if !bird && kind != .fish && kind != .frog {
      head.box([face * 0.69, face * 0.40, p.muzzle * 0.57], [0, -face * 0.16, front * 0.63], 2)
      if ![.elephant, .tortoise].contains(kind) {
        let softNose = [.cow, .pig, .rabbit].contains(kind)
        head.box([face * (kind == .rabbit ? 0.21 : 0.40), face * 0.18, 0.048],
          [0, -face * 0.15, front - 0.008], softNose ? 10 : 3)
      }
      mouth.box([face * 0.58, 0.022, p.muzzle * 0.30], [0, -face * 0.35, front * 0.73], 1)
    }
    for side: Float in [-1, 1] {
      let eyeX = face * (bird || kind == .fish ? 0.51 : 0.34)
      let eyeZ = bird || kind == .fish ? -p.muzzle * 0.22 : -p.muzzle * 0.45 - 0.012
      if kind != .frog {
        eyes.box([face * 0.21, face * 0.20, 0.025], [side * eyeX, face * 0.10, eyeZ], 6)
        eyes.box([face * 0.115, face * 0.16, 0.031], [side * eyeX, face * 0.095, eyeZ - 0.015], 7)
        eyes.box([face * 0.044, face * 0.07, 0.035], [side * eyeX + 0.006, face * 0.12, eyeZ - 0.019], 6)
      }
      if !bird && ![.fish, .frog, .tortoise].contains(kind) {
        let earHeight: Float = kind == .rabbit ? 0.30 : kind == .elephant ? 0.68 : [.fox, .wolf].contains(kind) ? 0.22 : 0.14
        let earWidth: Float = kind == .elephant ? 0.40 : kind == .cow ? 0.21 : face * 0.32
        let position = SIMD3<Float>(side * face * (kind == .elephant ? 0.63 : 0.46),
          kind == .elephant ? -0.02 : face * 0.44 + earHeight * 0.29, 0.015)
        head.box([earWidth, earHeight, 0.07], position, [.panda, .bear].contains(kind) ? 8 : 0)
        head.box([earWidth * 0.57, earHeight * 0.66, 0.014], position + [0, -0.015, -0.044], kind == .elephant ? 1 : 10)
      }
    }
    for i in limbs.indices {
      let side: Float = i % 2 == 0 ? -1 : 1
      limbs[i].pivot = [side * p.width * 0.34, p.legs, (i < 2 ? -1 : 1) * p.length * 0.30]
      if kind == .fish {
        limbs[i].pivot = [side * p.width * 0.5, middle, i < 2 ? -0.08 : 0.14]
        limbs[i].box([0.17, 0.027, 0.14], [side * 0.065, 0, 0.045], 5)
      } else if bird && i >= 2 {
        limbs[i].pivot = [side * p.width * 0.49, p.legs + p.height * 0.86, 0]
        limbs[i].box([0.075, p.height * 0.70, p.length * 0.80], [side * 0.03, -p.height * 0.29, 0.045], kind == .parrot ? 11 : 1)
        limbs[i].box([0.068, p.height * 0.30, p.length * 0.44], [side * 0.037, -p.height * 0.65, 0.07], kind == .parrot ? 5 : 0)
      } else {
        let thickness = p.width * (kind == .elephant ? 0.30 : bird ? 0.13 : 0.25)
        limbs[i].box([thickness, p.legs * 0.70, thickness * 1.1], [0, -p.legs * 0.31, 0], kind == .panda ? 8 : 0)
        limbs[i].box([thickness * 0.75, p.legs * 0.48, thickness * 0.83], [0, -p.legs * 0.70, 0.015], bird ? 5 : kind == .panda ? 8 : 1)
        limbs[i].box([thickness * 1.08, max(0.045, p.legs * 0.12), thickness * (bird || kind == .rabbit ? 1.95 : 1.28)],
          [0, -p.legs + max(0.023, p.legs * 0.06), -thickness * 0.21], bird ? 5 : 9)
        if kind == .elephant || kind == .bear {
          for x: Float in [-0.25, 0.15] { limbs[i].box([thickness * 0.19, 0.04, 0.028],
            [x * thickness, -p.legs + 0.04, -thickness * 0.88], 4) }
        }
      }
    }
    switch kind {
    case .dog, .hayHay: break
    case .sheep:
      for side: Float in [-1, 1] { for z: Float in [-0.30, 0, 0.30] {
        body.box([0.22, 0.26, 0.25], [side * p.width * 0.43, middle + 0.06, z], 12)
        body.box([0.24, 0.12, 0.25], [side * 0.14, p.legs + p.height, z], 12)
      } }
      tail.box([0.16, 0.15, 0.17], [0, -0.03, 0.10], 12)
    case .fox, .wolf, .otter:
      let fluffy = kind == .fox
      for n in 0..<4 {
        let width = p.width * (fluffy ? 0.88 : kind == .wolf ? 0.52 : 0.62) * (1 - Float(n) * 0.19)
        tail.box([width, width, 0.22], [0, Float(n) * (fluffy ? 0.03 : -0.02), Float(n) * 0.17 + 0.10], fluffy && n > 1 ? 2 : 0)
      }
      body.box([p.width * 0.65, p.height * 0.65, 0.08], [0, middle + 0.10, -p.length * 0.47], 2)
      if kind == .otter { for side: Float in [-1, 1] {
        head.box([0.13, 0.012, 0.018], [side * 0.14, -0.045, front - 0.015], 4)
      } }
    case .cow:
      for side: Float in [-1, 1] {
        for n in 0..<3 {
          let z = Float(n - 1) * 0.30 + Float(look.markings % 2) * 0.04
          body.box([0.022, 0.20 + Float((n + look.markings) % 2) * 0.16, 0.18 + Float(n % 2) * 0.12],
            [side * p.width * 0.504, middle + (n % 2 == 0 ? 0.06 : -0.02), z], 8)
        }
        if !look.juvenile { head.box([0.065, 0.16, 0.065], [side * 0.24, 0.26, 0.03], 4) }
        head.box([0.06, 0.032, 0.02], [side * 0.09, -0.08, front - 0.036], 3)
      }
      tail.box([0.045, 0.45, 0.045], [0, -0.20, 0.10], 0)
      tail.box([0.09, 0.14, 0.08], [0, -0.41, 0.10], 8)
    case .horse, .zebra, .camel, .giraffe, .deer, .goat:
      if kind == .horse || kind == .zebra || kind == .giraffe {
        for n in 0..<5 { body.box([0.065, 0.13, 0.12], [0, p.legs + p.height + 0.035, -p.length * 0.34 + Float(n) * 0.12], 8) }
        body.box([0.07, headHeight - middle, 0.06], [0, (headHeight + middle) / 2, -p.length * 0.37 + face * 0.50], 8)
      }
      if kind == .camel {
        for z: Float in look.shape == 0 ? [0.04] : [-0.25, 0.23] {
          body.box([0.40, 0.26, 0.35], [0, p.legs + p.height + 0.11, z], 0)
          body.box([0.25, 0.13, 0.22], [0, p.legs + p.height + 0.29, z], 12)
        }
      }
      if kind == .zebra { for side: Float in [-1, 1] { for n in 0..<7 {
        body.box([0.018, p.height * (n % 2 == 0 ? 0.75 : 0.57), 0.045 + Float(look.markings % 2) * 0.01],
          [side * p.width * 0.504, middle + Float(n % 2) * 0.04, -p.length * 0.35 + Float(n) * 0.145], 8)
      } } }
      if kind == .giraffe || (kind == .deer && look.juvenile) {
        for side: Float in [-1, 1] { for n in 0..<6 {
          body.box([0.018, 0.11, 0.13], [side * p.width * 0.504, middle + (n % 2 == 0 ? 0.11 : -0.07), -0.40 + Float(n) * 0.15], kind == .deer ? 4 : 8)
        }
          if kind == .giraffe { for n in 0..<5 {
            body.box([0.018, 0.12, 0.12], [side * face * 0.42, middle + 0.3 + Float(n) * 0.21, -p.length * 0.37], 8)
          } }
        }
      }
      if !look.juvenile && [.deer, .goat, .giraffe].contains(kind) { for side: Float in [-1, 1] {
        let height: Float = kind == .deer ? 0.40 + Float(look.shape) * 0.06 : kind == .goat ? 0.24 : 0.19
        head.box([0.045, height, 0.052], [side * face * 0.40, face * 0.48 + height / 2, 0.01], kind == .giraffe ? 8 : 4)
        if kind == .deer { for n in 0..<(2 + look.shape) {
          let branchX = side * (face * 0.40 + 0.07 + Float(n) * 0.025)
          head.box([0.16 + Float(n) * 0.05, 0.038, 0.045], [branchX, face * 0.60 + Float(n) * 0.11, 0.01], 4)
          head.box([0.037, 0.09, 0.04], [side * (face * 0.40 + 0.14 + Float(n) * 0.05), face * 0.67 + Float(n) * 0.11, 0.01], 4)
        } }
      } }
      if kind == .goat { head.box([0.09, 0.15, 0.09], [0, -face * 0.46, front * 0.70], 2) }
      tail.box([0.055, 0.42, 0.055], [0, -0.17, 0.12], 0)
      tail.box([kind == .deer ? 0.12 : 0.10, kind == .horse || kind == .zebra ? 0.36 : 0.12, 0.10], [0, -0.34, 0.13], 8)
    case .pig, .boar:
      for side: Float in [-1, 1] { head.box([0.055, 0.042, 0.026], [side * 0.072, -0.065, front - 0.038], 3) }
      for n in 0..<3 { tail.box([0.045, 0.065, 0.06], [n % 2 == 0 ? 0 : 0.04, Float(n) * 0.034, 0.07 + Float(n) * 0.033], 10) }
      if kind == .boar {
        for n in 0..<5 { body.box([0.07, 0.12, 0.12], [0, p.legs + p.height + 0.01, Float(n - 2) * 0.16], 8) }
        if !look.juvenile { for side: Float in [-1, 1] { head.box([0.045, 0.17, 0.055], [side * 0.19, -0.03, front * 0.80], 4) } }
      }
    case .panda, .bear:
      for side: Float in [-1, 1] {
        if kind == .panda {
          head.box([0.17, 0.155, 0.03], [side * face * 0.34, face * 0.10, -p.muzzle * 0.45 + 0.004], 8)
          body.box([0.024, p.height * 0.73, 0.32], [side * p.width * 0.505, middle + 0.04, -p.length * 0.27], 8)
        }
        head.box([0.14, 0.10, 0.16], [side * face * 0.33, -0.13, front * 0.6], 2)
      }
      tail.box([0.18, 0.15, 0.15], [0, -0.02, 0.08], 0)
    case .elephant:
      // A stepped, articulated trunk and paired tusks make the silhouette read
      // from the front as well as the side. Juveniles have no adult tusks.
      for n in 0..<6 {
        let taper = 0.21 - Float(n) * 0.02
        mouth.box([taper, 0.22, taper], [0, -Float(n) * 0.18 - 0.18, front - 0.06 - Float(max(0, n - 3)) * 0.08], n % 2 == 0 ? 0 : 12)
      }
      if !look.juvenile { for side: Float in [-1, 1] {
        head.box([0.08, 0.10, 0.39], [side * 0.28, -0.30, front - 0.05], 4)
        head.box([0.07, 0.13, 0.13], [side * 0.28, -0.25, front - 0.24], 4)
      } }
      tail.box([0.07, 0.63, 0.07], [0, -0.26, 0.13], 0)
      tail.box([0.13, 0.18, 0.12], [0, -0.55, 0.13], 8)
    case .tortoise:
      body.box([p.width * 1.06, 0.11, p.length * 1.02], [0, p.legs + 0.04, 0], 4)
      for tier in 0..<3 {
        let inset = Float(tier) * 0.10
        body.box([p.width - inset, 0.12, p.length - inset], [0, p.legs + 0.12 + Float(tier) * 0.10, 0], tier % 2 == 0 ? 8 : 12)
      }
      for x: Float in [-0.11, 0.11] { for z: Float in [-0.22, 0, 0.22] {
        body.box([0.16, 0.018, 0.16], [x, p.legs + 0.355, z], 5)
      } }
      tail.box([0.05, 0.06, 0.15], [0, -0.16, 0.12], 0)
    case .rabbit:
      for i in [2, 3] { limbs[i].box([0.18, 0.22, 0.20], [0, 0.02, 0], 0) }
      tail.box([0.17, 0.16, 0.17], [0, 0, 0.12], 2)
      for side: Float in [-1, 1] { head.box([0.10, 0.009, 0.012], [side * 0.15, -0.04, front - 0.02], 4) }
    case .chicken, .duck, .parrot, .penguin:
      let bill: SIMD3<Float> = kind == .duck ? [0.20, 0.055, 0.21] : kind == .parrot ? [0.14, 0.17, 0.12] : [0.10, 0.07, 0.15]
      mouth.box(bill, [0, -face * 0.14, front * 0.84], 5)
      if kind == .parrot { mouth.box([0.085, 0.10, 0.07], [0, -0.16, front - 0.02], 3) }
      if kind == .chicken {
        for n in 0..<3 { head.box([0.045, 0.08 + Float(n % 2) * 0.045, 0.07], [0, face * 0.52, Float(n - 1) * 0.06], 11) }
        mouth.box([0.055, 0.085, 0.055], [0, -0.14, front * 0.8], 11)
      }
      if kind == .duck { body.box([p.width * 0.81, 0.055, 0.09], [0, headHeight - face * 0.48, -p.length * 0.32], 4) }
      if kind == .penguin { body.box([p.width * 0.80, p.height * 0.74, 0.028], [0, middle + 0.015, -p.length * 0.453], 2) }
      for n in 0..<3 { tail.box([0.07, kind == .parrot ? 0.37 : 0.12, 0.19],
        [Float(n - 1) * 0.07, kind == .parrot ? -0.10 : 0.08 + Float(n % 2) * 0.045, 0.11], kind == .parrot ? 11 : 8) }
    case .frog:
      for side: Float in [-1, 1] {
        head.box([0.11, 0.11, 0.10], [side * 0.12, 0.16, -0.04], 0)
        eyes.box([0.075, 0.070, 0.017], [side * 0.12, 0.175, -0.096], 6)
        eyes.box([0.047, 0.059, 0.023], [side * 0.12, 0.17, -0.103], 3)
        eyes.box([0.015, 0.020, 0.028], [side * 0.12 + 0.008, 0.19, -0.108], 6)
      }
      for i in [2, 3] { limbs[i].box([0.20, 0.16, 0.23], [0, 0.05, 0], 0) }
      mouth.box([0.20, 0.012, 0.015], [0, -0.07, front], 3)
    case .fish:
      body.box([0.028, 0.19, 0.25], [0, p.height + 0.035, 0], 5)
      tail.box([0.028, 0.27, 0.16], [0, 0, 0.12], 5)
      tail.box([0.025, 0.39, 0.065], [0, 0, 0.20], 11)
      for side: Float in [-1, 1] { for n in 0..<(look.markings + 1) {
        body.box([0.012, p.height * 0.72, 0.042], [side * p.width * 0.505, middle, -0.11 + Float(n) * 0.09], 8)
      } }
      mouth.box([0.085, 0.05, 0.035], [0, -0.03, front], 10)
    }
    // Sparse markings add within-species variation without unrelated anatomy.
    if look.markings > 0 && [.horse, .pig, .goat, .rabbit, .boar].contains(kind) {
      for side: Float in [-1, 1] { for n in 0..<look.markings {
        body.box([0.018, p.height * 0.38, 0.12 + Float(n % 2) * 0.08],
          [side * p.width * 0.504, middle, -p.length * 0.24 + Float(n) * p.length * 0.21], 8)
      } }
    }
    // Expressions scale/rotate around the feature, not the head's origin.
    // Otherwise a blink would pull a frog's raised eyes down into its face.
    eyes.pivot = [0, kind == .frog ? 0.175 : face * 0.10, 0]
    eyes.boxes = eyes.boxes.map { .init($0.size, $0.center - eyes.pivot, $0.color) }
    mouth.pivot = mouth.boxes.first?.center ?? .zero
    mouth.boxes = mouth.boxes.map { .init($0.size, $0.center - mouth.pivot, $0.color) }
    return .init(name: kind.name, key: "animal-\(kind.rawValue)-\(look.shape)-\(look.markings)-\(look.juvenile)",
      colors: palette(look), parts: [body, head, eyes, mouth] + limbs + [tail])
  }

  private static func palette(_ look: AnimalAppearance) -> [SIMD3<Float>] {
    let coats: [SIMD3<Float>] = switch look.kind {
    case .sheep: [[0.95,0.91,0.78], [0.24,0.24,0.26], [0.57,0.35,0.23], [0.83,0.71,0.52]]
    case .fox: [[0.95,0.38,0.10], [0.86,0.89,0.93], [0.45,0.48,0.56], [0.68,0.22,0.10]]
    case .deer: [[0.68,0.39,0.18], [0.46,0.28,0.15], [0.78,0.54,0.30]]
    case .rabbit: [[0.67,0.57,0.43], [0.94,0.91,0.84], [0.40,0.44,0.49], [0.38,0.23,0.16]]
    case .cow: [[0.94,0.92,0.85], [0.64,0.31,0.12], [0.82,0.68,0.41], [0.30,0.20,0.17]]
    case .pig: [[0.96,0.57,0.63], [0.96,0.73,0.67], [0.59,0.34,0.32]]
    case .horse: [[0.54,0.25,0.12], [0.16,0.15,0.18], [0.80,0.59,0.28], [0.85,0.85,0.83], [0.41,0.22,0.14], [0.88,0.76,0.52]]
    case .goat: [[0.84,0.77,0.58], [0.42,0.29,0.19], [0.89,0.89,0.82], [0.30,0.33,0.36]]
    case .wolf: [[0.43,0.49,0.56], [0.22,0.24,0.29], [0.80,0.80,0.72], [0.58,0.46,0.32]]
    case .bear: [[0.33,0.20,0.12], [0.14,0.16,0.18], [0.65,0.46,0.27]]
    case .chicken: [[0.94,0.91,0.80], [0.70,0.26,0.10], [0.25,0.28,0.34]]
    case .duck: [[0.13,0.48,0.32], [0.70,0.50,0.27], [0.95,0.91,0.77]]
    case .frog: [[0.33,0.72,0.17], [0.18,0.62,0.56], [0.75,0.67,0.15]]
    case .parrot: [[0.95,0.22,0.16], [0.12,0.60,0.79], [0.34,0.78,0.19], [0.94,0.70,0.12]]
    case .zebra: [[0.94,0.92,0.83], [0.82,0.83,0.83], [0.94,0.87,0.69]]
    case .camel: [[0.76,0.54,0.29], [0.87,0.72,0.46], [0.59,0.39,0.24]]
    case .penguin: [[0.13,0.19,0.27], [0.24,0.28,0.35], [0.18,0.23,0.26]]
    case .fish: [[0.99,0.47,0.12], [0.11,0.65,0.76], [0.86,0.30,0.69], [0.95,0.76,0.16], [0.27,0.47,0.91], [0.68,0.80,0.37]]
    case .panda: [[0.94,0.92,0.84], [0.87,0.86,0.83], [0.99,0.94,0.79]]
    case .elephant: [[0.46,0.50,0.55], [0.61,0.56,0.51], [0.39,0.43,0.46]]
    case .giraffe: [[0.90,0.66,0.23], [0.79,0.49,0.16], [0.97,0.81,0.45]]
    case .tortoise: [[0.40,0.54,0.23], [0.62,0.56,0.25], [0.28,0.48,0.37]]
    case .otter: [[0.38,0.23,0.14], [0.59,0.42,0.26], [0.28,0.32,0.34]]
    case .boar: [[0.39,0.27,0.18], [0.22,0.22,0.23], [0.56,0.41,0.25]]
    case .dog: [DogSculpture.colors[0]]
    case .hayHay: [HayHaySculpture.colors[0]]
    }
    let coat = coats[look.coat % coats.count]
    let ink = SIMD3<Float>(0.055,0.067,0.086), cream = SIMD3<Float>(0.96,0.88,0.68)
    let spots: SIMD3<Float> = [.zebra,.panda].contains(look.kind) ? ink
      : look.kind == .cow ? (look.coat % 2 == 0 ? ink : cream) : coat * 0.43
    let accent = look.kind == .tortoise ? SIMD3<Float>(0.78,0.62,0.25) : SIMD3<Float>(1,0.65,0.10)
    return [coat, coat * 0.73, coat * 0.25 + cream * 0.75, ink, cream, accent,
      [0.98,0.97,0.90], [0.10,0.15,0.17], spots, coat * 0.26,
      [0.82,0.43,0.44], look.kind == .chicken ? [0.85,0.08,0.13] : [0.10,0.46,0.80],
      coat * 0.78 + SIMD3<Float>(repeating: 0.21), [0.48,0.70,0.22], [0.74,0.83,0.86], [1,1,1]]
  }
}
