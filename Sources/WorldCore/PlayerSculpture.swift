import Foundation

/// The same teal sleeves and warm skin as the first-person hands, in a full rig.
public enum PlayerSculpture {
  public static func make() -> ActorSculpture {
    var body = ActorPart(.body)
    var head = ActorPart(.head, at: [0, 1.48, 0])
    var eyes = ActorPart(.eyes, at: [0, 0.035, -0.155])
    var mouth = ActorPart(.mouth, at: [0, -0.10, -0.156])
    body.box([0.43, 0.52, 0.27], [0, 1.07, 0], 1)
    body.box([0.40, 0.16, 0.26], [0, 0.75, 0], 2)
    body.box([0.15, 0.10, 0.15], [0, 1.37, 0], 0)
    body.box([0.43, 0.045, 0.28], [0, 0.82, 0], 3)
    body.box([0.06, 0.045, 0.026], [0, 0.82, -0.153], 6)
    body.box([0.30, 0.35, 0.15], [0, 1.07, 0.185], 3)
    body.box([0.31, 0.08, 0.17], [0, 1.25, 0.19], 2)
    for side: Float in [-1, 1] {
      body.box([0.043, 0.39, 0.035], [side * 0.145, 1.12, -0.148], 3)
      body.box([0.10, 0.06, 0.035], [side * 0.09, 1.30, -0.135], 7)
      head.box([0.035, 0.09, 0.07], [side * 0.16, 0, 0], 0)
      eyes.box([0.065, 0.046, 0.018], [side * 0.073, 0, 0], 5)
      eyes.box([0.027, 0.039, 0.028], [side * 0.070, 0, -0.010], 4)
      head.box([0.07, 0.016, 0.018], [side * 0.073, 0.083, -0.152], 3)
    }
    head.box([0.29, 0.29, 0.28], .zero, 0)
    head.box([0.043, 0.061, 0.04], [0, -0.035, -0.154], 0)
    head.box([0.31, 0.07, 0.30], [0, 0.17, 0.005], 3)
    head.box([0.31, 0.20, 0.048], [0, 0.06, 0.137], 3)
    head.box([0.19, 0.055, 0.06], [-0.05, 0.12, -0.135], 3)
    mouth.box([0.065, 0.015, 0.018], .zero, 3)
    var parts = [body, head, eyes, mouth]
    for i in 0..<2 {
      let side: Float = i == 0 ? -1 : 1
      var arm = ActorPart(i == 0 ? .limb0 : .limb1, at: [side * 0.30, 1.28, 0])
      arm.box([0.15, 0.36, 0.17], [0, -0.17, 0], 1)
      arm.box([0.155, 0.05, 0.18], [0, -0.37, 0], 7)
      arm.box([0.135, 0.13, 0.15], [0, -0.46, -0.01], 0)
      arm.box([0.035, 0.065, 0.075], [-side * 0.076, -0.455, -0.025], 0)
      var leg = ActorPart(i == 0 ? .limb2 : .limb3, at: [side * 0.12, 0.73, 0])
      leg.box([0.18, 0.58, 0.21], [0, -0.29, 0], 2)
      leg.box([0.19, 0.16, 0.25], [0, -0.63, -0.02], 3)
      leg.box([0.20, 0.05, 0.28], [0, -0.705, -0.035], 4)
      parts += [arm, leg]
    }
    return .init(name: "Player", key: "player-explorer-v1", colors: [
      [0.75, 0.47, 0.29], [0.08, 0.53, 0.57], [0.18, 0.25, 0.32], [0.22, 0.14, 0.10],
      [0.08, 0.085, 0.10], [0.94, 0.93, 0.88], [0.93, 0.69, 0.28], [0.30, 0.72, 0.70]
    ], parts: parts)
  }
}
