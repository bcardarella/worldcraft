import GameController
import XCTest
@testable import WorldInput

final class GameInputTests: XCTestCase {
  @MainActor func testControllerReleaseIsAvailableAfterRenderQueueIsOccupied() throws {
    let controller = GCController.withExtendedGamepad()
    let input = GameInput(controllers: { [controller] }, currentController: { controller })
    input.start(); defer { input.stop() }
    let pad = try XCTUnwrap(controller.extendedGamepad)
    pad.leftThumbstick.setValueForXAxis(0, yAxis: 1)
    XCTAssertEqual(poll(input).movement.y, 1)
    XCTAssertFalse(controller.handlerQueue === DispatchQueue.main)
    // Wait on MainActor deliberately: the release must be processed on the
    // device queue without running any main-actor input-delivery tasks.
    let completed = DispatchSemaphore(value: 0)
    controller.handlerQueue.async {
      controller.extendedGamepad?.leftThumbstick.setValueForXAxis(0, yAxis: 0)
      completed.signal()
    }
    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(poll(input).movement, .zero)
    for _ in 0..<120 { XCTAssertEqual(poll(input).movement, .zero) }
  }

  func testMouseEventsCoalesceWithoutQueuedMainActorWorkAndDiscardOnFocusLoss() {
    let mailbox = MouseMotionMailbox()
    mailbox.reset(enabled: true)
    DispatchQueue.concurrentPerform(iterations: 1_000) { _ in mailbox.add(x: 1, y: -1) }
    let sample = mailbox.take()
    XCTAssertEqual(sample.0, [1_000, -1_000]); XCTAssertEqual(mailbox.take().0, .zero)
    mailbox.add(x: 5, y: 6); mailbox.addScroll(-1)
    mailbox.reset(enabled: false); mailbox.add(x: 100, y: 100)
    XCTAssertEqual(mailbox.take().0, .zero); XCTAssertEqual(mailbox.take().1, 0)
  }
  @MainActor func testMostRecentlyUsedControllerSuppliesInput() {
    let first = GCController.withExtendedGamepad()
    let second = GCController.withExtendedGamepad()
    first.extendedGamepad!.leftThumbstick.setValueForXAxis(-1, yAxis: 0)
    second.extendedGamepad!.leftThumbstick.setValueForXAxis(1, yAxis: 0)
    var current: GCController? = first
    let input = GameInput(controllers: { [first, second] }, currentController: { current })
    input.start()
    defer { input.stop() }
    XCTAssertEqual(poll(input).movement.x, -1)
    // Recover even if the current-controller notification wasn't delivered.
    current = second
    XCTAssertEqual(poll(input).movement.x, 1)
  }

  @MainActor func testLosingCurrentStatusKeepsConnectedControllerDespiteListReordering() {
    let first = GCController.withExtendedGamepad()
    let second = GCController.withExtendedGamepad()
    first.extendedGamepad!.leftThumbstick.setValueForXAxis(-1, yAxis: 0)
    second.extendedGamepad!.leftThumbstick.setValueForXAxis(1, yAxis: 0)
    var current: GCController? = second
    var connected = [second, first]
    var time: TimeInterval = 0
    let input = GameInput(controllers: { connected }, currentController: { current }, clock: { time })
    input.start()
    defer { input.stop() }
    XCTAssertEqual(poll(input).movement.x, 1)
    current = nil
    connected = [first, second]
    time = 2
    XCTAssertEqual(poll(input).movement.x, 1)
  }

  @MainActor func testSceneReturnRestoresAxesWithoutReplayingHeldActions() {
    let controller = GCController.withExtendedGamepad()
    let pad = controller.extendedGamepad!
    let input = GameInput(controllers: { [controller] }, currentController: { controller })
    input.start()
    defer { input.stop() }
    _ = poll(input)
    pad.buttonY.setValue(1)
    pad.leftThumbstick.setValueForXAxis(0, yAxis: 1)
    XCTAssertTrue(poll(input).toggleFlight)
    input.setSceneActive(false)
    XCTAssertEqual(poll(input).movement, .zero)
    input.setSceneActive(true)
    let resumed = poll(input)
    XCTAssertEqual(resumed.movement.y, 1)
    XCTAssertFalse(resumed.toggleFlight)
    XCTAssertFalse(poll(input).toggleFlight)
    pad.buttonY.setValue(0)
    _ = poll(input)
    pad.buttonY.setValue(1)
    XCTAssertTrue(poll(input).toggleFlight)
  }

  @MainActor func testMissedDisconnectAndReconnectRecoverWithoutStickyInput() {
    let controller = GCController.withExtendedGamepad()
    controller.extendedGamepad!.leftThumbstick.setValueForXAxis(1, yAxis: 0)
    var connected = [controller]
    var time: TimeInterval = 0
    let input = GameInput(controllers: { connected }, currentController: { nil }, clock: { time })
    input.start()
    defer { input.stop() }
    XCTAssertEqual(poll(input).movement.x, 1)
    connected = []
    time = 2
    XCTAssertEqual(poll(input).movement, .zero)
    let replacement = GCController.withExtendedGamepad()
    replacement.extendedGamepad!.leftThumbstick.setValueForXAxis(-1, yAxis: 0)
    connected = [replacement]
    time = 4
    XCTAssertEqual(poll(input).movement.x, -1)
  }

  @MainActor func testHeldAnalogStickDoesNotExpireWithoutNewEvents() {
    let controller = GCController.withExtendedGamepad()
    var time: TimeInterval = 0
    let input = GameInput(controllers: { [controller] }, currentController: { controller }, clock: { time })
    input.start()
    defer { input.stop() }
    controller.extendedGamepad!.leftThumbstick.setValueForXAxis(0, yAxis: 0.6)
    let movement = poll(input).movement
    XCTAssertGreaterThan(movement.y, 0)
    time = 120
    XCTAssertEqual(poll(input).movement, movement)
  }

  @MainActor func testRightStickPitchRemainsAnalogAndClickRecentersOnce() {
    let controller = GCController.withExtendedGamepad()
    let pad = controller.extendedGamepad!
    let input = GameInput(controllers: { [controller] }, currentController: { controller })
    input.start()
    defer { input.stop() }
    _ = poll(input)
    pad.rightThumbstick.setValueForXAxis(0, yAxis: 0.4)
    let gentle = poll(input).lookPitch
    pad.rightThumbstick.setValueForXAxis(0, yAxis: 1)
    XCTAssertGreaterThan(poll(input).lookPitch, gentle)
    XCTAssertGreaterThan(gentle, 0)
    pad.rightThumbstickButton?.setValue(1)
    XCTAssertTrue(poll(input).recenter)
    XCTAssertFalse(poll(input).recenter)
  }

  @MainActor func testDrivingRetainsAnalogTriggerAndStickValues() {
    let controller = GCController.withExtendedGamepad()
    let pad = controller.extendedGamepad!
    let input = GameInput(controllers: { [controller] }, currentController: { controller })
    input.start()
    defer { input.stop() }
    pad.rightTrigger.setValue(0.25)
    pad.leftThumbstick.setValueForXAxis(0.4, yAxis: 0)
    let gentle = poll(input)
    XCTAssertEqual(gentle.driveThrottle, 0.25, accuracy: 0.001)
    XCTAssertGreaterThan(gentle.driveSteering, 0)
    XCTAssertLessThan(gentle.driveSteering, 0.5)
    pad.rightTrigger.setValue(1)
    pad.leftThumbstick.setValueForXAxis(1, yAxis: 0)
    XCTAssertEqual(poll(input).driveThrottle, 1)
    XCTAssertEqual(poll(input).driveSteering, 1)
    pad.rightTrigger.setValue(0); pad.leftTrigger.setValue(0.6)
    XCTAssertEqual(poll(input).driveThrottle, -0.6, accuracy: 0.001)
    pad.rightShoulder.setValue(1)
    XCTAssertEqual(poll(input).driveBrake, 1)
    pad.rightThumbstick.setValueForXAxis(0, yAxis: 0.5)
    XCTAssertGreaterThan(poll(input).lookPitch, 0)
  }

  @MainActor func testRunIsEdgeTriggeredAndSurvivesReleaseFocusAndInventory() {
    let controller = GCController.withExtendedGamepad(), pad = controller.extendedGamepad!
    let input = GameInput(controllers: { [controller] }, currentController: { controller })
    input.start(); defer { input.stop() }
    XCTAssertFalse(poll(input).sprint)
    pad.leftThumbstickButton?.setValue(1)
    XCTAssertTrue(poll(input).sprint); XCTAssertTrue(poll(input).sprint)
    pad.leftThumbstickButton?.setValue(0)
    XCTAssertTrue(poll(input).sprint)
    input.setSceneActive(false); input.setSceneActive(true)
    XCTAssertTrue(poll(input).sprint)
    pad.leftThumbstickButton?.setValue(1)
    XCTAssertTrue(input.poll(smoothTurning:true,turnSpeed:90,deltaTime:1/90,inventoryOpen:true).sprint)
    input.reset()
    XCTAssertTrue(poll(input).sprint) // Held across closing a menu is not another press.
    pad.leftThumbstickButton?.setValue(0); _ = poll(input)
    pad.leftThumbstickButton?.setValue(1)
    XCTAssertFalse(poll(input).sprint)
    pad.leftThumbstickButton?.setValue(0); _ = poll(input)
    pad.leftThumbstickButton?.setValue(1); XCTAssertTrue(poll(input).sprint)
    input.stop(); input.start()
    XCTAssertFalse(poll(input).sprint) // A new play session starts walking.
  }

  @MainActor func testLeftTriggerUsesOnceOnFootAndNeverPlaces() {
    let controller = GCController.withExtendedGamepad(), pad = controller.extendedGamepad!
    let input = GameInput(controllers: { [controller] }, currentController: { controller })
    input.start(); defer { input.stop() }
    _ = poll(input)
    pad.leftTrigger.setValue(0.2)
    XCTAssertFalse(poll(input).interact)
    pad.leftTrigger.setValue(0.7)
    let use = poll(input)
    XCTAssertTrue(use.interact); XCTAssertFalse(use.place); XCTAssertEqual(use.driveThrottle, -0.7, accuracy: 0.001)
    XCTAssertFalse(poll(input).interact)
    input.reset(); XCTAssertFalse(poll(input).interact)
    pad.leftTrigger.setValue(0); _ = poll(input)
    pad.leftTrigger.setValue(1); XCTAssertTrue(poll(input).interact)
    pad.leftTrigger.setValue(0); pad.buttonX.setValue(1)
    let place = poll(input)
    XCTAssertTrue(place.place); XCTAssertFalse(place.interact); XCTAssertEqual(place.driveThrottle, 0)
  }

  @MainActor func testDpadDownSwitchesCameraOnceAndDoesNotTriggerInsideInventory() {
    let controller = GCController.withExtendedGamepad(), pad = controller.extendedGamepad!
    let input = GameInput(controllers: { [controller] }, currentController: { controller })
    input.start(); defer { input.stop() }
    _ = poll(input)
    pad.dpad.setValueForXAxis(0,yAxis:-1)
    XCTAssertTrue(poll(input).togglePerspective); XCTAssertFalse(poll(input).togglePerspective)
    input.reset()
    XCTAssertFalse(poll(input).togglePerspective)
    pad.dpad.setValueForXAxis(0,yAxis:0); _ = poll(input)
    pad.dpad.setValueForXAxis(0,yAxis:-1)
    let bag = input.poll(smoothTurning:true,turnSpeed:90,deltaTime:1/90,inventoryOpen:true)
    XCTAssertFalse(bag.togglePerspective); XCTAssertEqual(bag.inventoryMove, [0,1])
    input.reset(); XCTAssertFalse(poll(input).togglePerspective)
  }

  @MainActor func testSailingUsesAnalogTrimAndSeparateEdgeControls() {
    let controller=GCController.withExtendedGamepad(),pad=controller.extendedGamepad!
    let input=GameInput(controllers:{[controller]},currentController:{controller})
    input.start();defer{input.stop()}
    func sail()->InputFrame {input.poll(smoothTurning:true,turnSpeed:90,deltaTime:1/90,driving:true)}
    _ = poll(input)
    pad.leftTrigger.setValue(0.7)
    XCTAssertTrue(poll(input).interact)
    input.reset() // Taking the helm resets input while L2 is still held.
    XCTAssertEqual(sail().boatTrim,0)
    XCTAssertEqual(sail().boatTrim,0)
    pad.leftTrigger.setValue(0);_ = sail()
    pad.rightTrigger.setValue(0.35);pad.leftThumbstick.setValueForXAxis(0.5,yAxis:0)
    let trim=sail()
    XCTAssertEqual(trim.boatTrim,0.35,accuracy:0.001);XCTAssertFalse(trim.interact)
    XCTAssertEqual(trim.movement.y,0);XCTAssertGreaterThan(trim.driveSteering,0)
    pad.rightTrigger.setValue(0);pad.leftTrigger.setValue(0.6)
    XCTAssertEqual(sail().boatTrim,-0.6,accuracy:0.001)
    pad.rightShoulder.setValue(1);let anchor=sail()
    XCTAssertTrue(anchor.boatAnchor);XCTAssertEqual(anchor.slotDelta,0);XCTAssertFalse(sail().boatAnchor)
    pad.leftShoulder.setValue(1);let automatic=sail()
    XCTAssertTrue(automatic.boatAutoTrim);XCTAssertEqual(automatic.slotDelta,0)
    pad.buttonA.setValue(1);XCTAssertTrue(sail().boatHoist);XCTAssertFalse(sail().boatHoist)
    input.reset();let reset=sail()
    XCTAssertFalse(reset.boatHoist);XCTAssertFalse(reset.boatAnchor);XCTAssertFalse(reset.boatAutoTrim)
    XCTAssertEqual(reset.boatTrim,0)
  }

  @MainActor func testGTADrivingDoesNotUseTriggerOrHotbarOrSprintActions() {
    let controller = GCController.withExtendedGamepad(), pad = controller.extendedGamepad!
    let input = GameInput(controllers: { [controller] }, currentController: { controller })
    input.start(); defer { input.stop() }
    func drive() -> InputFrame { input.poll(smoothTurning:true,turnSpeed:90,deltaTime:1/90,driving:true) }
    _ = drive()
    pad.leftTrigger.setValue(0.7)
    let brake = drive()
    XCTAssertEqual(brake.driveThrottle, -0.7, accuracy: 0.001)
    XCTAssertFalse(brake.interact)
    pad.rightShoulder.setValue(1)
    let handbrake = drive()
    XCTAssertEqual(handbrake.driveBrake, 1); XCTAssertEqual(handbrake.slotDelta, 0)
    pad.leftThumbstickButton?.setValue(1)
    let horn = drive()
    XCTAssertTrue(horn.horn); XCTAssertFalse(horn.sprint); XCTAssertFalse(drive().horn)
    pad.buttonY.setValue(1)
    let exit = drive()
    XCTAssertTrue(exit.vehicleInteract); XCTAssertFalse(exit.toggleFlight)
    XCTAssertFalse(drive().vehicleInteract)
    // A held brake must not become a new use, even without resetting the adapter.
    XCTAssertFalse(poll(input).interact)
    pad.leftTrigger.setValue(0); pad.leftThumbstick.setValueForXAxis(0.8,yAxis:1)
    let turn = drive()
    XCTAssertEqual(turn.driveThrottle, 0); XCTAssertGreaterThan(turn.driveSteering, 0)
  }

  @MainActor func testJumpAndBackpackUseIndependentGamepadButtons() {
    let controller = GCController.withExtendedGamepad(), pad = controller.extendedGamepad!
    let input = GameInput(controllers: { [controller] }, currentController: { controller })
    input.start(); defer { input.stop() }
    _ = poll(input)

    pad.buttonA.setValue(1)
    let jump = poll(input)
    XCTAssertTrue(jump.jump)
    XCTAssertFalse(jump.toggleInventory)
    XCTAssertFalse(jump.inventoryConfirm)
    let held = poll(input)
    XCTAssertFalse(held.jump)
    XCTAssertFalse(held.toggleInventory)

    pad.buttonA.setValue(0); _ = poll(input)
    pad.dpad.setValueForXAxis(0, yAxis: 1)
    let backpack = poll(input)
    XCTAssertTrue(backpack.toggleInventory)
    XCTAssertFalse(backpack.jump)
    XCTAssertFalse(backpack.inventoryConfirm)
    XCTAssertFalse(poll(input).toggleInventory)
  }

  @MainActor func testHeldAAfterUIRoutingChangeWaitsForReleaseBeforeJumping() {
    let controller = GCController.withExtendedGamepad(), pad = controller.extendedGamepad!
    let input = GameInput(controllers: { [controller] }, currentController: { controller })
    input.start(); defer { input.stop() }
    _ = poll(input)
    // A may still be down after entering from the lobby or selecting an item.
    pad.buttonA.setValue(1)
    input.reset()
    for _ in 0..<3 {
      let held = poll(input)
      XCTAssertFalse(held.jump)
      XCTAssertFalse(held.toggleInventory)
    }
    pad.buttonA.setValue(0); _ = poll(input)
    pad.buttonA.setValue(1)
    let freshPress = poll(input)
    XCTAssertTrue(freshPress.jump)
    XCTAssertFalse(freshPress.toggleInventory)
  }

  @MainActor func testInventoryOpeningDoesNotReplayHeldDpadNavigation() {
    let controller = GCController.withExtendedGamepad(), pad = controller.extendedGamepad!
    let input = GameInput(controllers: { [controller] }, currentController: { controller })
    input.start()
    defer { input.stop() }
    _ = poll(input)
    pad.dpad.setValueForXAxis(0, yAxis: 1)
    XCTAssertTrue(poll(input).toggleInventory)
    input.reset() // The same transition used when opening the immersive attachment.
    func menu() -> InputFrame { input.poll(smoothTurning: true, turnSpeed: 90, deltaTime: 1 / 90, inventoryOpen: true) }
    XCTAssertEqual(menu().inventoryMove, .zero)
    XCTAssertEqual(menu().inventoryMove, .zero)
    XCTAssertFalse(menu().toggleInventory)
    pad.dpad.setValueForXAxis(0, yAxis: 0)
    _ = menu()
    pad.dpad.setValueForXAxis(0, yAxis: -1)
    XCTAssertEqual(menu().inventoryMove, [0, 1])
    XCTAssertEqual(menu().inventoryMove, .zero)
    pad.dpad.setValueForXAxis(1, yAxis: 0)
    XCTAssertEqual(menu().inventoryMove, [1, 0])
  }

  @MainActor func testInventoryConfirmEquipDropAndCloseAreEdges() {
    let controller = GCController.withExtendedGamepad(), pad = controller.extendedGamepad!
    let input = GameInput(controllers: { [controller] }, currentController: { controller })
    input.start()
    defer { input.stop() }
    func menu() -> InputFrame { input.poll(smoothTurning: true, turnSpeed: 90, deltaTime: 1 / 90, inventoryOpen: true) }
    _ = menu()
    pad.buttonA.setValue(1)
    XCTAssertTrue(menu().inventoryConfirm); XCTAssertFalse(menu().inventoryConfirm)
    pad.buttonX.setValue(1)
    XCTAssertTrue(menu().inventoryEquip); XCTAssertFalse(menu().inventoryEquip)
    pad.buttonY.setValue(1)
    XCTAssertTrue(menu().inventoryDrop); XCTAssertFalse(menu().inventoryDrop)
    pad.rightShoulder.setValue(1)
    XCTAssertEqual(menu().slotDelta, 1); XCTAssertEqual(menu().slotDelta, 0)
    pad.leftThumbstick.setValueForXAxis(-0.8, yAxis: 0)
    XCTAssertEqual(menu().inventoryMove, [-1, 0]); XCTAssertEqual(menu().inventoryMove, .zero)
    pad.buttonB.setValue(1)
    XCTAssertTrue(menu().leave); XCTAssertFalse(menu().leave)
  }

  @MainActor private func poll(_ input: GameInput) -> InputFrame {
    input.poll(smoothTurning: true, turnSpeed: 90, deltaTime: 1 / 90)
  }
}
