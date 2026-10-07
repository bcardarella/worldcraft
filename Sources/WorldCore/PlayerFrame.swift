import Foundation
import simd

/// Converts points between the headset's tracking space and the voxel world.
/// The initial headset pose defines neutral forward/up, including while reclining.
/// Body look is composed with subsequent head motion; stereo tracking stays native.
public struct PlayerFrame: Sendable {
  public var referenceEye: SIMD3<Float>
  public var referenceOrientation: simd_quatf
  public var feet: SIMD3<Float>
  public var heading: Float
  public var pitch: Float
  /// A camera boom changes the view without moving the character or its collision body.
  public var cameraOffset: SIMD3<Float>
  public init(
    referenceEye: SIMD3<Float>,
    referenceOrientation: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0]),
    feet: SIMD3<Float>, heading: Float, pitch: Float = 0, cameraOffset: SIMD3<Float> = .zero
  ) {
    self.referenceEye = referenceEye
    self.referenceOrientation = referenceOrientation.normalized
    self.feet = feet
    self.heading = heading
    self.pitch = pitch
    self.cameraOffset = cameraOffset
  }
  public var worldFromTrackingRotation: simd_quatf {
    simd_quatf(angle: heading, axis: [0, 1, 0])
      * simd_quatf(angle: pitch, axis: [1, 0, 0]) * referenceOrientation.inverse
  }
  public var trackingFromWorldRotation: simd_quatf { worldFromTrackingRotation.inverse }
  public var eye: SIMD3<Float> { feet + [0, PlayerPhysics.eyeHeight, 0] + cameraOffset }
  public var worldOriginInTracking: SIMD3<Float> { referenceEye - inverseRotate(eye) * WorldScale.metresPerBlock }
  public func worldPoint(fromTracked point: SIMD3<Float>) -> SIMD3<Float> {
    eye + rotate(point - referenceEye) / WorldScale.metresPerBlock
  }
  public func trackedPoint(fromWorld point: SIMD3<Float>) -> SIMD3<Float> {
    referenceEye + inverseRotate(point - eye) * WorldScale.metresPerBlock
  }
  public func worldDirection(fromTracked direction: SIMD3<Float>) -> SIMD3<Float> {
    rotate(direction)
  }
  private func rotate(_ point: SIMD3<Float>) -> SIMD3<Float> {
    worldFromTrackingRotation.act(point)
  }
  private func inverseRotate(_ point: SIMD3<Float>) -> SIMD3<Float> {
    trackingFromWorldRotation.act(point)
  }
}
