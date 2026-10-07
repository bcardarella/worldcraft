import XCTest
import simd
@testable import WorldCore

final class ScreenCameraTests: XCTestCase {
  func testFixedScreenCameraCentersAimAndSpatialSoundsAfterMovingAndLooking() {
    for feet: SIMD3<Float> in [[0, 30, 0], [-2800, 45, -5200], [240, 2200, -470]] {
      for heading: Float in [0, -.pi / 2, .pi, 0.7] {
        for pitch: Float in [-1.2, 0, 0.8] {
          let frame = PlayerFrame(referenceEye: .zero, feet: feet, heading: heading, pitch: pitch)
          let forward = frame.worldDirection(fromTracked: [0, 0, -1])
          let right = frame.worldDirection(fromTracked: [1, 0, 0])
          let centered = frame.trackedPoint(fromWorld: frame.eye + forward * 8)
          XCTAssertLessThan(simd_distance(centered, [0, 0, -4]), 0.001)
          XCTAssertLessThan(simd_length(frame.trackedPoint(fromWorld: frame.eye)), 0.0001)
          XCTAssertLessThan(simd_distance(frame.worldPoint(fromTracked: .zero), frame.eye), 0.0001)
          let sound = frame.trackedPoint(fromWorld: frame.eye + right * 6)
          XCTAssertLessThan(simd_distance(sound, [3, 0, 0]), 0.001)
        }
      }
    }
  }

  func testThirdPersonScreenViewKeepsTheAvatarBehindTheCrosshairAndAimWithinReach() {
    let feet = SIMD3<Float>(0.5, 0.26, 0.5)
    var camera = ThirdPersonCamera()
    var frame = PlayerFrame(referenceEye: .zero, feet: feet, heading: 0)
    frame.cameraOffset = camera.offset(eye: frame.eye, heading: 0, pitch: 0,
      seconds: 1 / 60, block: { _ in .air })
    let renderedPlayer = frame.trackedPoint(fromWorld: feet)
    XCTAssertLessThan(renderedPlayer.z, -3)
    XCTAssertLessThan(renderedPlayer.y, 0)
    XCTAssertEqual(frame.feet, feet)
    let eye = feet + [0, PlayerPhysics.eyeHeight, 0]
    let target = BlockPosition(0, 3, -3)
    let blocks: (BlockPosition) -> Block = { $0 == target ? .stone : .air }
    let direction = ThirdPersonCamera.interactionDirection(eye: eye,
      camera: frame.worldPoint(fromTracked: .zero),
      forward: simd_normalize(SIMD3<Float>(0.5, 3.5, -2.5) - frame.eye), block: blocks)
    XCTAssertEqual(VoxelRaycast.cast(origin: eye, direction: direction, reach: 6, block: blocks)?.block, target)
  }
}
