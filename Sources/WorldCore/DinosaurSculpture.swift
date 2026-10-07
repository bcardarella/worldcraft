import Foundation

/// Solid, articulated voxel animals; horns, sails, plates, crests and feathers
/// change silhouette, rather than simply recoloring the same T-rex mesh.
public enum DinosaurSculpture {
  private struct Build {
    let width: Float, legs: Float, body: Float, length: Float, neck: Float, face: Float, snout: Float, tail: Float
    init(_ w: Float, _ l: Float, _ b: Float, _ d: Float, _ n: Float, _ f: Float, _ s: Float, _ t: Float) {
      width = w; legs = l; body = b; length = d; neck = n; face = f; snout = s; tail = t
    }
  }
  public static func make(_ look: DinosaurAppearance) -> ActorSculpture {
    let kind = look.kind
    let p: Build = switch kind {
    case .trex: .init(1.02, 1.02, 1.10, 1.72, 2.55, 0.85, 1.00, 2.30)
    case .triceratops: .init(1.29, 0.57, 1.01, 2.21, 1.17, 0.77, 0.84, 1.60)
    case .stegosaurus: .init(1.09, 0.58, 0.95, 2.34, 0.83, 0.38, 0.51, 2.04)
    case .ankylosaurus: .init(1.30, 0.34, 0.73, 2.19, 0.64, 0.54, 0.59, 1.83)
    case .brachiosaurus: .init(1.68, 1.91, 1.71, 3.25, 7.96, 0.66, 0.75, 3.05)
    case .parasaurolophus: .init(0.78, 0.87, 0.87, 1.59, 2.04, 0.43, 0.67, 1.91)
    case .velociraptor: .init(0.37, 0.57, 0.48, 0.91, 1.14, 0.32, 0.51, 1.37)
    case .spinosaurus: .init(1.03, 0.94, 0.99, 2.14, 2.15, 0.56, 1.43, 2.71)
    }
    let juvenile = look.juvenile
    let leg = p.legs * (juvenile ? 0.79 : 1)
    let bodyHeight = p.body * (juvenile ? 0.93 : 1)
    let mid = leg + bodyHeight * 0.49
    let headY = p.neck * (juvenile ? (kind == .brachiosaurus ? 0.72 : 0.91) : 1)
    let face = p.face * (juvenile ? 1.18 : 1), snout = p.snout * (juvenile ? 0.86 : 1)
    var body = ActorPart(.body)
    var head = ActorPart(.head, at: [0, headY, -p.length * 0.39])
    var eyes = ActorPart(.eyes, at: [0, face * 0.21, -snout * 0.29])
    var mouth = ActorPart(.mouth, at: [0, -face * 0.17, -snout * 0.05])
    var tail = ActorPart(.tail, at: [0, mid + bodyHeight * 0.10, p.length * 0.43])
    var limbs = [ActorPart(.limb0), ActorPart(.limb1), ActorPart(.limb2), ActorPart(.limb3)]
    body.box([p.width, bodyHeight * 0.72, p.length * 0.90], [0, mid, 0], 0)
    body.box([p.width * 0.83, bodyHeight, p.length * 0.72], [0, mid + 0.03, 0], 0)
    body.box([p.width * 0.76, bodyHeight * 0.20, p.length * 0.75], [0, leg + bodyHeight * 0.035, -0.045], 1)
    let neckLength = max(0.16, headY - mid)
    if kind == .brachiosaurus {
      for i in 0..<7 {
        let t = Float(i) / 6, width = 0.89 - t * 0.46
        let y = mid + (headY - mid) * t
        let z = -p.length * 0.23 - t * p.length * 0.16
        body.box([width, neckLength / 6 + 0.13, width * 0.95], [0, y, z], 0)
        body.box([width * 0.61, neckLength / 6 + 0.08, 0.035], [0, y, z - width * 0.49], 1)
        for side: Float in [-1, 1] {
          body.box([0.025, 0.17, width * 0.4], [side * width * 0.507, y, z], i % 2 == 0 ? 2 : 8)
        }
      }
    } else {
      body.box([face * 0.78, neckLength, face * 0.79], [0, mid + neckLength / 2, -p.length * 0.33], 0)
      body.box([face * 0.54, neckLength * 0.85, 0.04], [0, mid + neckLength / 2, -p.length * 0.33 - face * 0.40], 1)
    }
    head.box([face, face * 0.68, snout * 0.59], [0, face * 0.11, -snout * 0.10], 0)
    head.box([face * 0.80, face * 0.30, snout * 0.90], [0, -face * 0.03, -snout * 0.37], 0)
    head.box([face * 0.77, face * 0.14, snout * 0.36], [0, face * 0.32, -snout * 0.12], 8)
    mouth.box([face * 0.78, face * 0.16, snout * 0.91], [0, -face * 0.055, -snout * 0.34], 1)
    mouth.box([face * 0.63, 0.017, snout * 0.77], [0, face * 0.035, -snout * 0.36], 7)
    if kind.carnivore {
      for side: Float in [-1, 1] { for i in 0..<(juvenile ? 3 : 5) {
        let z = -snout * (0.18 + Float(i) * 0.13)
        head.box([0.048, face * 0.105, 0.06], [side * face * 0.35, -face * 0.205, z], 4)
        mouth.box([0.036, face * 0.08, 0.05], [side * face * 0.30, face * 0.06, z - 0.018], 4)
      } }
    } else {
      head.box([face * 0.65, face * 0.115, 0.079], [0, -face * 0.075, -snout * 0.81], 2)
    }
    for side: Float in [-1, 1] {
      // Eyes wrap around the front corners so both profile and face read clearly.
      eyes.box([face * 0.18, face * 0.20, 0.055], [side * face * 0.48, 0, 0], 5)
      eyes.box([face * 0.11, face * 0.14, 0.063], [side * face * 0.49, 0, -0.03], 7)
      eyes.box([face * 0.044, face * 0.06, 0.070], [side * face * 0.49 + 0.01, face * 0.045, -0.04], 6)
      head.box([face * 0.22, face * 0.075, snout * 0.18], [side * face * 0.42, face * 0.36, -snout * 0.25], 8)
      head.box([face * 0.09, 0.039, 0.035], [side * face * 0.25, face * 0.035, -snout * 0.83], 7)
    }
    for i in limbs.indices {
      let side: Float = i % 2 == 0 ? -1 : 1
      let arm = kind.biped && i < 2
      if arm {
        let tiny = kind == .trex
        let length: Float = tiny ? 0.28 : kind == .velociraptor ? 0.39 : 0.52
        limbs[i].pivot = [side * p.width * 0.48, mid + bodyHeight * 0.22, -p.length * 0.31]
        limbs[i].box([p.width * 0.16, length * 0.55, p.width * 0.19], [side * 0.015, -length * 0.20, -0.04], 0)
        limbs[i].box([p.width * 0.13, 0.075, length * 0.50], [side * 0.02, -length * 0.40, -length * 0.27], 1)
        for n in 0..<(tiny ? 2 : 3) {
          limbs[i].box([0.027, 0.07, 0.027], [Float(n - 1) * 0.036, -length * 0.49, -length * 0.53], 4)
        }
      } else {
        let width = p.width * (kind.biped ? 0.38 : 0.25)
        let legHeight = leg * (kind == .brachiosaurus && i < 2 ? 1.12 : 1)
        limbs[i].pivot = [side * p.width * (kind.biped ? 0.37 : 0.34), legHeight,
          kind.biped ? p.length * 0.07 : (i < 2 ? -1 : 1) * p.length * 0.30]
        limbs[i].box([width, legHeight * 0.60, width * 1.03], [0, -legHeight * 0.23, 0], 0)
        limbs[i].box([width * 0.67, legHeight * 0.55, width * 0.69], [0, -legHeight * 0.67, 0.03], 1)
        limbs[i].box([width * 1.05, max(0.075, legHeight * 0.16), width * 1.70], [0, -legHeight * 0.90, -width * 0.23], 0)
        for toe in -1...1 { limbs[i].box([width * 0.21, 0.052, width * 0.38],
          [Float(toe) * width * 0.31, -legHeight + 0.039, -width * 1.06], 4) }
        if kind == .velociraptor {
          limbs[i].box([0.029, 0.12, 0.043], [-side * width * 0.35, -legHeight + 0.11, -width * 0.95], 7)
        }
      }
    }
    for i in 0..<8 {
      let t = Float(i) / 7, width = max(0.065, p.width * 0.56 * (1 - t * 0.87))
      tail.box([width, width * 0.88, p.tail / 7 + 0.055], [0, -t * min(mid * 0.62, 0.65), t * p.tail], i % 3 == look.pattern % 3 ? 2 : 0)
    }
    switch kind {
    case .trex:
      for i in 0..<5 {
        body.box([0.13, (juvenile ? 0.06 : 0.13) + Float(look.crest) * 0.025, 0.16],
          [0, leg + bodyHeight + 0.015, Float(i - 2) * 0.25], 8)
      }
      head.box([face * 0.69, 0.08, snout * 0.43], [0, face * 0.47, -snout * 0.05], 0)
    case .triceratops:
      // Wide layered frill, paired brow horns and a third nasal horn.
      head.box([face * 1.65, face * 1.10, 0.13], [0, face * 0.42, 0.16], 8)
      head.box([face * 1.46, face * 0.90, 0.035], [0, face * 0.43, 0.077], 11)
      head.box([face * 1.22, face * 0.71, 0.04], [0, face * 0.40, 0.048], 0)
      for side: Float in [-1, 1] {
        let horn: Float = juvenile ? 0.24 : 0.58 + Float(look.crest) * 0.08
        for i in 0..<3 {
          let taper = 0.13 - Float(i) * 0.032
          head.box([taper, horn / 3 + 0.035, 0.11], [side * face * 0.34, face * 0.38 + Float(i) * horn / 3, -0.24 - Float(i) * 0.12], 4)
        }
        for i in 0..<4 { head.box([0.12, 0.09, 0.08], [side * face * (0.52 + Float(i % 2) * 0.18), face * (0.18 + Float(i) * 0.23), 0.15], 4) }
      }
      head.box([0.13, juvenile ? 0.14 : 0.31, 0.13], [0, face * 0.20, -snout * 0.68], 4)
    case .stegosaurus:
      for side: Float in [-1, 1] { for i in 0..<6 {
        let size = (0.30 + sin(Float(i + 1) / 7 * .pi) * 0.37) * (juvenile ? 0.62 : 1)
        let z = -p.length * 0.36 + Float(i) * p.length * 0.145 + (side < 0 ? 0.04 : -0.04)
        body.box([0.10, size, 0.28], [side * 0.18, leg + bodyHeight + size * 0.38, z], 11)
        body.box([0.11, size * 0.48, 0.18], [side * 0.18, leg + bodyHeight + size * 0.95, z], 8)
      } }
      for side: Float in [-1, 1] { for z: Float in [p.tail * 0.67, p.tail * 0.86] {
        tail.box([juvenile ? 0.26 : 0.48, 0.07, 0.085], [side * 0.22, -0.39, z], 4)
        tail.box([0.07, juvenile ? 0.12 : 0.24, 0.075], [side * 0.43, -0.30, z], 4)
      } }
    case .ankylosaurus:
      body.box([p.width * 1.06, 0.20, p.length * 0.87], [0, leg + bodyHeight * 0.84, 0], 8)
      for x: Float in [-0.39, 0, 0.39] { for i in 0..<5 {
        body.box([0.24, 0.13, 0.26], [x, leg + bodyHeight + 0.03, Float(i - 2) * 0.36], (i + look.pattern) % 2 == 0 ? 11 : 8)
      } }
      for side: Float in [-1, 1] { for i in 0..<5 {
        body.box([juvenile ? 0.20 : 0.34, 0.10, 0.14], [side * p.width * 0.56, mid + 0.17, Float(i - 2) * 0.34], 4)
      } }
      tail.box([0.57, 0.29, 0.43], [0, -0.39, p.tail * 0.96], 8)
      tail.box([0.42, 0.36, 0.34], [0, -0.39, p.tail * 0.96], 11)
    case .brachiosaurus:
      head.box([0.28, 0.14, 0.26], [0, face * 0.53, -0.05], 0)
      for i in 0..<6 { body.box([0.10, 0.11, 0.15], [0, leg + bodyHeight + 0.01, Float(i - 2) * 0.43], 8) }
    case .parasaurolophus:
      let length: Float = juvenile ? 0.43 : 0.86 + Float(look.crest) * 0.11
      for i in 0..<4 {
        head.box([0.15 - Float(i) * 0.019, 0.12, length / 3 + 0.03], [0, face * 0.43 + Float(i) * 0.065, Float(i) * length / 3], i == 3 ? 8 : 11)
      }
      head.box([face * 0.88, 0.07, 0.15], [0, -0.045, -snout * 0.78], 8)
    case .velociraptor:
      // Solid feather steps, small forelimb fans, long balancing tail and raised claws.
      for i in 0..<5 { body.box([0.055, 0.13, 0.12], [0, leg + bodyHeight + 0.035, Float(i - 2) * 0.14], 11) }
      for i in 0..<2 { for feather in 0..<4 {
        let side: Float = i == 0 ? -1 : 1
        limbs[i].box([0.035, 0.18 - Float(feather) * 0.018, 0.14], [side * Float(feather + 1) * 0.031, -0.15, -0.10 + Float(feather) * 0.048], feather % 2 == 0 ? 11 : 8)
      } }
      for side: Float in [-1, 1] { for i in 0..<3 {
        tail.box([0.11, 0.035, 0.18], [side * 0.07, -0.19, p.tail * 0.60 + Float(i) * 0.13], 11)
      } }
    case .spinosaurus:
      for i in 0..<9 {
        let t = Float(i) / 8
        let height = (0.34 + sin(t * .pi) * (0.84 + Float(look.crest) * 0.10)) * (juvenile ? 0.64 : 1)
        let z = -p.length * 0.4 + t * p.length * 0.85
        body.box([0.075, height, p.length * 0.106], [0, leg + bodyHeight + height / 2, z], i % 2 == 0 ? 11 : 8)
        body.box([0.085, 0.055, p.length * 0.109], [0, leg + bodyHeight + height, z], 4)
      }
      for i in 0..<5 { tail.box([0.045, 0.20, 0.24], [0, -Float(i) * 0.085 + 0.16, Float(i) * 0.38], 11) }
    }
    // Four coat layouts with different silhouettes already carried by each species.
    for side: Float in [-1, 1] { for i in 0..<6 {
      let z = -p.length * 0.35 + Float(i) * p.length * 0.14
      switch look.pattern {
      case 0:
        body.box([0.018, bodyHeight * 0.67, p.length * 0.045], [side * p.width * 0.504, mid + 0.035, z], 2)
      case 1:
        body.box([0.018, bodyHeight * 0.22, p.length * 0.085], [side * p.width * 0.504, mid + (i % 2 == 0 ? 0.13 : -0.06), z], 8)
      case 2:
        body.box([0.018, bodyHeight * 0.11, p.length * 0.14], [side * p.width * 0.504, mid + 0.20, z], 11)
      default:
        if i % 2 == 0 { body.box([0.018, bodyHeight * 0.45, p.length * 0.13], [side * p.width * 0.504, mid - 0.035, z], 1) }
      }
    } }
    let parts = [body, head, eyes, mouth] + limbs + [tail]
    return .init(name: (juvenile ? "Baby " : "") + kind.name,
      key: "dinosaur-\(kind.rawValue)-\(juvenile)-\(look.pattern)-\(look.crest)", colors: palette(look), parts: parts)
  }
  private static func palette(_ look: DinosaurAppearance) -> [SIMD3<Float>] {
    let coat = look.color.rgb
    let cream = SIMD3<Float>(0.98, 0.91, 0.71)
    let accent: SIMD3<Float> = [[0.97,0.60,0.18],[0.40,0.83,0.72],[0.82,0.37,0.65],[0.50,0.54,0.88]][look.accent]
    return [coat, coat * 0.22 + cream * 0.78, coat * 0.30, [0.17,0.13,0.16], cream,
      [0.99,0.76,0.22], [1,0.98,0.91], [0.065,0.075,0.10], coat * 0.55 + accent * 0.23,
      [0.75,0.29,0.35], coat * 0.75 + SIMD3<Float>(repeating:0.19), accent,
      [0.31,0.58,0.40], [0.94,0.86,0.68], [0.47,0.57,0.65], [1,1,1]]
  }
}
