import RealityKit
import WorldCore

/// One articulated, cached actor. Mesh preparation uses ActorMeshPreparation,
/// and never waits for simulation or a provider on the render update.
@MainActor final class PlayerAvatarRenderer {
  let root = Entity()
  private var rig: ActorRig?
  private var gait: Float = 0
  private var previousFeet: SIMD3<Float>?
  private weak var lighting: Entity?

  func reset() { previousFeet = nil; gait = 0; root.isEnabled = false }

  func update(frame: PlayerFrame, feet: SIMD3<Float>, heading: Float,
    look: SIMD3<Float>, seconds: Float, time: Double, visible: Bool,
    seated: Bool, swimming: Bool, flying: Bool, lighting: Entity
  ) {
    let previous = previousFeet ?? feet
    previousFeet = feet
    root.isEnabled = visible && simd_length_squared(frame.cameraOffset) > 1.8 * 1.8
    guard root.isEnabled else { return }
    if rig == nil, let prepared = ActorModelLibrary.shared.geometry(for: .player) {
      let actor = ActorRig(prepared, library: .shared)
      rig = actor; root.addChild(actor.root)
    }
    guard let rig else { return }
    if self.lighting !== lighting {
      self.lighting = lighting
      root.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lighting))
    }
    let rotation = frame.trackingFromWorldRotation, origin = frame.worldOriginInTracking
    if root.orientation.vector != rotation.vector || root.position != origin {
      root.transform = .init(scale: .init(repeating: WorldScale.metresPerBlock), rotation: rotation, translation: origin)
    }
    rig.root.position = feet
    rig.root.orientation = simd_quatf(angle: heading, axis: [0, 1, 0])
    let stride = simd_length(SIMD2<Float>(feet.x - previous.x, feet.z - previous.z))
    let moving = seconds > 0 && stride > 0.003 && stride < 4
    gait += moving ? stride * 2.2 : seconds * (swimming ? 2 : 0)
    gait.formTruncatingRemainder(dividingBy: .pi * 2)
    let head = rig.root.orientation.inverse.act(look)
    let yaw = max(-1.2, min(1.2, atan2(-head.x, -head.z)))
    let pitch = max(-0.7, min(0.7, asin(max(-1, min(1, head.y)))))
    rig[.head].orientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
    for i in 0..<2 {
      let phase = gait + Float(i) * .pi
      let leg: ActorJoint = i == 0 ? .limb2 : .limb3, arm: ActorJoint = i == 0 ? .limb0 : .limb1
      let legAngle: Float = seated ? .pi / 2 : swimming ? sin(phase) * 0.35 : moving && !flying ? sin(phase) * 0.58 : 0
      let armAngle: Float = seated ? 1.15 : swimming ? 1.0 + sin(phase) * 0.8 : moving && !flying ? -sin(phase) * 0.48 : -0.06
      rig[leg].orientation = simd_quatf(angle: legAngle, axis: [1, 0, 0])
      rig[arm].orientation = simd_quatf(angle: armAngle, axis: [1, 0, 0])
        * simd_quatf(angle: flying ? (i == 0 ? -0.3 : 0.3) : 0, axis: [0, 0, 1])
    }
    rig.face(time: time, id: 0, asleep: false, talking: false)
  }
}
