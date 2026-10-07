import GameController
import Observation
import WorldCore

/// Mouse events are coalesced off the render executor. A stalled frame must not
/// leave hundreds of MainActor tasks replaying old motion after input stops.
final class MouseMotionMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var motion = SIMD2<Float>.zero
  private var scroll = 0
  private var enabled = false
  func reset(enabled: Bool) {
    lock.lock(); defer { lock.unlock() }
    self.enabled = enabled; motion = .zero; scroll = 0
  }
  func add(x: Float, y: Float) {
    lock.lock(); defer { lock.unlock() }
    guard enabled else { return }
    motion += [x, y]
  }
  func addScroll(_ y: Float) {
    lock.lock(); defer { lock.unlock() }
    guard enabled, abs(y) > 0.1 else { return }
    scroll = min(8, max(-8, scroll + (y > 0 ? -1 : 1)))
  }
  func take() -> (SIMD2<Float>, Int) {
    lock.lock(); defer { lock.unlock() }
    defer { motion = .zero; scroll = 0 }
    return (motion, scroll)
  }
}

struct InputFrame {
  var movement = SIMD2<Float>.zero
  var ascend: Float = 0
  var sprint = false
  var jump = false
  var mine = false
  var place = false
  var interact = false
  var vehicleInteract = false
  var horn = false
  var startRace = false
  var driveThrottle: Float = 0
  var driveSteering: Float = 0
  var driveBrake: Float = 0
  var boatHoist = false
  var boatAnchor = false
  var boatAutoTrim = false
  var boatTrim: Float = 0
  var togglePerspective = false
  var toggleFlight = false
  var togglePause = false
  var recenter = false
  var leave = false
  var turn: Float = 0
  var lookPitch: Float = 0
  var slotDelta = 0
  var selectedSlot: Int?
  var destinationDelta = 0
  var toggleInventory = false
  var inventoryMove = SIMD2<Int>.zero
  var inventoryConfirm = false
  var inventoryEquip = false
  var inventoryDrop = false
}

@MainActor @Observable
final class GameInput {
  private(set) var deviceDescription = "Connect a keyboard or gamepad"
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var previous = Set<String>()
  @ObservationIgnored private var suppressEdges = true
  @ObservationIgnored private var sailTrimArmed = false
  private(set) var runToggled = false
  @ObservationIgnored private var scrollDelta = 0
  @ObservationIgnored private var mouseDelta: Float = 0
  @ObservationIgnored private var mousePitchDelta: Float = 0
  @ObservationIgnored private var mouseTurnAccumulator: Float = 0
  @ObservationIgnored private var turnLatched = false
  @ObservationIgnored private var active = false
  @ObservationIgnored private var sceneActive = true
  @ObservationIgnored private var controller: GCController?
  @ObservationIgnored private var nextControllerCheck: TimeInterval = 0
  @ObservationIgnored private let inputQueue = DispatchQueue(label: "Worldcraft.device-input", qos: .userInteractive)
  @ObservationIgnored private let mouseMotion = MouseMotionMailbox()
  @ObservationIgnored private let controllersProvider: () -> [GCController]
  @ObservationIgnored private let currentControllerProvider: () -> GCController?
  @ObservationIgnored private let clock: () -> TimeInterval

  init(
    controllers: @escaping () -> [GCController] = { GCController.controllers() },
    currentController: @escaping () -> GCController? = { GCController.current },
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    controllersProvider = controllers
    currentControllerProvider = currentController
    self.clock = clock
  }

  func start() {
    guard !active else { return }
    active = true
    runToggled = false
    sceneActive = true
    reset()
    for name in [
      NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect,
      .GCControllerDidBecomeCurrent, .GCControllerDidStopBeingCurrent,
      .GCKeyboardDidConnect, .GCKeyboardDidDisconnect, .GCMouseDidConnect, .GCMouseDidDisconnect,
    ] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          Task { @MainActor in self?.connectDevices(reason: name.rawValue) }
        })
    }
    connectDevices(reason: "start")
  }

  func stop() {
    active = false
    runToggled = false
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    controller = nil
    GCMouse.mice().forEach {
      $0.mouseInput?.mouseMovedHandler = nil
      $0.mouseInput?.scroll.valueChangedHandler = nil
    }
    reset()
  }

  func reset() {
    previous.removeAll()
    // A button held across a focus/device change must not become a fresh jump,
    // pause, flight toggle or inventory action when input resumes.
    suppressEdges = true
    sailTrimArmed = false
    scrollDelta = 0
    mouseDelta = 0
    mousePitchDelta = 0
    mouseMotion.reset(enabled: active && sceneActive)
    mouseTurnAccumulator = 0
    turnLatched = true
  }

  func setSceneActive(_ value: Bool) {
    guard value != sceneActive else { return }
    sceneActive = value
    reset()
    if value { connectDevices(reason: "scene_active") }
    print("WORLDCRAFT_INPUT scene_active=\(value)")
  }

  private func refreshController(reason: String) {
    guard active else { return }
    let connected = controllersProvider().filter { $0.extendedGamepad != nil }
    let current = currentControllerProvider()
    let preferred = connected.first { $0 === current }
      ?? connected.first { $0 === controller } ?? connected.first
    if controller !== preferred {
      controller = preferred
      reset()
      print("WORLDCRAFT_INPUT source=\(preferred?.vendorName ?? "none") reason=\(reason) connected=\(connected.count)")
    }
    // Device delivery must keep consuming stick releases while RealityKit is
    // publishing a mesh. Poll an atomic capture below, never replay old events.
    if controller?.handlerQueue !== inputQueue { controller?.handlerQueue = inputQueue }
    if let controller {
      deviceDescription = controller.vendorName ?? "Gamepad connected"
    } else if GCKeyboard.coalesced != nil {
      deviceDescription =
        GCMouse.current == nil ? "Keyboard connected" : "Keyboard + mouse connected"
    } else {
      deviceDescription = "Connect a keyboard or gamepad"
    }
    nextControllerCheck = clock() + 1
  }

  private func connectDevices(reason: String) {
    guard active else { return }
    refreshController(reason: reason)
    GCKeyboard.coalesced?.handlerQueue = inputQueue
    for mouse in GCMouse.mice() {
      mouse.handlerQueue = inputQueue
      let mailbox = mouseMotion
      mouse.mouseInput?.mouseMovedHandler = { _, x, y in
        mailbox.add(x: x, y: y)
      }
      mouse.mouseInput?.scroll.valueChangedHandler = { _, _, y in
        mailbox.addScroll(y)
      }
    }
  }

  func poll(smoothTurning: Bool, turnSpeed: Float, deltaTime: Float, inventoryOpen: Bool = false, driving: Bool = false) -> InputFrame {
    guard active && sceneActive else { return InputFrame() }
    // Notifications handle ordinary transitions. Also recover if a framework
    // notification was missed, without enumerating every controller every frame.
    let current = currentControllerProvider()
    if (current != nil && current !== controller)
      || clock() >= nextControllerCheck
    {
      refreshController(reason: "poll_recovery")
    }
    let keyboard = GCKeyboard.coalesced?.keyboardInput?.capture() as? GCKeyboardInput
    let mouse = GCMouse.current?.mouseInput?.capture() as? GCMouseInput
    let snapshot = controller?.capture()
    let pad = snapshot?.extendedGamepad
    let motion = mouseMotion.take()
    mouseDelta = motion.0.x; mousePitchDelta = motion.0.y; scrollDelta = motion.1
    func key(_ code: GCKeyCode) -> Bool { keyboard?.button(forKeyCode: code)?.isPressed == true }
    var pressed = Set<String>()
    func edge(_ name: String, _ down: Bool) -> Bool {
      if down { pressed.insert(name) }
      return down && !suppressEdges && !previous.contains(name)
    }
    var frame = InputFrame()
    frame.toggleInventory = edge("inventory", key(.keyI) || (!inventoryOpen && pad?.dpad.up.isPressed == true))
    if inventoryOpen {
      if edge("bagLeft", key(.leftArrow) || key(.keyA) || pad?.dpad.left.isPressed == true || (pad?.leftThumbstick.xAxis.value ?? 0) < -0.55) { frame.inventoryMove.x -= 1 }
      if edge("bagRight", key(.rightArrow) || key(.keyD) || pad?.dpad.right.isPressed == true || (pad?.leftThumbstick.xAxis.value ?? 0) > 0.55) { frame.inventoryMove.x += 1 }
      if edge("bagUp", key(.upArrow) || key(.keyW) || pad?.dpad.up.isPressed == true || (pad?.leftThumbstick.yAxis.value ?? 0) > 0.55) { frame.inventoryMove.y -= 1 }
      if edge("bagDown", key(.downArrow) || key(.keyS) || pad?.dpad.down.isPressed == true || (pad?.leftThumbstick.yAxis.value ?? 0) < -0.55) { frame.inventoryMove.y += 1 }
      frame.inventoryConfirm = edge("bagConfirm", key(.returnOrEnter) || pad?.buttonA.isPressed == true)
      frame.inventoryEquip = edge("bagEquip", key(.keyR) || pad?.buttonX.isPressed == true)
      frame.inventoryDrop = edge("bagDrop", key(.deleteOrBackspace) || pad?.buttonY.isPressed == true)
    }
    let stick = LocomotionInput.movement([
      pad?.leftThumbstick.xAxis.value ?? 0, pad?.leftThumbstick.yAxis.value ?? 0,
    ])
    frame.movement.x = (key(.keyD) ? 1 : 0) - (key(.keyA) ? 1 : 0) + stick.x
    frame.movement.y = (key(.keyW) ? 1 : 0) - (key(.keyS) ? 1 : 0) + stick.y
    let length = (frame.movement.x * frame.movement.x + frame.movement.y * frame.movement.y)
      .squareRoot()
    if length > 1 { frame.movement /= length }
    // GTA-style driving: analog accelerator/brake triggers, steering on stick X.
    // Stick Y never adds throttle while steering through a bend.
    let throttle = (pad?.rightTrigger.value ?? 0) - (pad?.leftTrigger.value ?? 0)
    frame.driveThrottle = min(1, max(-1, (key(.keyW) ? 1 : 0) - (key(.keyS) ? 1 : 0)
      + throttle))
    frame.driveSteering = min(1, max(-1, (key(.keyD) ? 1 : 0) - (key(.keyA) ? 1 : 0) + stick.x))
    frame.driveBrake = key(.spacebar) ? 1 : (pad?.rightShoulder.value ?? 0)
    frame.boatHoist = edge("sailHoist", key(.keyH) || pad?.buttonA.isPressed == true)
    frame.boatAnchor = edge("sailAnchor", key(.spacebar) || pad?.rightShoulder.isPressed == true)
    frame.boatAutoTrim = edge("sailTrimAuto", key(.keyT) || pad?.leftShoulder.isPressed == true)
    let sheet = min(1,max(-1,throttle + (key(.openBracket) ? 1:0) - (key(.closeBracket) ? 1:0)))
    // L2 boards on foot and eases the sheet aboard. Require a release after
    // boarding/focus reset so that the boarding press cannot disable auto trim.
    if !driving || inventoryOpen { sailTrimArmed=false }
    else if abs(sheet)<0.05 { sailTrimArmed=true }
    frame.boatTrim = sailTrimArmed ? sheet:0
    let up = key(.spacebar) || pad?.buttonA.isPressed == true
    let down = key(.leftControl) || key(.rightControl) || pad?.buttonB.isPressed == true
    frame.ascend = (up ? 1 : 0) - (down ? 1 : 0)
    frame.jump = edge("jump", up)
    let runPressed = edge("run", key(.leftShift) || key(.rightShift) || pad?.leftThumbstickButton?.isPressed == true)
    frame.startRace = driving && edge("startRace",key(.keyE) || pad?.buttonX.isPressed == true)
    frame.horn = edge("horn", pad?.leftThumbstickButton?.isPressed == true) && driving && !inventoryOpen
    if runPressed, !inventoryOpen && !driving {
      runToggled.toggle()
    }
    frame.sprint = runToggled
    frame.mine =
      mouse?.leftButton.isPressed == true || key(.keyX) || (pad?.rightTrigger.value ?? 0) > 0.4
    frame.place =
      mouse?.rightButton?.isPressed == true || key(.keyZ) || pad?.buttonX.isPressed == true
    // Track the physical trigger edge in every mode: braking while exiting must
    // not become an accidental Use when the on-foot controls take over.
    let triggerUse = edge("triggerUse", (pad?.leftTrigger.value ?? 0) > 0.4)
    frame.interact = edge("interact", key(.keyR)) || (triggerUse && !driving)
    frame.vehicleInteract = edge("vehicle", pad?.buttonY.isPressed == true)
    frame.togglePerspective = edge("perspective", key(.keyV) || (!inventoryOpen && pad?.dpad.down.isPressed == true))
    frame.toggleFlight = edge("flight", key(.keyF)) || (frame.vehicleInteract && !driving)
    frame.togglePause = edge("pause", key(.escape) || pad?.buttonMenu.isPressed == true)
    frame.recenter = edge("recenter", key(.keyC) || pad?.rightThumbstickButton?.isPressed == true)
    frame.leave = edge("leave", key(.keyL) || pad?.buttonB.isPressed == true)
    frame.slotDelta = scrollDelta
    if edge("planetPrevious", key(.comma) || pad?.dpad.left.isPressed == true) {
      frame.destinationDelta -= 1
    }
    if edge("planetNext", key(.period) || pad?.dpad.right.isPressed == true) {
      frame.destinationDelta += 1
    }
    let buttons = snapshot?.physicalInputProfile.buttons
    func paddle(named names: [String], fallback: [String]) -> Bool {
      let named = names.compactMap { buttons?[$0] }
      let inputs = named.isEmpty ? fallback.compactMap { buttons?[$0] } : named
      return inputs.contains { $0.isPressed }
    }
    // Prefer side-labelled inputs. Legacy Xbox P3/P4 are on the player's
    // left, and P1/P2 on the right, as mapped by SDL's Apple controller driver.
    let leftNames: [String]
    let rightNames: [String]
    if #available(macOS 14.4, *) {
      leftNames = (0...1).map { GCButtonElementName.backLeftButton(position: $0).rawValue }
      rightNames = (0...1).map { GCButtonElementName.backRightButton(position: $0).rawValue }
    } else {
      leftNames = []; rightNames = []
    }
    let leftPaddle = paddle(
      named: leftNames,
      fallback: [GCInputXboxPaddleThree, GCInputXboxPaddleFour])
    let rightPaddle = paddle(
      named: rightNames,
      fallback: [GCInputXboxPaddleOne, GCInputXboxPaddleTwo])
    if edge("previous", (!driving && (key(.openBracket) || pad?.leftShoulder.isPressed == true)) || leftPaddle) {
      frame.slotDelta -= 1
    }
    if edge("next", (!driving && (key(.closeBracket) || pad?.rightShoulder.isPressed == true)) || rightPaddle) {
      frame.slotDelta += 1
    }
    for (i, code) in [GCKeyCode.one, .two, .three, .four, .five, .six, .seven, .eight, .nine].enumerated() {
      if edge("slot\(i)", key(code)) { frame.selectedSlot = i }
    }
    let turn = (key(.keyE) ? 1 : 0) - (key(.keyQ) ? 1 : 0) + (pad?.rightThumbstick.xAxis.value ?? 0)
    let pitch = (pad?.rightThumbstick.yAxis.value ?? 0)
      + (key(.upArrow) ? 1 : 0) - (key(.downArrow) ? 1 : 0)
    frame.lookPitch = LocomotionInput.lookPitchDelta(axis: pitch, speed: turnSpeed, deltaTime: deltaTime)
      + mousePitchDelta * 0.002
    if smoothTurning {
      frame.turn =
        -LocomotionInput.axis(turn) * deltaTime * turnSpeed * .pi / 180 - mouseDelta * 0.002
    } else {
      if abs(turn) < 0.3 { turnLatched = false }
      if abs(turn) > 0.65 && !turnLatched {
        frame.turn = turn > 0 ? -.pi / 6 : .pi / 6
        turnLatched = true
      }
      mouseTurnAccumulator += mouseDelta
      if abs(mouseTurnAccumulator) >= 85 {
        frame.turn += mouseTurnAccumulator > 0 ? -.pi / 6 : .pi / 6
        mouseTurnAccumulator = 0
      }
    }
    previous = pressed
    suppressEdges = false
    scrollDelta = 0
    mouseDelta = 0
    mousePitchDelta = 0
    return frame
  }

  func logDiagnostics(paused: Bool, tracking: String) {
    let pad = controller?.extendedGamepad
    // The event timestamp helps distinguish lost delivery from a deliberate
    // pause. A held stick need not emit new events, so silence is not a timeout.
    print("WORLDCRAFT_INPUT active=\(sceneActive) paused=\(paused) tracking=\(tracking) "
      + "controller=\(controller?.vendorName ?? "none") connected=\(controllersProvider().count) "
      + "event_time=\(controller?.physicalInputProfile.lastEventTimestamp ?? 0) "
      + "left=(\(pad?.leftThumbstick.xAxis.value ?? 0),\(pad?.leftThumbstick.yAxis.value ?? 0)) "
      + "right=(\(pad?.rightThumbstick.xAxis.value ?? 0),\(pad?.rightThumbstick.yAxis.value ?? 0))")
  }
}
