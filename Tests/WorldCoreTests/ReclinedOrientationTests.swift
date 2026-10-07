import simd
import XCTest
@testable import WorldCore

final class ReclinedOrientationTests: XCTestCase {
  func testNeutralHeadFacesHorizonWhenUprightReclinedOrOnSide() {
    let orientations: [simd_quatf] = [
      .init(angle: 0, axis: [0, 1, 0]),
      .init(angle: .pi / 2, axis: [1, 0, 0]),
      .init(angle: -.pi / 2, axis: [0, 0, 1]),
      simd_quatf(angle: 1.3, axis: [0, 1, 0])
        * simd_quatf(angle: 1.4, axis: [1, 0, 0])
        * simd_quatf(angle: -0.4, axis: [0, 0, 1]),
    ]
    for neutral in orientations {
      let frame = PlayerFrame(referenceEye: [0.4, 0.6, -0.7], referenceOrientation: neutral,
        feet: [80, 25, -90], heading: -.pi / 2)
      assertNear(frame.worldDirection(fromTracked: neutral.act([0, 0, -1])), [1, 0, 0])
      assertNear(frame.worldDirection(fromTracked: neutral.act([0, 1, 0])), [0, 1, 0])
      assertNear(frame.worldPoint(fromTracked: frame.referenceEye), frame.eye)
    }
  }

  func testRelativeHeadMotionAndControllerLookComposeAfterCalibration() {
    let neutral = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
    let headTurn = simd_quatf(angle: -.pi / 4, axis: [0, 1, 0])
    let frame = PlayerFrame(referenceEye: .zero, referenceOrientation: neutral,
      feet: .zero, heading: -.pi / 2, pitch: .pi / 6)
    let localLook = headTurn.act([0, 0, -1])
    let body = simd_quatf(angle: -.pi / 2, axis: [0, 1, 0])
      * simd_quatf(angle: .pi / 6, axis: [1, 0, 0])
    assertNear(frame.worldDirection(fromTracked: (neutral * headTurn).act([0, 0, -1])),
      body.act(localLook))
    XCTAssertGreaterThan(frame.worldDirection(fromTracked: neutral.act([0, 0, -1])).y, 0.49)
  }

  func testReclinedParallaxAndRendererTransformAgreeWithTargeting() {
    let neutral = simd_quatf(angle: 0.8, axis: [0, 1, 0])
      * simd_quatf(angle: 1.5, axis: [1, 0, 0])
      * simd_quatf(angle: -0.2, axis: [0, 0, 1])
    let frame = PlayerFrame(referenceEye: [0.2, 0.8, -0.5], referenceOrientation: neutral,
      feet: [120, 32, -180], heading: 0.7, pitch: 0.3)
    let body = simd_quatf(angle: frame.heading, axis: [0, 1, 0])
      * simd_quatf(angle: frame.pitch, axis: [1, 0, 0])
    let lean = SIMD3<Float>(0.12, 0.05, -0.08)
    assertNear(frame.worldPoint(fromTracked: frame.referenceEye + neutral.act(lean)) - frame.eye,
      body.act(lean) / WorldScale.metresPerBlock)
    for point: SIMD3<Float> in [[121, 35, -182], [0, 0, 0], [-90, 3, 55]] {
      let rendered = frame.worldOriginInTracking
        + frame.trackingFromWorldRotation.act(point * WorldScale.metresPerBlock)
      assertNear(rendered, frame.trackedPoint(fromWorld: point))
      assertNear(frame.worldPoint(fromTracked: rendered), point)
    }
  }

  func testRecenterAfterTrackingOriginChangesKeepsPlayerInPlace() {
    // A Crown recenter changes ARKit's origin as well as the neutral head pose.
    let feet = SIMD3<Float>(500, 240, -200)
    let after = PlayerFrame(referenceEye: [-1, 0.3, 2],
      referenceOrientation: .init(angle: .pi / 2, axis: [1, 0, 0]),
      feet: feet, heading: 0.9)
    assertNear(after.worldPoint(fromTracked: after.referenceEye), feet + [0, PlayerPhysics.eyeHeight, 0])
    assertNear(after.worldDirection(fromTracked: [0, 1, 0]),
      LocomotionInput.worldMovement([0, 1], heading: 0.9))
  }

  private func assertNear(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    for axis in 0..<3 { XCTAssertEqual(a[axis], b[axis], accuracy: 0.0002, file: file, line: line) }
  }
}
