import XCTest
import simd
@testable import WorldCore

final class ThirdPersonTests: XCTestCase {
  func testCameraOffsetPreservesReclinedHeadTrackingAndCharacterPosition() {
    let reference = simd_quatf(angle: -.pi / 2, axis: [1,0,0])
    let first = PlayerFrame(referenceEye: [0.2,1.3,-0.1], referenceOrientation: reference,
      feet: [100,30,-40], heading: 0.6, pitch: 0.3)
    var third = first; third.cameraOffset = [1,2,6]
    let tracked = first.referenceEye + [0.05,0.02,0.1]
    XCTAssertEqual(third.feet, first.feet)
    XCTAssertLessThan(simd_distance(third.worldPoint(fromTracked: tracked),
      first.worldPoint(fromTracked: tracked) + third.cameraOffset), 0.0001)
    XCTAssertLessThan(simd_distance(third.trackedPoint(fromWorld: third.worldPoint(fromTracked: tracked)), tracked), 0.0001)
    let neutral = reference.act([0,0,-1])
    XCTAssertLessThan(simd_distance(first.worldDirection(fromTracked: neutral), third.worldDirection(fromTracked: neutral)), 0.0001)
    XCTAssertEqual(third.trackingFromWorldRotation.vector, first.trackingFromWorldRotation.vector)
  }

  func testBoomPullsInAtWallsImmediatelyAndRecoversSmoothly() {
    var camera = ThirdPersonCamera()
    let eye = SIMD3<Float>(0.5,3.2,0.5)
    let open = camera.offset(eye: eye, heading: 0, pitch: 0, seconds: 1/90, block: { _ in .air })
    XCTAssertEqual(open, ThirdPersonCamera.boom)
    let wall: (BlockPosition)->Block = { $0.z == 3 ? .stone : .air }
    let shortened = camera.offset(eye: eye, heading: 0, pitch: 0, seconds: 1/90, block: wall)
    XCTAssertLessThanOrEqual(eye.z + shortened.z + ThirdPersonCamera.clearance, 3.001)
    XCTAssertGreaterThan(shortened.z, 2)
    let recovering = camera.offset(eye: eye, heading: 0, pitch: 0, seconds: 1/90, block: { _ in .air })
    XCTAssertGreaterThan(recovering.z, shortened.z)
    XCTAssertLessThan(recovering.z, open.z)
    for _ in 0..<120 { _ = camera.offset(eye: eye, heading: 0, pitch: 0, seconds: 1/60, block: { _ in .air }) }
    let restored = camera.offset(eye: eye, heading: 0, pitch: 0, seconds: 0, block: { _ in .air })
    XCTAssertEqual(restored.z, open.z, accuracy: 0.001)
  }

  func testBoomResweepsAfterSnapTurnsAndStopsAtCabinGlass() {
    var camera = ThirdPersonCamera()
    _ = camera.offset(eye: [0.5,3.2,0.5], heading: 0, pitch: 0, seconds: 1/90, block: { _ in .air })
    let wall: (BlockPosition)->Block = { $0.x == 2 ? .glass : .air }
    let turned = camera.offset(eye: [0.5,3.2,0.5], heading: .pi/2, pitch: 0, seconds: 1/90, block: wall)
    XCTAssertLessThan(turned.x + 0.5 + ThirdPersonCamera.clearance, 2.001)
    camera.reset()
    let cabin = camera.offset(eye: [0,3.2,0], heading: 0, pitch: 0, seconds: 1/90, block: { _ in .air },
      occupied: { point,radius in RocketCabin.walls.contains { $0.overlaps(center:point,radius:radius) }
        || RocketCabin.door.overlaps(center:point,radius:radius) })
    XCTAssertLessThan(cabin.z + ThirdPersonCamera.clearance, 3.801)
    XCTAssertGreaterThan(cabin.z, 3)
  }

  func testCameraAimingRespectsBodyReachAndInterveningWall() {
    let eye = SIMD3<Float>(0.5,3.5,0.5), camera = eye + ThirdPersonCamera.boom
    let world: (BlockPosition)->Block = { $0 == .init(0,3,-3) ? .stone : .air }
    let target = SIMD3<Float>(0.5,3.5,-2.9)
    let direction = ThirdPersonCamera.interactionDirection(eye: eye, camera: camera,
      forward: simd_normalize(target-camera), block: world)
    XCTAssertEqual(VoxelRaycast.cast(origin: eye, direction: direction, reach: 6, block: world)?.block, .init(0,3,-3))
    let distant: (BlockPosition)->Block = { $0 == .init(0,3,-10) ? .stone : .air }
    let farAim = ThirdPersonCamera.interactionDirection(eye: eye, camera: camera,
      forward: simd_normalize(SIMD3<Float>(0.5,3.5,-9.5)-camera), block: distant)
    XCTAssertNil(VoxelRaycast.cast(origin: eye, direction: farAim, reach: 6, block: distant))
    let obstruction: (BlockPosition)->Block = { $0.z == -1 ? .brick : world($0) }
    XCTAssertEqual(VoxelRaycast.cast(origin: eye, direction: direction, reach: 6, block: obstruction)?.block.z, -1)
  }

  func testPlayerSculptureHasFullBodyAndFitsPlayerScale() async {
    let geometry = await ActorMeshPreparation().prepare(.player)
    let model = geometry.sculpture
    for joint: ActorJoint in [.body,.head,.eyes,.mouth,.limb0,.limb1,.limb2,.limb3] {
      XCTAssertFalse(model.parts.first { $0.joint == joint }?.boxes.isEmpty ?? true)
    }
    XCTAssertGreaterThan(model.bounds.maximum.y, 1.6)
    XCTAssertLessThan(model.bounds.maximum.y, WorldScale.metres(PlayerPhysics.height) + 0.1)
    XCTAssertTrue(model.parts.flatMap(\.boxes).allSatisfy { model.colors.indices.contains($0.color) })
  }
}
