import Foundation

/// Photo reference: clipped golden curls, long cream muzzle, darker floppy ears,
/// long legs, dark eyes/nose and a teal patterned bandana. All detail is solid.
public enum DogSculpture {
  public static let colors: [SIMD3<Float>] = [
    [0.86,0.68,0.42], [0.72,0.52,0.30], [0.95,0.84,0.64], [0.10,0.075,0.055],
    [0.90,0.75,0.51], [0.97,0.88,0.70], [1,0.98,0.92], [0.035,0.035,0.035],
    [0.10,0.48,0.53], [0.31,0.68,0.70], [0.85,0.41,0.46], [0.14,0.18,0.18],
    [0.79,0.63,0.41], [0.78,0.82,0.80], [0.61,0.43,0.24], [0.93,0.80,0.57]
  ]
  public static func make(juvenile: Bool = false) -> ActorSculpture {
    let leg: Float = juvenile ? 0.31 : 0.43
    let face: Float = juvenile ? 1.10 : 1
    let headY: Float = leg + 0.37
    var body = ActorPart(.body)
    var head = ActorPart(.head, at: [0, headY, -0.37])
    var eyes = ActorPart(.eyes, at: [0, 0.045 * face, -0.154])
    var mouth = ActorPart(.mouth, at: [0, -0.075 * face, -0.11])
    var tail = ActorPart(.tail, at: [0, leg + 0.25, 0.38])
    var legs = [ActorPart(.limb0), ActorPart(.limb1), ActorPart(.limb2), ActorPart(.limb3)]
    body.box([0.32,0.26,0.77], [0,leg + 0.14,0], 0)
    body.box([0.275,0.31,0.66], [0,leg + 0.16,-0.025], 0)
    body.box([0.29,0.29,0.22], [0,leg + 0.13,-0.27], 4)
    body.box([0.23,0.14,0.59], [0,leg + 0.005,-0.05], 2)
    body.box([0.215,0.29,0.22], [0,leg + 0.29,-0.29], 4)
    body.box([0.17,0.23,0.045], [0,leg + 0.13,-0.411], 2)
    // Sparse shallow tufts read as a close wavy clip, not a sheep's fleece.
    for i in 0..<5 {
      let z = Float(i - 2) * 0.13
      body.box([0.16,0.025,0.085], [i % 2 == 0 ? -0.035 : 0.035,leg + 0.323,z], i % 2 == 0 ? 4 : 15)
      for side: Float in [-1,1] {
        body.box([0.025,0.074,0.083], [side * 0.161,leg + 0.14 + Float(i % 2) * 0.045,z], i % 2 == 0 ? 4 : 12)
      }
    }
    head.box([0.275 * face,0.225 * face,0.24], [0,0.015,0], 4)
    head.box([0.235 * face,0.255 * face,0.215], [0,0.025,-0.01], 4)
    head.box([0.195 * face,0.15,juvenile ? 0.25 : 0.30], [0,-0.048,-0.175], 2)
    head.box([0.161 * face,0.145,0.20], [0,-0.035,-0.241], 4)
    head.box([0.146,0.079,0.06], [0,-0.026,-0.352], 3)
    head.box([0.119,0.09,0.042], [0,-0.023,-0.357], 3)
    head.box([0.057,0.015,0.008], [-0.02,0.005,-0.382], 13)
    for side: Float in [-1,1] {
      // Brow/cheek curls, long drooping ears and a soft beard around the muzzle.
      head.box([0.072,0.047,0.073], [side * 0.087,0.118 * face,-0.084], 15)
      head.box([0.035,0.039,0.079], [side * 0.12,0.067,-0.06], 0)
      head.box([0.050,0.089,0.11], [side * 0.109,-0.10,-0.14], 5)
      head.box([0.04,0.070,0.08], [side * 0.094,-0.145,-0.19], 2)
      head.box([0.09,0.19,0.125], [side * 0.163,0.002,0.018], 1)
      head.box([0.095,0.20,0.115], [side * 0.179,-0.14,0.027], 0)
      head.box([0.084,0.098,0.106], [side * 0.176,-0.256,0.024], 1)
      for n in 0..<3 {
        head.box([0.034,0.067,0.027], [side * (0.163 + Float(n % 2) * 0.024),-0.08 - Float(n) * 0.076,-0.043], n % 2 == 0 ? 4 : 12)
      }
      eyes.box([0.059,0.066,0.027], [side * 0.086,0,0], 14)
      eyes.box([0.044,0.054,0.031], [side * 0.085,-0.002,-0.016], 3)
      eyes.box([0.027,0.041,0.035], [side * 0.084,-0.003,-0.022], 7)
      eyes.box([0.012,0.015,0.039], [side * 0.084 - 0.007,0.012,-0.026], 6)
    }
    for i in 0..<3 {
      head.box([0.055,0.029,0.073], [Float(i - 1) * 0.066,0.161 * face,-0.025], i == 1 ? 15 : 0)
    }
    // Happy open mouth and tongue stay attached to the jaw during panting.
    head.box([0.155,0.034,0.20], [0,-0.13,-0.226], 7)
    mouth.box([0.164,0.043,0.20], [0,-0.09,-0.12], 2)
    mouth.box([0.109,0.015,0.14], [0,-0.062,-0.16], 7)
    mouth.box([0.055,0.017,0.095], [0,-0.045,-0.189], 10)
    mouth.box([0.048,0.045,0.035], [0,-0.06,-0.235], 10)
    for i in legs.indices {
      let side: Float = i % 2 == 0 ? -1 : 1
      legs[i].pivot = [side * 0.111, leg + 0.035, i < 2 ? -0.255 : 0.269]
      legs[i].box([0.095,leg * 0.56,0.11], [0,-leg * 0.21,0], 0)
      legs[i].box([0.076,leg * 0.65,0.080], [0,-leg * 0.63,0.007], 2)
      legs[i].box([0.109,0.074,0.153], [0,-leg + 0.002,-0.034], 5)
      legs[i].box([0.085,0.041,0.104], [0,-leg + 0.052,-0.014], 4)
      for toe in -1...1 {
        legs[i].box([0.023,0.018,0.018], [Float(toe) * 0.031,-leg - 0.012,-0.109], 12)
      }
    }
    for i in 0..<9 {
      let t = Float(i) / 8
      let width = 0.078 - t * 0.036
      tail.box([width,0.092,width], [0,-t * 0.35,0.035 + t * 0.14 + max(0,t - 0.7) * 0.18], t > 0.65 ? 2 : 0)
    }
    // Teal kerchief, lighter woven squares, dark collar and a silver tag loop.
    body.box([0.24,0.065,0.24], [0,leg + 0.31,-0.31], 11)
    body.box([0.258,0.062,0.251], [0,leg + 0.292,-0.317], 8)
    for i in 0..<4 {
      let w = 0.26 - Float(i) * 0.056
      body.box([w,0.066,0.021], [0,leg + 0.25 - Float(i) * 0.055,-0.437], 8)
      if i < 3 {
        body.box([0.028,0.028,0.007], [i % 2 == 0 ? -w * 0.24 : w * 0.24,leg + 0.26 - Float(i) * 0.055,-0.452], 9)
      }
    }
    body.box([0.038,0.043,0.016], [0.12,leg + 0.232,-0.387], 13)
    body.box([0.022,0.028,0.019], [0.12,leg + 0.232,-0.389], 11)
    return .init(name: juvenile ? "Golden puppy" : "Golden dog", key: "golden-dog-\(juvenile)",
      colors: colors, parts: [body,head,eyes,mouth] + legs + [tail])
  }
}
