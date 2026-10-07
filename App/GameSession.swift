import ARKit
import Observation
import QuartzCore
import RealityKit
import SwiftUI
import WorldCore

@MainActor @Observable
final class GameSession {
  var seedText = "8192"
  var smoothTurning = true
  var turnSpeed: Float = 90
  var headDirectedMovement = false
  var showHands = true
  var thirdPerson = UserDefaults.standard.bool(forKey: "worldcraft.thirdPerson") {
    didSet {
      UserDefaults.standard.set(thirdPerson, forKey: "worldcraft.thirdPerson")
      camera.reset()
    }
  }
  var jevEnabled = true {
    didSet {
      UserDefaults.standard.set(!jevEnabled, forKey: "worldcraft.jevDisabled")
      configureJev()
    }
  }
  var reasoningEnabled = true {
    didSet { UserDefaults.standard.set(!reasoningEnabled, forKey: "worldcraft.reasoningDisabled"); configureReasoning() }
  }
  let reasoningHourlyLimit = 0.05
  private(set) var reasoningKeyConfigured = false
  private(set) var reasoningHasSavedKey = false
  private(set) var reasoningConfigurationError: String?
  private(set) var reasoningStatus = "Reasoning ready when needed"
  @ObservationIgnored private var autonomousDirty = false
  @ObservationIgnored private var lastAgencySave: Double = 0
  private(set) var jevKeyConfigured = false
  private(set) var jevHasSavedKey = false
  private(set) var jevConfigurationError: String?
  private(set) var npcDecisionStatus = "Local life · add a TypeSafe key for Jev"
  private(set) var npcPrompt = ""
  private(set) var ridePrompt = ""
  private(set) var hayHayCount = 0
  @ObservationIgnored private var hayHays = HayHayCollection()
  @ObservationIgnored private var lastCompanionCheck = -Double.infinity
  @ObservationIgnored private var mount: MountedRide?
  @ObservationIgnored private var mountCandidate: MountCandidate?
  private(set) var npcConversation = ""
  private(set) var biomeName = ""
  @ObservationIgnored private var lastNPCFocus: Double = 0
  var showPerformance = false {
    didSet {
      UserDefaults.standard.set(showPerformance, forKey: "worldcraft.performanceHUD")
      if oldValue != showPerformance { resetPerformanceMeasurement() }
    }
  }
  private(set) var performanceSummary = "Measuring…"
  // Session-only diagnostic: does not reduce normal graphics quality or persist
  // a disabled effect across launches. Torch lights and sounds stay independent.
  var fireParticlesEnabled = true {
    didSet {
      renderer.fire.particlesEnabled = fireParticlesEnabled
      if oldValue != fireParticlesEnabled { resetPerformanceMeasurement() }
    }
  }
  private(set) var performanceDetail = ""
  @ObservationIgnored private var frameTiming = FrameTiming()
  @ObservationIgnored private var logTiming = FrameTiming(capacity: 900)
  @ObservationIgnored private var lastPerformanceUpdate: Double = 0
  @ObservationIgnored private var performanceWindowStart: Double?
  @ObservationIgnored private var performanceRun = UUID().uuidString
  @ObservationIgnored private var performanceSequence = 0
  var renderDistance = DrawDistance.standard {
    didSet {
      let clamped = DrawDistance.clamp(renderDistance)
      // Observation moves observers onto backing storage. Assigning the same
      // value unconditionally would re-enter this observer through its setter.
      if renderDistance != clamped { renderDistance = clamped }
      UserDefaults.standard.set(clamped, forKey: "worldcraft.drawDistance")
    }
  }
  var detailDistance = DrawDistance.detailedRadius {
    didSet {
      let clamped = DrawDistance.clampDetail(detailDistance)
      if detailDistance != clamped { detailDistance = clamped }
      UserDefaults.standard.set(clamped, forKey: "worldcraft.detailDistance")
    }
  }
  var musicVolume: Float = 0.45
  var effectsVolume: Float = 0.8
  private(set) var isImmersed = false
  private(set) var isPaused = false
  private(set) var isLoading = false
  private(set) var isStopping = false
  private(set) var status = "A world of your own."
  private(set) var errorMessage: String?
  private(set) var selectedSlot = 0
  private(set) var inventory = Inventory()
  private(set) var inventoryOpen = false
  private(set) var inventoryCursor = 0
  private(set) var inventorySource: Int?
  private(set) var gatheringProgress: Float = 0
  private(set) var gatheringNotice = ""
  private(set) var throwingStrength:Float=0
  private(set) var throwingAccuracy:Float=0
  @ObservationIgnored private var baseballThrow=BaseballThrow()
  @ObservationIgnored private var throwSequence=0
  @ObservationIgnored private var mining = MiningProgress()
  @ObservationIgnored private var actionButtonsArmed = true
  @ObservationIgnored private var lastMiningSwing: Double = 0
  @ObservationIgnored private var lastAction: Double = 0
  @ObservationIgnored private var noticeUntil: Double = 0
  @ObservationIgnored private var plantEdits: [BlockPosition: PlantEdit] = [:]
  private(set) var coordinates = "0 / 0 / 0"
  private(set) var chunkCount = 0
  private(set) var flying = false
  private(set) var targetName = ""
  private(set) var exitRequested = false
  private(set) var worldClock = "09:07"
  private(set) var tideDescription = "Rising tide"
  private(set) var driving = false
  private var inVehicle: Bool { renderer.vehicles.isDriving || renderer.boats.isSailing }
  private(set) var drivingSpeed: Float = 0
  private(set) var flightSpeed: Float = 0
  private(set) var animalCount = 0
  private(set) var dinosaurCount = 0
  private(set) var dinosaurMessage = ""
  private(set) var isInSpace = false
  private(set) var planetName = "Mossmere"
  private(set) var destinationName = "Saffron"
  private(set) var navigation = ""
  private(set) var settlementName = ""
  private(set) var residentCount = 0
  private(set) var rocketStatus = ""
  let input = GameInput()

  @ObservationIgnored let renderer = WorldRenderer()
  #if os(visionOS)
  @ObservationIgnored let headAnchor = AnchorEntity(.head)
  #else
  // A fixed virtual camera uses the same inverse world transform as the headset.
  // Its origin also keeps hands, overlays and spatial audio in the same frame.
  @ObservationIgnored let headAnchor = Entity()
  @ObservationIgnored let screenCamera = PerspectiveCamera()
  #endif
  @ObservationIgnored private let audio = WorldAudio()
  #if os(visionOS)
  @ObservationIgnored private var tracking = WorldTrackingProvider()
  @ObservationIgnored private var arSession = ARKitSession()
  #endif
  private var trackingStatus: String {
    #if os(visionOS)
    String(describing: tracking.state)
    #else
    "virtual_camera"
    #endif
  }
  @ObservationIgnored private let saveStore = SaveStore()
  @ObservationIgnored private var player = PlayerPhysics(position: [0, 30, 0])
  @ObservationIgnored private var environment = WorldEnvironment()
  @ObservationIgnored private var doubleJump = DoubleJumpGesture()
  @ObservationIgnored private let hands = PlayerHands()
  @ObservationIgnored private let avatar = PlayerAvatarRenderer()
  @ObservationIgnored private var camera = ThirdPersonCamera()
  @ObservationIgnored private let universe = UniverseRenderer()
  @ObservationIgnored private let rockets = RocketRenderer()
  @ObservationIgnored private let elevators = ElevatorRenderer()
  @ObservationIgnored private var rocketJourney: RocketJourney?
  @ObservationIgnored private var rocketSearch: Task<Void, Never>?
  @ObservationIgnored private var rocketLaunch: Task<Void, Never>?
  @ObservationIgnored private var lifeTransition: Task<Void, Never>?
  @ObservationIgnored private var rocketRegion: ChunkCoordinate?
  @ObservationIgnored private var rocketLocalSite: UInt64?
  @ObservationIgnored private var rocketNotice = ""
  @ObservationIgnored private var rocketWelcomePrepared = false
  @ObservationIgnored private let underwaterOverlay = ModelEntity()
  @ObservationIgnored private let cloudOverlay = ModelEntity()
  @ObservationIgnored private let biteOverlay = ModelEntity()
  @ObservationIgnored private var biteUntil: Double = 0
  @ObservationIgnored private var lastAnimalSound: Double = 0
  @ObservationIgnored private var lastAudioScene: Double = -.infinity
  @ObservationIgnored private var lastSwimSound: Double = 0
  @ObservationIgnored private var lastNPCSound: Double = 0
  @ObservationIgnored private var lastLapSound = 0
  @ObservationIgnored private var lastCountdown = -1
  @ObservationIgnored private var lastCarSound: Double = 0
  @ObservationIgnored private var lastWake: Double = 0
  @ObservationIgnored private var wasTouchingWater = false
  @ObservationIgnored private var swimming = false
  @ObservationIgnored private var underwaterAppearance: SIMD4<Float>?
  @ObservationIgnored private var baseSeed: UInt64 = 8192
  @ObservationIgnored private var solarSystem = SolarSystem(seed: 8192)
  @ObservationIgnored private var planetIndex = 0
  @ObservationIgnored private var destinationIndex = 1
  @ObservationIgnored private var space: SpaceFlight?
  @ObservationIgnored private var atmosphereTransition: AtmosphereTransition?
  @ObservationIgnored private var arrivingSpace: SpaceFlight?
  @ObservationIgnored private var planetProgress: [Int: SavedPlanet] = [:]
  @ObservationIgnored private var seed: UInt64 = 8192
  @ObservationIgnored private var edits: [BlockPosition: Block] = [:]
  @ObservationIgnored private var heading: Float = 0
  @ObservationIgnored private var viewPitch: Float = 0
  @ObservationIgnored private var systemTime: Double = 0
  @ObservationIgnored private var reference: SIMD3<Float>?
  @ObservationIgnored private var referenceOrientation = simd_quatf(angle: 0, axis: [0, 1, 0])
  @ObservationIgnored private var isRecentering = false
  @ObservationIgnored private var subscription: EventSubscription?
  @ObservationIgnored private var lastActionTime: Double = 0
  @ObservationIgnored private var lastStepPosition = SIMD3<Float>.zero
  @ObservationIgnored private var lastSaveTime: Double = 0
  @ObservationIgnored private var lastHUDTime: Double = 0
  @ObservationIgnored private var ambienceCenter: ChunkCoordinate?
  @ObservationIgnored private var restoredSave: WorldSave?
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private var trackingTask: Task<Void, Never>?
  @ObservationIgnored private let preparation = ScenePreparation()
  @ObservationIgnored private var startupWatchdog: Task<Void, Never>?
  @ObservationIgnored private var startupTime: Double = 0
  @ObservationIgnored private var startupFrames = 0
  @ObservationIgnored private var firstWorldFrame = false
  @ObservationIgnored private var lifecycle = UUID()

  var seedIsValid: Bool { UInt64(seedText) != nil }
  var selectedItem: InventoryItem? { inventory[selectedSlot]?.item }
  var inventorySuffix: String { solarSystem.planets[planetIndex].style.assetSuffix }

  init() {
    showPerformance = UserDefaults.standard.bool(forKey: "worldcraft.performanceHUD")
    let saved = UserDefaults.standard.object(forKey: "worldcraft.drawDistance") as? Int
    renderDistance = DrawDistance.clamp(saved ?? DrawDistance.standard)
    detailDistance = DrawDistance.clampDetail(
      UserDefaults.standard.object(forKey: "worldcraft.detailDistance") as? Int ?? DrawDistance.detailedRadius)
    jevEnabled = !UserDefaults.standard.bool(forKey: "worldcraft.jevDisabled")
    configureJev()
    reasoningEnabled = !UserDefaults.standard.bool(forKey: "worldcraft.reasoningDisabled")
    configureReasoning()
    renderer.life.commitEffects = { [weak self] effects in self?.commitLifeEffects(effects) ?? false }
    renderer.entityObstacleSnapshot = { [weak rockets] in rockets?.port }
    renderer.entityObstacle = { [weak rockets] in rockets?.port?.blocksTraffic($0) ?? false }
  }

  private func configureJev() {
    let key = JevCredentials.load()
    jevKeyConfigured = key != nil
    jevHasSavedKey = JevCredentials.hasSavedKey
    renderer.settlementLife.configureJev(key: key, enabled: jevEnabled)
    renderer.vehicles.configureJev(key:key,enabled:jevEnabled)
    npcDecisionStatus = renderer.settlementLife.decisionStatus
  }
  func saveJevKey(_ key: String) -> Bool {
    do {
      try JevCredentials.save(key); jevConfigurationError = nil
      configureJev(); return true
    } catch { jevConfigurationError = "Could not save the key in Keychain."; return false }
  }
  func removeJevKey() { JevCredentials.remove(); configureJev() }

  private func configureReasoning() {
    let key = OpenRouterCredentials.load()
    reasoningKeyConfigured = key != nil; reasoningHasSavedKey = OpenRouterCredentials.hasSavedKey
    renderer.deliberation.configure(key: key, enabled: reasoningEnabled, hourlyLimit: reasoningHourlyLimit)
    reasoningStatus = renderer.deliberation.status
  }
  func saveReasoningKey(_ key: String) -> Bool {
    do {
      try OpenRouterCredentials.save(key); reasoningConfigurationError = nil
      configureReasoning(); return true
    } catch { reasoningConfigurationError = "Could not save the key in Keychain."; return false }
  }
  func removeReasoningKey() { OpenRouterCredentials.remove(); configureReasoning() }

  func restore() async {
    do {
      restoredSave = try await saveStore.load()
      if let save = restoredSave {
        seedText = String(save.seed)
        status = "Your world is ready to return to."
      }
    } catch { errorMessage = "The saved world could not be read: \(error.localizedDescription)" }
  }

  func prepare() throws {
    guard let chosenSeed = UInt64(seedText) else { return }
    baseSeed = chosenSeed
    solarSystem = .init(seed: chosenSeed)
    planetIndex = restoredSave?.seed == chosenSeed ? restoredSave?.planetIndex ?? 0 : 0
    let planet = solarSystem.planets[planetIndex]
    seed = planet.seed
    lifecycle = UUID()
    preparation.cancel()
    startupWatchdog?.cancel()
    startupFrames = 0; firstWorldFrame = false
    let generator = planet.terrain
    environment = .init()
    doubleJump.reset()
    camera.reset(); avatar.reset()
    space = nil
    inventory = .init(); inventoryOpen = false; inventorySource = nil
    plantEdits = [:]; mining.reset(); gatheringProgress = 0; gatheringNotice = ""
    autonomousDirty = false; lastAgencySave = 0
    actionButtonsArmed = false
    rocketJourney = nil
    rocketRegion = nil
    rocketLocalSite = nil
    rocketWelcomePrepared = false
    rocketSearch?.cancel(); rocketSearch = nil; rocketLaunch?.cancel(); rocketLaunch = nil
    atmosphereTransition=nil; arrivingSpace=nil
    universe.root.components.remove(OpacityComponent.self); renderer.root.components.remove(OpacityComponent.self)
    elevators.clear(); rockets.clear(); rocketStatus = ""; rocketNotice = ""
    systemTime = 0
    viewPitch = 0
    planetProgress = [:]
    hayHays = .init(); hayHayCount=0; lastCompanionCheck = -.infinity
    mount=nil; mountCandidate=nil; ridePrompt=""; renderer.mount=nil
    renderer.wildlife.riddenID=nil; renderer.dinosaurs.riddenID=nil
    swimming = false
    wasTouchingWater = false
    biteUntil = 0
    dinosaurMessage = ""
    if let save = restoredSave, save.seed == baseSeed {
      edits = Dictionary(
        save.edits.map { ($0.position, $0.block) }, uniquingKeysWith: { _, latest in latest })
      player = .init(position: [save.player[0], save.player[1], save.player[2]])
      player.flying = save.flying
      heading = save.heading
      selectedSlot = save.selectedSlot
      inventory = save.inventory ?? .init()
      hayHays = save.hayHays ?? .init(); hayHayCount=hayHays.count
      plantEdits = Dictionary((save.plantEdits ?? []).map { ($0.position, $0) }, uniquingKeysWith: { _, last in last })
      environment = .init(elapsed: save.worldTime ?? WorldEnvironment.dayDuration * 0.38)
      space = save.space
      rocketJourney = save.rocket
      systemTime = save.systemTime ?? 0
      // A new session takes its neutral view from the wearer's current pose.
      // Preserve the world heading, but don't restore a previous body-look tilt.
      planetProgress = Dictionary(
        (save.visitedPlanets ?? []).map { ($0.index, $0) },
        uniquingKeysWith: { _, latest in latest })
    } else {
      edits = [:]
      player = .init(position: generator.spawn())
      heading = 0
      selectedSlot = 0
    }
    // Older landscapes and player-built walls may surround a restored location.
    if rocketJourney == nil && player.collides(at: player.position, block: { edits[$0] ?? generator.block(at: $0) }) {
      player = .init(position: generator.spawn())
    }
    flying = player.flying
    isInSpace = space != nil
    planetName = planet.name
    destinationIndex = (planetIndex + 1) % solarSystem.planets.count
    reference = nil
    referenceOrientation = simd_quatf(angle: 0, axis: [0, 1, 0])
    isRecentering = false
    // A stopped ARKit data provider cannot be restarted; each entry gets a fresh one.
    #if os(visionOS)
    tracking = WorldTrackingProvider()
    arSession = ARKitSession()
    #endif
    resetPerformanceMeasurement()
    isLoading = true
    isPaused = false
    exitRequested = false
    errorMessage = nil
    ambienceCenter = nil
    lastStepPosition = player.position
    lastAnimalSound = environment.elapsed
    renderer.onError = { [weak self] message in self?.errorMessage = message }
    try renderer.configure(seed: seed, style: planet.style, edits: edits, environment: environment)
    renderer.restorePlants(Array(plantEdits.values))
    renderer.pickups.restore(restoredSave?.seed == baseSeed ? restoredSave?.droppedItems ?? [] : [])
    renderer.wildlife.restore(restoredSave?.seed == baseSeed ? restoredSave?.animalBonds ?? [] : [])
    renderer.vehicles.restore(restoredSave?.seed == baseSeed ? restoredSave?.vehicles ?? [] : [])
    renderer.boats.restore(restoredSave?.seed == baseSeed ? restoredSave?.boats ?? [] : [], driver:restoredSave?.seed == baseSeed ? restoredSave?.boatDriver : nil)
    renderer.settlementLife.restore(restoredSave?.seed == baseSeed ? restoredSave?.residents ?? [] : [],
      homes: restoredSave?.seed == baseSeed ? restoredSave?.homes ?? [] : [])
    renderer.fauna.restore(restoredSave?.seed == baseSeed ? restoredSave?.fauna ?? [] : [])
    if let journey = rocketJourney {
      destinationIndex = journey.destinationPlanet
      rockets.setPort(journey.port, lighting: renderer.atmosphere.lighting)
      player.position = journey.port.center + journey.passenger
      player.flying = false
    }
    if space == nil {
      renderer.stream(around: player.position, radius: renderDistance, detailRadius: detailDistance)
    }
  }

  // Return from RealityView.make immediately. Terrain publication depends on
  // SceneEvents.Update, so awaiting optional assets here can deadlock startup.
  func start(content: some RealityViewContentProtocol) {
    guard !isImmersed else { return }
    let lifetime = lifecycle
    #if os(visionOS)
    let session = arSession
    let provider = tracking
    #else
    screenCamera.camera = .init(near: 0.02, far: .infinity, fieldOfViewInDegrees: 65)
    screenCamera.transform = .identity
    content.add(screenCamera)
    reference = .zero
    referenceOrientation = simd_quatf(angle: 0, axis: [0, 1, 0])
    #endif
    isImmersed = true
    input.start()
    content.add(renderer.root)
    content.add(renderer.sky)
    content.add(headAnchor)
    content.add(universe.root)
    content.add(rockets.root)
    content.add(avatar.root)
    hands.configure(
      parent: headAnchor, lighting: space != nil || rocketJourney?.phase == .cruise ? universe.lighting : renderer.atmosphere.lighting)
    do { try hands.select(selectedItem, materials: renderer.materials) } catch {
      errorMessage = "Could not display your held block: \(error.localizedDescription)"
    }
    var underwater = UnlitMaterial(color: UIColor(red: 0.02, green: 0.25, blue: 0.43, alpha: 1))
    underwater.faceCulling = .front
    underwater.blending = .transparent(opacity: .init(floatLiteral: 0.22))
    underwaterOverlay.model = .init(mesh: .generateSphere(radius: 1.4), materials: [underwater])
    underwaterAppearance = nil
    underwaterOverlay.isEnabled = false
    headAnchor.addChild(underwaterOverlay)
    var cloudFog = UnlitMaterial(color: UIColor(white: 0.94, alpha: 1))
    cloudFog.faceCulling = .front
    cloudFog.blending = .transparent(opacity: .init(floatLiteral: 0.40))
    cloudOverlay.model = .init(mesh: .generateSphere(radius: 1.35), materials: [cloudFog])
    cloudOverlay.isEnabled = false
    headAnchor.addChild(cloudOverlay)
    var biteTint = UnlitMaterial(color: UIColor(red: 0.92, green: 0.24, blue: 0.34, alpha: 1))
    biteTint.faceCulling = .front
    biteTint.blending = .transparent(opacity: .init(floatLiteral: 0.10))
    biteOverlay.model = .init(mesh: .generateSphere(radius: 1.3), materials: [biteTint])
    biteOverlay.isEnabled = false
    headAnchor.addChild(biteOverlay)
    startupTime = CACurrentMediaTime()
    status = "Loading nearby terrain…"
    subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
      // Scene updates are delivered by RealityKit on the main executor.
      MainActor.assumeIsolated { self?.update(deltaTime: Float(event.deltaTime)) }
    }
    print("WORLDCRAFT_STARTUP stage=scene_attached")
    preparation.onEvent = { [weak self] event in
      guard let self, self.isImmersed, self.lifecycle == lifetime else { return }
      switch event {
      case .started(let job): print("WORLDCRAFT_STARTUP stage=\(job.rawValue) state=started")
      case .finished(let job, let milliseconds):
        print("WORLDCRAFT_STARTUP stage=\(job.rawValue) state=ready elapsed_ms=\(Int(milliseconds))")
      case .failed(let job, let message):
        print("WORLDCRAFT_STARTUP stage=\(job.rawValue) state=failed error=\(message)")
        self.errorMessage = "Could not prepare \(job.rawValue): \(message)"
        if job == .tracking { self.setPaused(true) }
      }
    }
    #if os(visionOS)
    if WorldTrackingProvider.isSupported {
      preparation.launch(.tracking) { [weak self] in
        guard let self else { return }
        try await session.run([provider])
        guard !Task.isCancelled, self.isImmersed, lifetime == self.lifecycle else {
          session.stop(); return
        }
        self.trackingTask = Task { [weak self] in
          for await event in session.events {
            guard !Task.isCancelled, let self, self.isImmersed, self.lifecycle == lifetime else { return }
            if case .dataProviderStateChanged(_, _, let error) = event, let error {
              self.errorMessage = "Tracking stopped: \(error.localizedDescription)"
              self.setPaused(true)
            } else if case .dataProviderStateChanged(_, let state, _) = event, state == .stopped {
              self.setPaused(true)
            }
          }
        }
      }
    } else {
      // Simulator preview only. Device builds use the tracked headset pose.
      reference = [0, 1.62, 0]
      status = "Simulator preview · head targeting needs Vision Pro"
    }
    #endif
    audio.musicVolume = musicVolume
    audio.effectsVolume = effectsVolume
    preparation.launch(.planets) { [weak self] in
      guard let self else { return }
      try await self.universe.configure(self.solarSystem)
    }
    preparation.launch(.rocketAudio) { [weak self] in await self?.rockets.prepareAudio() }
    preparation.launch(.audio) { [weak self] in
      guard let self else { return }
      try await self.audio.start(root: self.renderer.root,
        generator: self.solarSystem.planets[self.planetIndex].terrain, player: self.player.position)
      guard !Task.isCancelled, self.isImmersed, lifetime == self.lifecycle else { return }
      self.ambienceCenter = BlockPosition(self.player.position).chunk
      self.audio.setSpace(self.space != nil || self.rocketJourney?.phase == .cruise)
      self.audio.setPaused(self.isPaused)
    }
    startupWatchdog = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        guard let self, self.isImmersed, self.lifecycle == lifetime, !self.firstWorldFrame else { return }
        let jobs = self.preparation.pending.map(\.rawValue).joined(separator: ",")
        print("WORLDCRAFT_STARTUP stage=waiting elapsed_s=\(Int(CACurrentMediaTime() - self.startupTime)) frames=\(self.startupFrames) chunks=\(self.renderer.chunks.count) tracking=\(self.trackingStatus) recentering=\(self.isRecentering) pending=\(jobs)")
      }
    }
  }

  private func recordWorldReady() {
    guard !isLoading, !isRecentering, !firstWorldFrame, reference != nil else { return }
    firstWorldFrame = true
    startupWatchdog?.cancel(); startupWatchdog = nil
    print("WORLDCRAFT_STARTUP stage=world_visible elapsed_ms=\(Int((CACurrentMediaTime() - startupTime) * 1_000))")
  }

  func leaveWorld() { exitRequested = true }

  private func update(deltaTime: Float) {
    guard isImmersed else { return }
    let interval = PerformanceTrace.begin("Game update")
    defer { PerformanceTrace.end("Game update", interval) }
    let now = CACurrentMediaTime()
    startupFrames += 1
    if startupFrames == 1 { print("WORLDCRAFT_STARTUP stage=first_frame") }
    defer {
      recordWorldReady()
      if space == nil { renderer.sampleCoverage(at: now) }
      recordPerformance(interval: Double(deltaTime), cpuTime: CACurrentMediaTime() - now, now: now)
    }
    guard !isRecentering else { return }
    ActorModelLibrary.shared.beginFrame()
    let dt = min(deltaTime, 0.05)
    var frame = PerformanceTrace.measure(.input) {
      input.poll(smoothTurning: smoothTurning, turnSpeed: turnSpeed, deltaTime: dt, inventoryOpen: inventoryOpen, driving: inVehicle)
    }
    let actionButtonsReleased = !frame.mine && !frame.place
    if inventoryOpen {
      if frame.toggleInventory || frame.leave || frame.togglePause {
        setInventoryOpen(false); frame = InputFrame()
      } else { handleInventory(frame); frame = InputFrame() }
    } else if frame.toggleInventory && !isPaused && !isLoading {
      setInventoryOpen(true); frame = InputFrame()
    }
    if isPaused && frame.leave { exitRequested = true }
    if isPaused && frame.jump {
      setPaused(false)
      frame.jump = false
      frame.boatHoist = false
      frame.ascend = 0
    }
    if frame.togglePause { setPaused(!isPaused) }
    if frame.recenter { recenterOrientation() }
    if frame.togglePerspective && !inventoryOpen { thirdPerson.toggle() }
    audio.musicVolume = musicVolume
    audio.effectsVolume = effectsVolume
    if space == nil && rocketJourney == nil {
      PerformanceTrace.measure(.streaming) { renderer.stream(around: player.position, radius: renderDistance, detailRadius: detailDistance,
        velocity: renderer.vehicles.isDriving ? renderer.vehicles.velocity : renderer.boats.isSailing ? renderer.boats.velocity : player.velocity, frameInterval: Double(deltaTime)) }
    }
    PerformanceTrace.measure(.audio) { audio.tick(time: now) }
    #if os(visionOS)
    let device = PerformanceTrace.measure(.tracking) {
      tracking.state == .running ? tracking.queryDeviceAnchor(atTimestamp: now) : nil
    }
    if WorldTrackingProvider.isSupported && (device == nil || device?.isTracked == false) {
      if reference != nil && !isPaused { setPaused(true) }
      rockets.update(deltaTime: 0, player: player.position, phase: rocketJourney?.phase,
        clock: systemTime, paused: true, effectsVolume: effectsVolume)
      status = "Waiting for headset tracking…"
      return
    }
    let pose = device?.originFromAnchorTransform ?? matrix_identity_float4x4
    #else
    let pose = matrix_identity_float4x4
    #endif
    let trackedPosition = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
    if reference == nil {
      reference = trackedPosition
      referenceOrientation = simd_quatf(pose).normalized
      viewPitch = 0
    }
    guard let reference else { return }
    if showPerformance {
      let coverageFrame = PlayerFrame(referenceEye: reference, referenceOrientation: referenceOrientation,
        feet: player.position, heading: heading, pitch: viewPitch)
      renderer.coverageViewDirection = coverageFrame.worldDirection(
        fromTracked: -SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z))
    }
    if rocketJourney != nil {
      updateRocket(frame: frame, deltaTime: dt, now: now, reference: reference,
        trackedPosition: trackedPosition, pose: pose)
      return
    }
    if space != nil {
      updateSpace(
        frame: frame, deltaTime: dt, now: now, reference: reference,
        trackedPosition: trackedPosition, pose: pose)
      return
    }
    // Move the world with the inverse player transform. visionOS keeps its native
    // tracked stereo pose; iPad uses a fixed virtual camera at the tracking origin.
    findNearbyRocket()
    rockets.root.isEnabled = rockets.port != nil && space == nil
    rockets.update(deltaTime: dt, player: player.position, phase: nil,
      clock: systemTime, paused: isPaused || inventoryOpen || isLoading, effectsVolume: effectsVolume)
    isLoading = renderer.waitingForInitialTerrain(at: player.position)
    if renderer.root.isEnabled == isLoading { renderer.root.isEnabled = !isLoading }
    guard !isPaused && !inventoryOpen && !isLoading && !exitRequested && lifeTransition == nil else {
      let coordinateFrame = cameraFrame(reference: reference, trackedPosition: trackedPosition,
        feet: player.position, seconds: 0)
      placeWorld(coordinateFrame)
      blendArrival(frame:coordinateFrame,seconds:0)
      updateAvatar(frame: coordinateFrame, pose: pose, seconds: 0, visible: !isLoading)
      renderer.updateEnvironment(
        environment, deltaTime: 0, player: player.position,
        frame: coordinateFrame, trackedPosition: trackedPosition,
        trackedForward: -SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z))
      renderer.showSelection(nil)
      hands.root.isEnabled = false
      refreshHUD(now: now)
      return
    }
    environment.advance(Double(dt))
    systemTime += Double(dt)
    let inCabin = rockets.isInside(player.position)
    // Resolve Triangle/Y before flight toggles so boarding never starts flight.
    if frame.vehicleInteract && mount == nil && !inCabin {
      let bodyFrame = PlayerFrame(referenceEye: reference, referenceOrientation: referenceOrientation,
        feet: player.position, heading: heading, pitch: viewPitch)
      let look = bodyFrame.worldDirection(fromTracked: -SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z))
      renderer.vehicles.focus(eye: bodyFrame.worldPoint(fromTracked: trackedPosition), direction: look, block: renderer.block)
      renderer.boats.focus(eye: bodyFrame.worldPoint(fromTracked: trackedPosition), direction: look, block: renderer.block)
      if renderer.vehicles.hasInteraction || renderer.boats.hasInteraction { frame.toggleFlight = false }
    }
    if actionButtonsReleased { actionButtonsArmed = true }
    if now >= noticeUntil && !gatheringNotice.isEmpty { gatheringNotice = "" }
    let gestureFlight = !elevators.riding && mount == nil && !inVehicle && !inCabin && frame.jump && doubleJump.press(at: environment.elapsed)
    if !elevators.riding && mount == nil && !inVehicle && !inCabin && (frame.toggleFlight || gestureFlight) {
      player.flying.toggle()
      player.verticalVelocity = 0
      player.grounded = false
      frame.jump = false
      flying = player.flying
      audio.play(flying ? "flight_start" : "flight_stop", at: player.position, root: renderer.root, time: now)
    }
    heading += frame.turn
    viewPitch = LocomotionInput.clampLookPitch(viewPitch + frame.lookPitch)
    heading.formTruncatingRemainder(dividingBy: .pi * 2)
    let nextSlot = ((frame.selectedSlot ?? selectedSlot) + frame.slotDelta % Inventory.hotbarCount + Inventory.hotbarCount)
      % Inventory.hotbarCount
    if selectedSlot != nextSlot {
      selectedSlot = nextSlot; mining.reset()
      audio.play("hotbar", at: player.position, root: renderer.root, time: now)
    }
    renderer.wildlife.offering = selectedItem?.food
    var movement = worldMovement(frame, pose: pose, heading: heading)
    let body = renderer.terrain.waterBody(
      atX: Int(floor(player.position.x)), z: Int(floor(player.position.z)))
    let waterColumn =
      body.map {
        renderer.block(at: BlockPosition([player.position.x, $0.level - 0.5, player.position.z]))
          .isLiquid
      } ?? false
    let waterLevel: Float? =
      waterColumn
      ? body.map {
        environment.water(atX: player.position.x, z: player.position.z, body: $0).height
      } : nil
    swimming = !inVehicle && !player.flying && waterLevel.map { player.position.y + WorldScale.blocks(0.9) < $0 } ?? false
    let touchingWater = !inVehicle && !player.flying && waterLevel.map { player.position.y < $0 } ?? false
    if touchingWater, let body, body.level - player.position.y < 4,
      !wasTouchingWater
        || (simd_length_squared(frame.movement) > 0.02 && environment.elapsed - lastWake > 0.22)
    {
      let depth = max(0, body.level - player.position.y)
      environment.disturbWater(
        atX: player.position.x, z: player.position.z, body: body,
        energy: (wasTouchingWater ? 0.16 : 0.32) * max(0, 1 - depth / 4))
      if !wasTouchingWater && depth < 4 && body.kind != .lava {
        audio.play(
          "splash", at: [player.position.x, body.level, player.position.z], root: renderer.root,
          time: now)
      }
      lastWake = environment.elapsed
    }
    if wasTouchingWater && !touchingWater {
      audio.play("water_exit", at: player.position, root: renderer.root, time: now)
    }
    if swimming && simd_length_squared(frame.movement) > 0.02 && now-lastSwimSound > 0.7 {
      lastSwimSound = now
      audio.play("swim", at: player.position+[0,1,0], root: renderer.root, time: now)
    }
    wasTouchingWater = touchingWater
    movement.y = player.flying || waterLevel != nil ? frame.ascend : 0
    let locomotionStart = CACurrentMediaTime()
    if let lifted = elevators.advance(seconds:dt,player:player.position,block:renderer.actorBlock) {
      player.position=lifted; player.verticalVelocity=0; player.flying=false; player.grounded=true
    } else if var ride = mount {
      if ride.profile.isColossal {
        ride.updateColossal(seconds:dt,movement:movement,sprint:frame.sprint) { [renderer] x,z in
          let column=renderer.terrain.column(atX:Int(floor(x)),z:Int(floor(z)))
          return .init(height:Float(column.height+1),waterDepth:max(0,(column.water?.level ?? Float(column.height))-Float(column.height)))
        }
      } else {
        ride.update(seconds:dt,movement:movement,sprint:frame.sprint,jump:frame.jump,
          block:{ [renderer] p in renderer.loadedChunks.contains(p.chunk) ? renderer.actorBlock(at:p) : .stone },
          occupied:{ [renderer,rockets] p in renderer.vehicles.obstructsPlayer(at:p) || rockets.obstructs(p) })
      }
      mount=ride; renderer.mount=ride
      renderer.wildlife.applyRider(ride,seconds:dt); renderer.dinosaurs.applyRider(ride,seconds:dt)
      player.position=ride.eye-[0,PlayerPhysics.eyeHeight,0]
      player.grounded=false; player.flying=false; swimming=false
    } else if renderer.boats.isSailing {
      heading += renderer.boats.sail(seconds:dt,frame:frame,terrain:renderer.terrain,environment:&environment,block:renderer.playerBlock)
      if let seat=renderer.boats.eye {player.position=seat-[0,PlayerPhysics.eyeHeight,0]}
      player.grounded=false;player.flying=false;swimming=false
    } else if renderer.vehicles.isDriving {
      if frame.startRace {
        let previous=renderer.vehicles.heading ?? heading
        renderer.vehicles.startRace(block:renderer.actorBlock)
        let change=(renderer.vehicles.heading ?? previous)-previous
        heading += atan2(sin(change),cos(change))
      }
      if frame.horn { audio.play("car_horn", at: player.position, root: renderer.root, time: now) }
      heading += renderer.vehicles.drive(deltaTime: dt, throttle: frame.driveThrottle,
        steering: frame.driveSteering, brake: frame.driveBrake,
        obstacles: renderer.settlementLife.positions, loaded: renderer.loadedChunks, block: renderer.actorBlock)
      if let seat = renderer.vehicles.eye { player.position = seat - [0, PlayerPhysics.eyeHeight, 0] }
      if renderer.vehicles.impactSpeed > 2 && now-lastCarSound > 0.25 {
        lastCarSound = now
        audio.play("car_bump", at: player.position, root: renderer.root, time: now)
      } else if renderer.vehicles.slipSpeed > 3 && now-lastCarSound > 0.55 {
        lastCarSound = now
        audio.play("car_skid", at: player.position, root: renderer.root, time: now)
      }
    } else {
      let wasFlying = player.flying, wasGrounded = player.grounded
      let fallingSpeed = player.verticalVelocity
      player.update(
        deltaTime: dt, movement: movement, jump: frame.jump, sprint: frame.sprint,
        waterLevel: waterLevel, waterCurrent: renderer.terrain.waterCurrent(at:player.position,time:environment.elapsed),
        block: renderer.playerBlock, occupied: { [renderer, rockets, elevators] in
          renderer.vehicles.obstructsPlayer(at: $0) || renderer.boats.obstructsPlayer(at: $0) || rockets.obstructs($0) || elevators.obstructs($0) || renderer.doors.obstructs($0)
        })
      if wasFlying && !player.flying { doubleJump.reset() }
      if wasGrounded && !player.grounded && frame.jump && !player.flying {
        audio.play("jump", at: player.position, root: renderer.root, time: now, level: -6)
      } else if !wasGrounded && player.grounded && fallingSpeed < -5 {
        audio.play("land", at: player.position, root: renderer.root, time: now)
      }
    }
    if flying != player.flying { flying = player.flying }
    PerformanceTrace.record(.locomotion, since: locomotionStart)
    if player.position.y < Float(ChunkData.minimumY - 4) {
      player = .init(position: renderer.terrain.spawn())
    }
    if player.flying && mount == nil && player.position.y >= SolarSystem.departureAltitude+Float(ChunkData.minimumY),
      SolarSystem.canDepart(height:player.position.y,
        ground:Float(renderer.terrain.height(atX:Int(floor(player.position.x)),z:Int(floor(player.position.z))))+1,
        flying:player.flying,mounted:mount != nil) {
      departPlanet()
      updateSpace(
        frame: frame, deltaTime: 0, now: now, reference: reference,
        trackedPosition: trackedPosition,
        pose: pose
      )
      return
    }
    let movedFrame = cameraFrame(reference: reference, trackedPosition: trackedPosition,
      feet: player.position, seconds: dt)
    PerformanceTrace.measure(.worldTransform) { placeWorld(movedFrame) }
    blendArrival(frame:movedFrame,seconds:dt)
    let viewEye = movedFrame.worldPoint(fromTracked: trackedPosition)
    let eye = viewEye - movedFrame.cameraOffset
    updateAvatar(frame: movedFrame, pose: pose, seconds: dt)
    renderer.settlementLife.homesteads.playerFlying = player.flying
    renderer.settlementLife.homesteads.playerDriving = inVehicle || rocketJourney != nil
    elevators.survey(site:renderer.settlementLife.currentSite,terrain:renderer.terrain,player:player.position,
      time:environment.elapsed,worldRoot:renderer.root)
    updateCompanions(now:now)
    renderer.updateEnvironment(
      environment, deltaTime: dt, player: player.position, frame: movedFrame,
      trackedPosition: trackedPosition,
      trackedForward: -SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z))
    let interactionsStart = CACurrentMediaTime()
    applyResidentInterventions(now: now)
    if autonomousDirty && now - lastAgencySave >= 1 {
      autonomousDirty = false; lastAgencySave = now; scheduleSave()
    }
    for hatch in renderer.dinosaurs.hatches {
      audio.play("break_glass", at:hatch,root:renderer.root,time:now,level:-10)
      audio.play("dinosaur_call", at:hatch,root:renderer.root,time:now,level:-6)
    }
    for bite in renderer.dinosaurs.bites {
      audio.play("rex_chomp", at: bite, root: renderer.root, time: now)
      biteUntil = now + 0.4
    }
    biteOverlay.isEnabled = now < biteUntil
    let biteMessage = now < biteUntil ? "\(renderer.dinosaurs.biteName) chomp!" : renderer.dinosaurs.encounterMessage
    if dinosaurMessage != biteMessage { dinosaurMessage = biteMessage }
    let viewWater = renderer.terrain.waterBody(atX: Int(floor(viewEye.x)), z: Int(floor(viewEye.z)))
    let viewWaterLevel: Float? = viewWater.flatMap { body in
      guard renderer.block(at: .init([viewEye.x, body.level - 0.5, viewEye.z])).isLiquid else { return nil }
      return environment.water(atX: viewEye.x, z: viewEye.z, body: body).height
    }
    let immersion = WaterAppearance.immersion(depth: (viewWaterLevel ?? viewEye.y) - viewEye.y,
      daylight: environment.daylight, lava: viewWater?.kind == .lava)
    if underwaterAppearance.map({ simd_distance($0, immersion) > 0.012 }) ?? true,
      var material = underwaterOverlay.model?.materials.first as? UnlitMaterial {
      underwaterAppearance = immersion
      material.color = .init(tint: UIColor(red: CGFloat(immersion.x), green: CGFloat(immersion.y),
        blue: CGFloat(immersion.z), alpha: 1))
      material.blending = .transparent(opacity: .init(floatLiteral: immersion.w))
      underwaterOverlay.model?.materials = [material]
    }
    underwaterOverlay.isEnabled = viewWaterLevel.map { viewEye.y < $0 - 0.06 } ?? false
    cloudOverlay.isEnabled = renderer.atmosphere.cloudDensity > 0.01
    cloudOverlay.components.set(OpacityComponent(opacity: renderer.atmosphere.cloudDensity))
    hands.update(
      deltaTime: dt, movement: flying ? 0 : simd_length(frame.movement),
      visible: showHands && !thirdPerson && !inVehicle && mount == nil)
    do { try hands.select(selectedItem, materials: renderer.materials) } catch {
      errorMessage = "Could not display your held block: \(error.localizedDescription)"
    }
    let look = movedFrame.worldDirection(
      fromTracked: -SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z))
    let direction = thirdPerson ? ThirdPersonCamera.interactionDirection(eye: eye, camera: viewEye,
      forward: look, block: renderer.block) : look
    var vehicleInteractionHandled = false
    var rocketInteractionHandled = false
    var animalInteractionHandled = false
    renderer.sports.focus(eye:eye,direction:direction,block:renderer.block)
    var sportsHandled=false
    if !inVehicle && mount == nil && frame.interact,let changes=renderer.sports.lockerChanges(player:player,block:renderer.actorBlock) {
      sportsHandled=true
      for (point,value) in changes {change(point,to:value)}
      if !changes.isEmpty {audio.play("car_door",at:eye,root:renderer.root,time:now);scheduleSave()}
    }
    renderer.doors.focus(eye:eye,direction:direction,block:renderer.block)
    let doorHandled = sportsHandled || (!inVehicle && mount == nil && !inCabin && frame.interact && renderer.doors.interact(time:environment.elapsed))
    elevators.focus(eye:eye,direction:direction,feet:player.position,block:renderer.block)
    if elevators.contains(player.position) && frame.destinationDelta != 0 { elevators.choose(frame.destinationDelta) }
    let elevatorHandled = doorHandled || (!inVehicle && mount == nil && !inCabin && frame.interact && elevators.interact(player:player.position))
    if now-lastNPCFocus > 0.15 || frame.interact {
      if mount == nil && !inVehicle && !inCabin {
        renderer.wildlife.focus(eye: eye, direction: direction, item: selectedItem,
          time: environment.elapsed, block: renderer.block)
      }
      updateMountFocus(eye:eye,direction:direction)
    }
    // Use feeds an offered food, and pets a companion, before trying to mount it.
    let caringForAnimal = mount == nil && renderer.wildlife.hasFocus
      && (selectedItem?.food != nil || renderer.wildlife.focusedPet)
    if caringForAnimal { ridePrompt = "" }
    if !elevatorHandled && !caringForAnimal && frame.interact && (mount != nil || mountCandidate != nil) && !inVehicle && !inCabin {
      animalInteractionHandled=true
      interactWithMount(now:now)
      let frame = cameraFrame(reference: reference, trackedPosition: trackedPosition, feet: player.position, seconds: 0)
      placeWorld(frame); updateAvatar(frame: frame, pose: pose, seconds: 0)
    }
    if now - lastNPCFocus > 0.15 || frame.interact || frame.vehicleInteract || frame.place {
      lastNPCFocus = now
      if !driving && mount == nil && !inCabin {
        renderer.boats.focus(eye:eye,direction:direction,block:renderer.block)
        if !elevatorHandled && (frame.interact || frame.vehicleInteract) && renderer.boats.hasInteraction {
          vehicleInteractionHandled=true
          let wasSailing=renderer.boats.isSailing
          if let exit=renderer.boats.interact(terrain:renderer.terrain,block:renderer.playerBlock) {
            player = .init(position:exit)
          } else if renderer.boats.isSailing,let seat=renderer.boats.eye {
            player = .init(position:seat-[0,PlayerPhysics.eyeHeight,0])
            if !wasSailing {heading=renderer.boats.heading ?? heading;viewPitch=0}
          }
          flying=false;swimming=false;doubleJump.reset();input.reset();actionButtonsArmed=false
          camera.reset()
          let view=cameraFrame(reference:reference,trackedPosition:trackedPosition,feet:player.position,seconds:0)
          placeWorld(view);updateAvatar(frame:view,pose:pose,seconds:0)
          if wasSailing != renderer.boats.isSailing {
            audio.play("water_enter",at:player.position,root:renderer.root,time:now,level:-12)
          }
        }
      }
      if !inVehicle && mount == nil { rockets.focus(eye: eye, direction: direction, feet: player.position, block: renderer.block) }
      if !vehicleInteractionHandled && !elevatorHandled && !inVehicle && mount == nil && rockets.focused != nil {
        rocketInteractionHandled = true
        if frame.interact {
          switch rockets.focused {
          case .door: rockets.toggleDoor(player: player.position)
          case .previous: changeRocketDestination(-1)
          case .next: changeRocketDestination(1)
          case .launch: requestRocketLaunch()
          case nil: break
          }
        }
      }
      renderer.vehicles.focus(eye: eye, direction: direction, block: renderer.block)
      let vehicleInteraction = renderer.vehicles.hasInteraction && !renderer.boats.isSailing
      if !vehicleInteractionHandled && !elevatorHandled && (frame.interact || frame.vehicleInteract) && vehicleInteraction && !rocketInteractionHandled && !inCabin && mount == nil && !animalInteractionHandled {
        vehicleInteractionHandled = true
        let wasDriving = renderer.vehicles.isDriving
        if let exit = renderer.vehicles.interact(player: player.position, block: { [renderer] p in
          renderer.loadedChunks.contains(p.chunk) ? renderer.actorBlock(at: p) : .stone
        }, occupied: { [renderer, rockets] point in
          rockets.obstructs(point)
            || renderer.settlementLife.positions.contains { abs($0.y - point.y) < PlayerPhysics.height
              && simd_length(SIMD2<Float>($0.x-point.x, $0.z-point.z)) < 1 }
        }) {
          player = .init(position: exit); doubleJump.reset()
        } else if !wasDriving, renderer.vehicles.isDriving, let seat = renderer.vehicles.eye {
          player = .init(position: seat - [0, PlayerPhysics.eyeHeight, 0])
          heading = renderer.vehicles.heading ?? heading; viewPitch = 0; doubleJump.reset()
        }
        driving = renderer.vehicles.isDriving; flying = false; swimming = false
        if driving != wasDriving {
          input.reset(); actionButtonsArmed = false
          audio.play("car_door", at: player.position, root: renderer.root, time: now)
          audio.play(driving ? "car_start" : "car_stop", at: player.position, root: renderer.root, time: now)
        }
        // Apply the seat/exit immediately, including the neutral headset frame.
        camera.reset()
        let frame = cameraFrame(reference: reference, trackedPosition: trackedPosition, feet: player.position, seconds: 0)
        placeWorld(frame); updateAvatar(frame: frame, pose: pose, seconds: 0)
      }
      renderer.wildlife.clearFocus()
      if !vehicleInteractionHandled && !elevatorHandled && !inVehicle && mount == nil && !inCabin && !vehicleInteraction && !rocketInteractionHandled && !animalInteractionHandled {
        renderer.wildlife.focus(eye: eye, direction: direction, item: selectedItem,
          time: environment.elapsed, block: renderer.block)
        if frame.interact && renderer.wildlife.hasFocus {
          animalInteractionHandled = true; feedAnimal(now: now)
        }
      }
      renderer.settlementLife.focus(eye: eye, direction: direction,
        interact: !vehicleInteractionHandled && !inVehicle && !elevatorHandled && frame.interact && mount == nil && !vehicleInteraction && !rocketInteractionHandled && !inCabin && !animalInteractionHandled,
        terrain: renderer.terrain, block: renderer.block)
    }
    if inCabin && frame.destinationDelta != 0 {
      changeRocketDestination(frame.destinationDelta)
    }
    if let port = rockets.port {
      rockets.setDisplay("\(solarSystem.planets[destinationIndex].name.uppercased())\nDESTINATION \(destinationIndex+1) / \(solarSystem.planets.count)")
      if rocketLaunch == nil {
        let delta = port.center - player.position
        let bearing = atan2(-delta.x, -delta.z) - heading
        let angle = atan2(sin(bearing), cos(bearing)) * 180 / .pi
        let message = !rocketNotice.isEmpty ? rocketNotice : inCabin ? "Cabin · Choose planet with D-pad / , . · Look at the amber launch button"
          : "Spaceport · \(port.town) · \(Int(WorldScale.metres(simd_length(delta)))) m · \(angle >= 0 ? "left" : "right") \(Int(abs(angle)))°"
        if rocketStatus != message { rocketStatus = message }
      }
    }
    updateGathering(frame: frame, deltaTime: dt, now: now, eye: eye, direction: direction,
      blocked: elevators.riding || elevatorHandled || mount != nil || inVehicle || vehicleInteractionHandled || rocketInteractionHandled || inCabin || animalInteractionHandled)
    renderer.sports.publishDrops(to:renderer.pickups)
    updatePickups(deltaTime: dt, now: now)
    PerformanceTrace.record(.interactions, since: interactionsStart)
    let audioStart = CACurrentMediaTime()
    for (sound,point) in renderer.doors.sounds { audio.play(sound,at:point,root:renderer.root,time:now,level:-7) }
    updateAudioScene(now: now)
    if environment.elapsed - lastAnimalSound > 4 {
      lastAnimalSound = environment.elapsed
      let nearby = renderer.wildlife.audibleAnimals.filter {
        $0.0.sound != nil && simd_distance($0.1, player.position) < 24
      }
      var calls = renderer.dinosaurs.calls.filter { simd_distance($0.position, player.position) < $0.range }
      calls += nearby.compactMap { animal in
        animal.0.sound.map { (name: $0, position: animal.1+[0,0.8,0], range: Float(24), level: Float(0)) }
      }
      if let call = calls.randomElement() {
        audio.play(call.name, at: call.position, root: renderer.root, time: now, level: call.level)
      }
    }
    if player.grounded && !player.flying && !inVehicle && !swimming && simd_distance(player.position, lastStepPosition) > 1.65 {
      let ground = renderer.block(at: BlockPosition(player.position - [0, 0.1, 0]))
      audio.play("step_\(SoundSurface(ground).rawValue)", at: player.position + [0, -0.1, 0], root: renderer.root, time: now)
      lastStepPosition = player.position
    } else if player.flying || inVehicle || simd_length_squared(movement) < 0.01 {
      lastStepPosition = player.position
    }
    let center = BlockPosition(player.position).chunk
    if ambienceCenter == nil || center.distanceSquared(to: ambienceCenter!) >= 4 {
      audio.updateAmbience(
        root: renderer.root, generator: renderer.terrain, player: player.position)
      ambienceCenter = center
    }
    PerformanceTrace.record(.audio, since: audioStart)
    PerformanceTrace.measure(.hud) { refreshHUD(now: now) }
    if now - lastSaveTime > 5 {
      lastSaveTime = now
      scheduleSave()
    }
  }

  private func updateCompanions(now: Double) {
    guard now-lastCompanionCheck > 0.3 else { return }
    lastCompanionCheck=now
    renderer.hayHayIDs=hayHays.activeIDs; renderer.hiddenCastleHayHay=nil
    guard let castle=renderer.terrain.landmarks.first(where:{$0.kind == .castle}) else { return }
    hayHays.rearm(castle:castle,player:player.position)
    if hayHays.lockedCastles.contains(castle.id) { renderer.hiddenCastleHayHay=HayHay.id(in:castle); return }
    guard let pet = renderer.wildlife.simulationStates.first(where: { $0.id == HayHay.id(in:castle) }) else { return }
    let destination=pet.position+[0,1,0], eye=player.position+[0,PlayerPhysics.eyeHeight,0]
    if simd_distance_squared(player.position,pet.position)<3.5*3.5,
      VoxelRaycast.cast(origin:eye,direction:destination-eye,reach:max(0,simd_distance(eye,destination)-0.5),block:renderer.actorBlock) == nil,
      hayHays.collect(castle:castle) != nil {
      renderer.hiddenCastleHayHay=HayHay.id(in:castle)
      _ = renderer.wildlife.removePrey(id:HayHay.id(in:castle))
      renderer.hayHayIDs=hayHays.activeIDs; hayHayCount=hayHays.count
      gatheringMessage("Hay Hay joined you! · \(hayHayCount) collected",now:now)
      audio.play("hay_hay",at:castle.petHome,root:renderer.root,time:now)
      scheduleSave()
    }
  }

  private func updateMountFocus(eye: SIMD3<Float>, direction: SIMD3<Float>) {
    if let ride=mount {
      ridePrompt="Riding \(ride.name) · Left stick / WASD: move · "
        + (ride.profile.isColossal ? "Walk through trees and buildings · ":"A / Space: jump · ")+"R / LT: dismount"
      return
    }
    mountCandidate=nil
    if !inVehicle && !rockets.isInside(player.position) {
      let candidates=renderer.wildlife.mounts+renderer.dinosaurs.mounts
      mountCandidate=candidates.filter { candidate in
        let target=candidate.position+[0,min(candidate.profile.height,max(0.8,eye.y-candidate.position.y)),0]
        let delta=target-eye, distance=simd_length(delta)
        let giant=candidate.profile.isColossal
        let reach=giant ? max(candidate.profile.radius,abs(candidate.profile.seatForward))+8:candidate.profile.radius+6
        let height=player.position.y-candidate.position.y
        guard distance > 0.01, distance < reach,
          height > -5,height < (giant ? candidate.profile.seatHeight+5:5),
          simd_dot(delta/distance,direction) > (giant ? 0.4:0.82) else { return false }
        return VoxelRaycast.cast(origin:eye,direction:delta,reach:max(0,distance-candidate.profile.radius),block:renderer.block) == nil
      }.min { simd_distance_squared($0.position,eye) < simd_distance_squared($1.position,eye) }
    }
    ridePrompt=mountCandidate.map { "\($0.name) · R / LT: ride · Hold food to feed" } ?? ""
  }
  private func interactWithMount(now: Double) {
    let safe: (BlockPosition)->Block = { [renderer] p in
      p.y>=ChunkData.height ? .air : renderer.loadedChunks.contains(p.chunk) ? renderer.actorBlock(at:p) : .stone
    }
    if let ride=mount {
      guard let exit=ride.dismount(block:safe,occupied:{ [renderer,rockets] p in
        renderer.vehicles.obstructsPlayer(at:p) || rockets.obstructs(p)
          || renderer.settlementLife.positions.contains { simd_distance_squared($0,p)<1 }
      }) else { gatheringMessage("Move to open ground to dismount safely.",now:now); return }
      mount=nil; renderer.mount=nil; mountCandidate=nil
      renderer.wildlife.riddenID=nil; renderer.dinosaurs.riddenID=nil
      player = .init(position:exit); ridePrompt=""; doubleJump.reset()
    } else if let candidate=mountCandidate {
      let ride=MountedRide(candidate,boardedAt:player.position)
      guard ride.clear(at:ride.position,block:safe) else {
        gatheringMessage("There isn't enough headroom to ride here.",now:now); return
      }
      mount=ride; renderer.mount=ride
      renderer.wildlife.riddenID=ride.id; renderer.dinosaurs.riddenID=ride.id
      player = .init(position:ride.eye-[0,PlayerPhysics.eyeHeight,0]); player.grounded=false
      flying=false; swimming=false; doubleJump.reset(); resetGathering()
      audio.play("pet",at:ride.position,root:renderer.root,time:now)
    }
    scheduleSave()
  }

  private func updateAudioScene(now: Double) {
    guard now-lastAudioScene > 0.2 else { return }
    lastAudioScene = now
    let terrain = renderer.terrain, p = BlockPosition(player.position)
    let column = terrain.column(atX: p.x, z: p.z)
    let underground = space == nil && rocketJourney == nil && player.position.y+PlayerPhysics.height < Float(column.height)-2
    let town = !settlementName.isEmpty
    let mood = MusicMood.select(style: terrain.style,
      biome: terrain.biome(atX:p.x,z:p.z,height:column.height,water:column.water),
      daylight: environment.daylight, space: space != nil || rocketJourney?.phase == .cruise,
      underwater: underwaterOverlay.isEnabled, racing: renderer.vehicles.isOnCircuit,
      town: town, cave: underground, castle: terrain.landmarks.contains { $0.kind == .castle && $0.contains(x:p.x,z:p.z) })
    audio.updateEnvironment(environment, player: player.position, mood: mood,
      submerged: underwaterOverlay.isEnabled, underground: underground, town: town,
      ducked: !npcConversation.isEmpty || rocketJourney != nil, vehicles: renderer.vehicles.audioStates, fires: renderer.fire.audiblePositions)
    let laps=renderer.vehicles.completedLaps
    if laps>lastLapSound { audio.play("lap",at:player.position,root:renderer.root,time:now) }
    lastLapSound=laps
    if now-lastNPCSound>2.5 {
      let sources=renderer.settlementLife.soundSources.filter { simd_distance_squared($0.1,player.position)<24*24 }
      if let source=sources.randomElement() {
        lastNPCSound=now; audio.play(source.0,at:source.1,root:renderer.root,time:now)
      }
    }
  }

  private func resetPerformanceMeasurement() {
    PerformanceTrace.measuresPhases = showPerformance
    renderer.measuresStreamingCoverage = showPerformance
    renderer.resetCoverageDiagnostics()
    _ = PerformanceTrace.consumePhases()
    frameTiming.reset()
    logTiming.reset()
    performanceWindowStart = nil
    lastPerformanceUpdate = 0
    performanceRun = UUID().uuidString
    performanceSequence = 0
    performanceSummary = "Measuring…"
    performanceDetail = ""
    renderer.ocean.measuresPerformance = showPerformance
    renderer.ocean.resetPerformanceTiming()
    _ = renderer.fire.consumePerformanceTiming()
    _ = renderer.life.consumePerformance(); _ = renderer.consumeRenderingTiming()
    renderer.settlementLife.logsDecisions = showPerformance
  }

  private func recordPerformance(interval: Double, cpuTime: Double, now: Double) {
    guard showPerformance else { return }
    frameTiming.record(interval: interval, cpuTime: cpuTime)
    logTiming.record(interval: interval, cpuTime: cpuTime)
    if performanceWindowStart == nil { performanceWindowStart = now }
    if now - lastPerformanceUpdate >= 1 {
      lastPerformanceUpdate = now
      let timing = frameTiming.snapshot
      performanceSummary = String(
        format: "Update %.0f Hz · game p95 %.1f ms · interval p95 %.1f ms",
        timing.updateHz, timing.cpuP95Milliseconds, timing.intervalP95Milliseconds)
      performanceDetail = isInSpace ? "Space flight" : String(
        format: "%d terrain tiles · %.2fM triangles · %d streaming · upload %.1f ms",
        renderer.terrainTileCount,
        Double(renderer.terrainGeometryTriangles + renderer.ocean.triangleCount) / 1_000_000,
        renderer.streamingJobCount, renderer.lastUploadMilliseconds)
        + " · \(renderer.queuedTerrainTileCount) queued · detail \(detailDistance * 8) m · " + renderer.ocean.animationBackend
    }
    guard let start = performanceWindowStart, now - start >= 5 else { return }
    input.logDiagnostics(paused: isPaused, tracking: trackingStatus)
    performanceSequence += 1
    let rendering = renderer.consumeRenderingTiming()
    let water = renderer.ocean.consumePerformanceTiming()
    PerformanceTrace.emit(.init(
      run: performanceRun, sequence: performanceSequence, windowSeconds: now - start,
      build: PerformanceTrace.build, os: ProcessInfo.processInfo.operatingSystemVersionString,
      thermalState: PerformanceTrace.thermalState, gameUpdate: logTiming.snapshot,
      stateAtEnd: .init(
        mode: rocketJourney.map { "rocket_\($0.phase.rawValue)" } ?? (isInSpace ? "space" : renderer.boats.isSailing ? "sailing" : driving ? "driving" : swimming ? "swimming" : flying ? "flying" : "walking"),
        paused: isPaused, loading: isLoading, planet: planetName, seed: String(seed),
        drawDistanceChunks: renderDistance, drawDistanceMetres: renderDistance * 8,
        detailDistanceChunks: detailDistance, detailDistanceMetres: min(renderDistance, detailDistance) * 8,
        positionBlocks: isInSpace ? nil : [player.position.x, player.position.y, player.position.z]),
      sceneAtEnd: .init(
        terrainMesher: renderer.terrainMesherBackend, terrainCaveSampling: renderer.caveSamplingName,
        terrainTiles: renderer.terrainTileCount, terrainTriangles: renderer.terrainGeometryTriangles,
        terrainMaterialParts: renderer.terrainGeometryParts, waterTiles: renderer.ocean.count,
        waterTriangles: renderer.ocean.triangleCount, waterMaterialParts: renderer.ocean.drawParts,
        streamingJobs: renderer.streamingJobCount, queuedTerrainTiles: renderer.queuedTerrainTileCount,
        latestUploadMilliseconds: renderer.lastUploadMilliseconds,
        animals: animalCount, dinosaurs: dinosaurCount, residents: residentCount,
        waterBackend: renderer.ocean.animationBackend, waterBatches: renderer.ocean.batchCount,
        activeWaterBatches: renderer.ocean.activeBatchCount, queuedWaterBatches: renderer.ocean.queuedBatchCount,
        terrainWorkers: renderer.terrainWorkerCount, readyTerrainTiles: renderer.readyTerrainTileCount,
        windVertices: renderer.wind.animatedVertexCount, windTiles: renderer.wind.animatedTileCount,
        fireSources: renderer.fire.sourceCount, activeFireSources: renderer.fire.activeSourceCount,
        fireParticles: renderer.fire.particleCount, fireBatches: renderer.fire.batchCount,
        fireLights: renderer.fire.lightCount, fireBackend: renderer.fire.animationBackend,
        fireParticlesEnabled: renderer.fire.rendersParticles,
        localLampLights: renderer.lamps.activeLightCount, headlightBeams: renderer.vehicles.activeHeadlightCount,
        preparedCollisionChunks: renderer.preparedCollisionChunkCount,
        collisionCachedBlocks: renderer.collisionCachedBlockCount,
        collisionProceduralSamples: renderer.collisionProceduralSamples,
        collisionCacheHits: renderer.collisionCacheHits),
      waterComputeGPU: water.gpu, vegetationComputeGPU: renderer.wind.consumeGPUTiming(),
      simulation: renderer.life.consumePerformance(),
      hazeCPU: rendering.haze, terrainUploadCPU: rendering.upload,
      terrainStreaming: renderer.streamingMetrics, terrainDemandCache: renderer.demandMetrics,
      terrainFrontierPlanner: renderer.frontierPlanningMetrics,
      terrainPublicationBudget: renderer.publicationBudgetMetrics,
      incrementalTerrainCoverage: renderer.incrementalTerrainCoverage,
      terrainCoverageTracker: renderer.coverageTrackerMetrics,
      asynchronousTerrainPublication: renderer.asynchronousTerrainPublication,
      terrainNativePublication: renderer.nativePublicationMetrics,
      terrainNativeAdmission: renderer.nativeAdmissionMetrics,
      terrainTravelPrefetch: renderer.travelPrefetchMetrics,
      terrainDryRegions: renderer.dryRegionMetrics,
      terrainCoverage: renderer.coverageMetrics,
      regionalCaches: TerrainRegionalCaches.metrics,
      terrainTreePlans: TerrainTreePlans.metrics,
      terrainPayloadCache: TerrainPreparation.cacheMetrics,
      terrainRefinement: renderer.refinementMetrics,
      terrainBaseCache: TerrainPreparation.baseCacheMetrics,
      indexedTerrainWindPartition: TerrainPreparation.indexedWindPartition,
      terrainDiskCache: TerrainPreparation.diskCacheMetrics,
      terrainCoverageDetails: renderer.coverageDetails,
      terrainResources: .init(residentMeshBytes: renderer.residentMeshBytes,
        residentMeshCapacityBytes: renderer.residentMeshCapacityBytes,
        residentVoxelBytes: renderer.residentVoxelBytes, sceneRemovalCPU: rendering.removal,
        rendering: rendering.resources, seatInstancing: renderer.seatInstancingMetrics,
        surfaceSources: renderer.surfaceSourceMetrics,
        replacementVisibility: renderer.replacementVisibilityMetrics),
      phasesCPU: PerformanceTrace.consumePhases(), waterQueue: water,
      waterGeometry: renderer.ocean.geometryMetrics,
      waterSurfaceSources: renderer.ocean.sourceMetrics,
      waterAnimation: renderer.ocean.animationMetrics, waterDeformationWork: renderer.ocean.deformationWork,
      renderDiagnostics: .current,
      fireQueue: renderer.fire.consumePerformanceTiming(),
      memory: .init(physicalFootprintBytes: PerformanceTrace.physicalFootprint,
        metalAllocatedBytes: renderer.ocean.metalAllocatedBytes,
        metalRecommendedWorkingSetBytes: renderer.ocean.metalRecommendedBytes)))
    logTiming.reset()
    performanceWindowStart = now
  }

  private func blendArrival(frame:PlayerFrame,seconds:Float) {
    guard var blend=atmosphereTransition,blend.arriving,var observer=arrivingSpace else { return }
    blend.advance(seconds,ready:!isLoading)
    var spaceFrame=frame
    spaceFrame.feet=blend.spacePoint(frame.feet+[0,PlayerPhysics.eyeHeight,0])-[0,PlayerPhysics.eyeHeight,0]
    observer.position=spaceFrame.eye
    universe.update(observer,frame:spaceFrame,selectedPlanet:planetIndex,system:solarSystem,time:systemTime)
    renderer.root.components.set(OpacityComponent(opacity:blend.surfaceOpacity))
    universe.root.components.set(OpacityComponent(opacity:1-blend.surfaceOpacity))
    atmosphereTransition=blend
    if blend.finished {
      atmosphereTransition=nil; arrivingSpace=nil; universe.root.isEnabled=false
      universe.root.components.remove(OpacityComponent.self); renderer.root.components.remove(OpacityComponent.self)
    }
  }

  private func placeWorld(_ frame: PlayerFrame) {
    let rotation = frame.trackingFromWorldRotation
    let origin = frame.worldOriginInTracking
    // One transform write after movement; an idle frame leaves the entire
    // terrain hierarchy's transform cache intact. Head tracking stays native.
    if renderer.root.orientation.vector != rotation.vector || renderer.root.position != origin {
      renderer.root.transform = .init(scale: renderer.root.scale, rotation: rotation, translation: origin)
    }
    rockets.transform(frame)
  }

  private func cameraFrame(reference: SIMD3<Float>, trackedPosition: SIMD3<Float>, feet: SIMD3<Float>,
    seconds: Float, inSpace: Bool = false, rocketPosition: SIMD3<Float>? = nil
  ) -> PlayerFrame {
    var frame = PlayerFrame(referenceEye: reference, referenceOrientation: referenceOrientation,
      feet: feet, heading: heading, pitch: viewPitch)
    guard thirdPerson else { return frame }
    frame.cameraOffset = camera.offset(eye: frame.worldPoint(fromTracked: trackedPosition), heading: heading,
      pitch: viewPitch, seconds: seconds, block: { [renderer] position in
        if inSpace { return .air }
        return renderer.playerCameraBlock(at: position)
      }, occupied: { [renderer, rockets, elevators] point, radius in
        rockets.obstructsCamera(point, radius: radius, shipPosition: rocketPosition)
          || (!inSpace && (elevators.obstructsCamera(point, radius: radius)
            || renderer.vehicles.obstructsCamera(point, radius: radius) || renderer.boats.obstructsCamera(point, radius: radius)))
      })
    return frame
  }

  private func updateAvatar(frame: PlayerFrame, pose: simd_float4x4, seconds: Float,
    visible: Bool = true, inSpace: Bool = false
  ) {
    let look = frame.worldDirection(fromTracked: -SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z))
    avatar.update(frame: frame, feet: frame.feet, heading: mount?.heading ?? renderer.vehicles.heading ?? renderer.boats.heading ?? heading,
      look: look, seconds: seconds, time: environment.elapsed, visible: thirdPerson && visible,
      seated: mount != nil || inVehicle, swimming: swimming, flying: flying,
      lighting: inSpace ? universe.lighting : renderer.atmosphere.lighting)
  }

  private func worldMovement(
    _ frame: InputFrame, pose: simd_float4x4, heading: Float
  ) -> SIMD3<Float> {
    guard headDirectedMovement else {
      return LocomotionInput.worldMovement(frame.movement, heading: heading)
    }
    let rotation = worldFromTrackingRotation(heading: heading)
    var forward = rotation.act(-SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z))
    forward.y = 0
    forward =
      simd_length_squared(forward) < 0.001
      ? LocomotionInput.worldMovement([0, 1], heading: heading) : simd_normalize(forward)
    return simd_cross(forward, [0, 1, 0]) * frame.movement.x + forward * frame.movement.y
  }

  private func worldFromTrackingRotation(heading: Float) -> simd_quatf {
    PlayerFrame(referenceEye: .zero, referenceOrientation: referenceOrientation,
      feet: .zero, heading: heading, pitch: viewPitch).worldFromTrackingRotation
  }

  private func refreshHUD(now: Double) {
    guard now - lastHUDTime > 0.2 else { return }
    lastHUDTime = now
    coordinates =
      "\(Int(player.position.x)) / \(Int(player.position.y)) / \(Int(player.position.z))"
    chunkCount = renderer.renderedChunkCount
    worldClock = environment.clock
    tideDescription = renderer.terrain.style == .solar ? "Molten seas" : (environment.tide >= 0 ? "High tide" : "Low tide")
    animalCount = renderer.wildlife.count
    dinosaurCount = renderer.dinosaurs.count
    settlementName = isInSpace ? "" : renderer.settlementLife.settlementName
    residentCount = renderer.settlementLife.count
    if rocketJourney != nil || isInSpace { npcPrompt = "" }
    else if !renderer.boats.prompt.isEmpty && !driving { npcPrompt = renderer.boats.prompt }
    else if !renderer.doors.prompt.isEmpty { npcPrompt = renderer.doors.prompt }
    else if !elevators.prompt.isEmpty { npcPrompt = elevators.prompt }
    else if !renderer.sports.prompt.isEmpty {npcPrompt=renderer.sports.prompt}
    else if !ridePrompt.isEmpty { npcPrompt = ridePrompt }
    else if !rockets.prompt.isEmpty && !inVehicle { npcPrompt = rockets.prompt }
    else if !renderer.vehicles.prompt.isEmpty { npcPrompt = renderer.vehicles.prompt + (driving && !renderer.vehicles.isOnCircuit ? "\n" + landmarkDirections : "") }
    else if !renderer.wildlife.prompt.isEmpty && !inVehicle && !rockets.isInside(player.position) { npcPrompt = renderer.wildlife.prompt }
    else if !renderer.settlementLife.prompt.isEmpty { npcPrompt = renderer.settlementLife.prompt }
    else { npcPrompt = landmarkDirections }
    driving = renderer.vehicles.isDriving
    drivingSpeed = WorldScale.metres(renderer.vehicles.speed) * 3.6
    npcConversation = isInSpace ? "" : renderer.settlementLife.conversation
    reasoningStatus = renderer.deliberation.status
    npcDecisionStatus = renderer.settlementLife.decisionStatus
    biomeName = isInSpace ? "" : renderer.terrain.biome(atX: Int(floor(player.position.x)), z: Int(floor(player.position.z))).name
    flightSpeed = WorldScale.metres(space?.speed ?? simd_length(player.velocity))
    if isPaused {
      status = "Paused · Esc / Menu to resume"
    } else if inventoryOpen {
      status = "Inventory · I / B to close"
    } else if isLoading {
      status = isInSpace ? "Preparing planets…" : "Growing your world…"
    } else if rocketJourney != nil {
      status = rocketStatus
    } else if isInSpace {
      status = "Space flight · D-pad selects destination"
    } else {
      status = renderer.boats.isSailing ? "Sailing · \(String(format: "%.1f", renderer.boats.speed * 1.94384)) knots" : driving ? "Driving · \(Int(drivingSpeed)) km/h" :
        flying
        ? "Creative flight"
        : (swimming ? "Swimming" : input.runToggled ? "Running" : "Walking")
    }
  }

  func setInventoryOpen(_ open: Bool) {
    guard open != inventoryOpen, !open || (isImmersed && !isLoading && !isPaused) else { return }
    inventoryOpen = open
    inventorySource = nil
    inventoryCursor = selectedSlot
    resetGathering()
    doubleJump.reset()
    input.reset()
    audio.setPaused(open || isPaused)
    audio.play(open ? "inventory_open" : "inventory_close", at: player.position, root: renderer.root, time: CACurrentMediaTime())
    rockets.update(deltaTime: 0, player: player.position, phase: rocketJourney?.phase,
      clock: systemTime, paused: open || isPaused, effectsVolume: effectsVolume)
    if open { renderer.suspendLife() }
    else { scheduleSave() }
  }

  private func handleInventory(_ frame: InputFrame) {
    let column = min(8, max(0, inventoryCursor % 9 + frame.inventoryMove.x))
    let row = min(3, max(0, inventoryCursor / 9 + frame.inventoryMove.y))
    if inventoryCursor != row*9+column {
      audio.play("inventory_move", at: player.position, root: renderer.root, time: CACurrentMediaTime())
    }
    inventoryCursor = row * 9 + column
    selectedSlot = ((frame.selectedSlot ?? selectedSlot) + frame.slotDelta % 9 + 9) % 9
    if frame.inventoryConfirm { inventorySelect(inventoryCursor) }
    if frame.inventoryEquip { inventoryEquip() }
    if frame.inventoryDrop { inventoryDropOne() }
  }

  func inventorySelect(_ slot: Int) {
    guard inventoryOpen, (0..<Inventory.slotCount).contains(slot) else { return }
    inventoryCursor = slot
    audio.play("inventory_select", at: player.position, root: renderer.root, time: CACurrentMediaTime())
    if let source = inventorySource {
      inventory.move(from: source, to: slot)
      inventorySource = nil
      scheduleSave()
    } else if inventory[slot] != nil { inventorySource = slot }
  }

  func inventoryEquip() {
    guard inventoryOpen else { return }
    audio.play("inventory_select", at: player.position, root: renderer.root, time: CACurrentMediaTime())
    inventory.move(from: inventoryCursor, to: selectedSlot)
    inventorySource = nil
    scheduleSave()
  }

  func inventoryDropOne() {
    guard inventoryOpen, let stack = inventory[inventoryCursor] else { return }
    let now = CACurrentMediaTime()
    guard space == nil, rocketJourney == nil, !inVehicle, !rockets.isInside(player.position) else {
      gatheringMessage("Step outside on a planet to drop items.", now: now); return
    }
    let position = player.position + [0, PlayerPhysics.height * 0.55, 0]
      + LocomotionInput.worldMovement([0, 1], heading: heading) * 1.5
    guard renderer.loadedChunks.contains(BlockPosition(position).chunk),
      !renderer.actorBlock(at: BlockPosition(position)).isSolid,
      renderer.pickups.add(.init(stack.item, count: 1), at: position, delay: 1.5) else {
      gatheringMessage("No room to drop an item here.", now: now); return
    }
    inventory.consume(slot: inventoryCursor)
    inventorySource = nil
    gatheringMessage("Dropped \(stack.item.name)", now: now)
    scheduleSave()
  }

  private func resetGathering() {
    mining.reset();baseballThrow.reset();throwingStrength=0;throwingAccuracy=0
    gatheringProgress = 0
    targetName = ""
    actionButtonsArmed = false
    renderer.showSelection(nil)
    renderer.wildlife.clearFocus()
  }

  private func restoreGathering(_ saved: SavedPlanet?) {
    plantEdits = Dictionary((saved?.plantEdits ?? []).map { ($0.position, $0) }, uniquingKeysWith: { _, last in last })
    renderer.restorePlants(Array(plantEdits.values))
    renderer.pickups.restore(saved?.droppedItems ?? [])
    renderer.wildlife.restore(saved?.animalBonds ?? [])
    renderer.fauna.restore(saved?.fauna ?? [])
    resetGathering()
  }

  private var landmarkDirections: String {
    let landmarks = renderer.terrain.landmarks
    func distance(_ landmark: WorldLandmark) -> Float {
      let delta = landmark.entrance-player.position
      return sqrt(delta.x*delta.x+delta.z*delta.z)
    }
    func label(_ landmark: WorldLandmark) -> String {
      let delta = landmark.entrance-player.position
      let metres = Int(WorldScale.metres(distance(landmark)))
      let direction = abs(delta.x) > abs(delta.z) ? (delta.x > 0 ? "east" : "west") : (delta.z > 0 ? "south" : "north")
      return "\(landmark.name) · \(metres)m \(direction)"
    }
    let castle = landmarks.first { $0.kind == .castle }
    if let castle, distance(castle) < 65 {
      return label(castle) + " · South gate → winding rooms → stairs → upper sanctuary"
    }
    let circuit = landmarks.filter { $0.kind == .circuit }.min { distance($0) < distance($1) }
    var labels=[circuit,castle].compactMap { $0.map(label) }
    if let dock=renderer.boats.destination,let name=renderer.boats.marinaName {
      let d=dock-player.position
      let direction=abs(d.x)>abs(d.z) ? (d.x>0 ? "east":"west"):(d.z>0 ? "south":"north")
      labels.append("\(name) · \(Int(WorldScale.metres(simd_length(d))))m \(direction)")
    }
    return labels.joined(separator:" · ")
  }

  private func gatheringMessage(_ message: String, now: Double) {
    if gatheringNotice != message { gatheringNotice = message }
    noticeUntil = now + 3
  }

  private func feedAnimal(now: Double) {
    if renderer.wildlife.focusedPet,
      selectedItem?.food.map({ renderer.wildlife.focusedKind?.foods.contains($0) == true }) != true {
      if renderer.wildlife.petSelected(time: environment.elapsed) {
        hands.animateAction()
        gatheringMessage(renderer.wildlife.focusedDog ? "You pet the golden dog · That tail won't stop wagging!" : "You found Hay Hay! A gentle new friend who will follow you.", now: now)
        if let position = renderer.wildlife.focusedPosition {
          audio.play(renderer.wildlife.focusedDog ? "dog_bark" : "hay_hay", at: position, root: renderer.root, time: now, level: -8)
        }
        scheduleSave()
      }
      return
    }
    guard let item = selectedItem else {
      gatheringMessage("Select a harvested plant to feed this animal.", now: now); return
    }
    guard let result = renderer.wildlife.feedSelected(item, time: environment.elapsed) else { return }
    switch result {
    case .fed:
      audio.play("feed", at: renderer.wildlife.focusedPosition ?? player.position, root: renderer.root, time: now)
      inventory.consume(slot: selectedSlot)
      hands.animateAction()
      if renderer.wildlife.focusedDog, let bond = renderer.wildlife.focusedBond {
        gatheringMessage(bond.trusting ? "Boomer · You're friends!" : "Boomer loved that snack · Friendship \(bond.meals)/3", now: now)
      } else {
        gatheringMessage("Fed \(item.name) · Your new friend will follow you", now: now)
      }
      scheduleSave()
    case .disliked: gatheringMessage("This animal prefers different food.", now: now)
    case .chewing: gatheringMessage("Let your friend finish its meal.", now: now)
    }
  }

  private func updateGathering(frame: InputFrame, deltaTime: Float, now: Double,
    eye: SIMD3<Float>, direction: SIMD3<Float>, blocked: Bool) {
    guard !blocked, actionButtonsArmed else { resetGathering(); return }
    if selectedItem == .baseball {
      mining.reset();gatheringProgress=0;renderer.showSelection(nil)
      targetName="Baseball · Hold RT / left-click, release to throw"
      if frame.mine {baseballThrow.hold(seconds:deltaTime);throwingStrength=baseballThrow.strength;throwingAccuracy=baseballThrow.accuracy}
      else if baseballThrow.charge>0 {
        let origin=eye+direction*0.7
        if !renderer.actorBlock(at:.init(origin)).isSolid,
          renderer.sports.throwBall(origin:origin,velocity:baseballThrow.velocity(direction:direction,sequence:throwSequence),root:renderer.root) {
          inventory.consume(slot:selectedSlot);throwSequence+=1;hands.animateAction();scheduleSave()
        }
        baseballThrow.reset();throwingStrength=0;throwingAccuracy=0
      }
      return
    }
    baseballThrow.reset();throwingStrength=0;throwingAccuracy=0
    if frame.place && renderer.wildlife.hasFocus {
      mining.reset(); gatheringProgress = 0; renderer.showSelection(nil)
      if now - lastAction > 0.3 { lastAction = now; feedAnimal(now: now) }
      return
    }
    let hit = VoxelRaycast.cast(origin: eye, direction: direction, reach: 6, block: renderer.block)
    let plant = renderer.targetPlant(eye: eye, direction: direction, reach: min(6, hit?.distance ?? 6))?.0
    let target: MiningTarget? = plant.map { .init(position: $0.position, item: .plant($0.kind)) }
      ?? hit.map { .init(position: $0.block, item: .block(renderer.block(at: $0.block))) }
    let finished = mining.update(target: target, held: frame.mine && !frame.place, seconds: deltaTime)
    let fraction = (mining.fraction * 30).rounded(.down) / 30
    if gatheringProgress != fraction { gatheringProgress = fraction }
    let ownership = target.flatMap { renderer.settlementLife.homesteads.title(at: $0.position) }
    let name = (target?.item.name ?? "") + (ownership.map { " · " + $0 } ?? "")
    if targetName != name { targetName = name }
    renderer.showMining(center: plant?.center ?? hit?.block.center,
      size: plant.map { $0.maximum - $0.minimum + SIMD3<Float>(repeating: 0.1) } ?? .init(repeating: 1),
      progress: mining.fraction, solid: plant == nil)
    if frame.mine, let target, now - lastMiningSwing > 0.25 {
      hands.animateAction(); lastMiningSwing = now
      audio.play("hit_\(SoundSurface.material(target.item).rawValue)", at: target.position.center, root: renderer.root, time: now)
    }
    if finished, let target, renderer.loadedChunks.contains(target.position.chunk) {
      let supportedPlant: PlantInstance? = plant == nil
        ? renderer.plant(at: target.position + .init(0, 1, 0)) : nil
      let removedPlants = [plant, supportedPlant].compactMap { $0 }
      // Reserve all drops before altering terrain, including a plant whose soil
      // is being mined. Full bags leave physical drops safely in the world.
      guard renderer.pickups.freeSlots >= (supportedPlant == nil ? 1 : 2),
        plantEdits.count + removedPlants.filter({ plantEdits[$0.position] == nil }).count <= 200_000 else {
        mining.reset(); gatheringProgress = 0
        gatheringMessage("Collect nearby drops or make room in your backpack first.", now: now); return
      }
      for instance in removedPlants {
        changePlant(at: instance.position, to: nil)
        renderer.pickups.add(.init(.plant(instance.kind), count: 1), at: instance.center)
      }
      if plant == nil {
        change(target.position, to: .air)
        renderer.pickups.add(.init(target.item, count: 1), at: target.position.center)
      }
      audio.play("break_\(SoundSurface.material(target.item).rawValue)", at: target.position.center, root: renderer.root, time: now)
      mining.reset(); gatheringProgress = 0
      scheduleSave()
    } else if frame.place && now - lastAction > 0.22 {
      lastAction = now
      guard let item = selectedItem else {
        gatheringMessage("Hold RT / left-click to collect blocks and plants.", now: now); return
      }
      guard let hit, renderer.loadedChunks.contains(hit.adjacent.chunk) else { return }
      let position = hit.adjacent
      guard renderer.plant(overlapping: position) == nil else {
        gatheringMessage("Harvest the plant here first.", now: now); return
      }
      switch item {
      case .baseball: return
      case .block(let block):
        guard position.y > ChunkData.minimumY, position.y < ChunkData.height,
          !renderer.actorBlock(at: position).isSolid, !player.overlaps(position),
          !renderer.vehicles.obstructsPlayer(at: position.center), !rockets.obstructs(position.center) else { return }
        change(position, to: block.facing(direction))
      case .plant(let kind):
        guard kind.canPlant(at: position, block: renderer.actorBlock),
          plantEdits[position] != nil || plantEdits.count < 200_000 else {
          gatheringMessage(kind.aquatic ? "Plant this on a seabed beneath water." : "Plant this on open soil.", now: now)
          return
        }
        changePlant(at: position, to: kind)
      }
      inventory.consume(slot: selectedSlot)
      hands.animateAction()
      audio.play("place_\(SoundSurface.material(item).rawValue)", at: position.center, root: renderer.root, time: now)
      scheduleSave()
    }
  }

  private func changePlant(at position: BlockPosition, to kind: PlantKind?) {
    let edit = PlantEdit(position: position, kind: kind)
    plantEdits[position] = edit
    renderer.editPlant(edit)
  }

  private func updatePickups(deltaTime: Float, now: Double) {
    renderer.pickups.update(seconds: deltaTime, time: environment.elapsed, player: player.position,
      root: renderer.root, materials: renderer.materials, loaded: renderer.loadedChunks, terrain:renderer.terrain, block: renderer.block)
    guard !inVehicle, !rockets.isInside(player.position) else { return }
    var collected = false
    for drop in renderer.pickups.nearby(player: player.position, block: renderer.block) {
      guard inventory.capacity(for: drop.stack.item) > 0 else {
        if now >= noticeUntil { gatheringMessage("Backpack full · Open I / D-pad ↑ to make room", now: now) }
        continue
      }
      let remainder = inventory.collect(drop.stack.item, count: drop.stack.count)
      let count = drop.stack.count - remainder
      renderer.pickups.collect(id: drop.id, amount: count)
      gatheringMessage("+\(count) \(drop.stack.item.name)", now: now)
      collected = true
    }
    if collected {
      audio.play("pickup", at: player.position+[0,1,0], root: renderer.root, time: now)
      scheduleSave()
    }
  }

  private func change(_ position: BlockPosition, to block: Block) {
    let block = renderer.terrain.waterSafeMaterial(block, at: position)
    let old = renderer.block(at: position)
    edits[position] = block
    renderer.edit(position, to: block)
    renderer.settlementLife.witnessedEdit(at: position, old: old, new: block, terrain: renderer.terrain)
    if let body = renderer.terrain.waterBody(atX: position.x, z: position.z),
      abs(Float(position.y) - body.level) < 2
    {
      environment.disturbWater(
        atX: Float(position.x) + 0.5, z: Float(position.z) + 0.5, body: body, energy: 0.20)
    }
  }

  /// Validation is side-effect free. A simulation proposal commits its complete
  /// set of world effects and matching life records in one MainActor turn.
  private func autonomousEdit(_ p: BlockPosition, expected: Block, replacement: Block, commit: Bool = true) -> Bool {
    guard !isPaused, !inventoryOpen, !isInSpace, renderer.loadedChunks.contains(p.chunk),
      p.y > ChunkData.minimumY, p.y < ChunkData.height,
      renderer.block(at: p) == expected, renderer.entityObstacle?(p) != true else { return false }
    if replacement.isSolid {
      guard !expected.isSolid, !player.overlaps(p),
        !renderer.vehicles.obstructsPlayer(at: p.center), !rockets.obstructs(p.center),
        !renderer.settlementLife.positions.contains(where: { abs($0.x - p.center.x) < 0.8 && abs($0.z - p.center.z) < 0.8 && p.center.y >= $0.y && p.center.y < $0.y + 3.5 }) else { return false }
    } else {
      guard expected.isSolid, edits[p] == nil,
        SettlementGenerator.site(at: p, terrain: renderer.terrain) == nil,
        renderer.terrain.block(at: p) == expected else { return false }
    }
    let plant = replacement.isSolid ? renderer.plant(overlapping: p) : renderer.plant(at: p + .init(0, 1, 0))
    if let plant {
      guard plantEdits[plant.position] != nil || plantEdits.count < 200_000 else { return false }
      if commit { changePlant(at: plant.position, to: nil) }
    }
    guard commit else { return true }
    edits[p] = replacement; renderer.edit(p, to: replacement)
    autonomousDirty = true
    return true
  }

  private func commitLifeEffects(_ effects: [LifeEffect]) -> Bool {
    guard !isPaused, !inventoryOpen, !isInSpace else { return effects.isEmpty }
    var plantReservations = Set<BlockPosition>()
    for effect in effects {
      switch effect {
      case .edit(let point, let expected, let replacement):
        guard autonomousEdit(point, expected: expected, replacement: replacement, commit: false) else { return false }
        let plant = replacement.isSolid ? renderer.plant(overlapping: point) : renderer.plant(at: point + .init(0, 1, 0))
        if let plant, plantEdits[plant.position] == nil { plantReservations.insert(plant.position) }
      case .eat(let point, let kind):
        guard renderer.loadedChunks.contains(point.chunk), renderer.plant(at: point)?.kind == kind else { return false }
        if plantEdits[point] == nil { plantReservations.insert(point) }
      case .hunt(let id):
        guard renderer.wildlife.contains(id: id) || renderer.dinosaurs.contains(id: id) else { return false }
      case .trample(let blocks,let plants):
        guard blocks.count<=512,plants.count<=128,blocks.allSatisfy({
          renderer.loadedChunks.contains($0.position.chunk) && $0.position.y>ChunkData.minimumY
            && $0.position.y<ChunkData.height && renderer.block(at:$0.position) == $0.material
            && $0.material.isSolid && renderer.entityObstacle?($0.position) != true
        }),plants.allSatisfy({ renderer.plant(at:$0.position)?.kind == $0.kind }) else { return false }
        for plant in plants where plantEdits[plant.position] == nil { plantReservations.insert(plant.position) }
      }
    }
    guard plantEdits.count + plantReservations.count <= 200_000 else { return false }
    // No suspension between preflight and publication; nothing can invalidate
    // this batch part-way through, including the shared plant-edit capacity.
    for effect in effects {
      switch effect {
      case .edit(let point, let expected, let replacement):
        _ = autonomousEdit(point, expected: expected, replacement: replacement)
      case .eat(let point, _): changePlant(at: point, to: nil); autonomousDirty = true
      case .hunt(let id): _ = renderer.wildlife.removePrey(id: id) || renderer.dinosaurs.removePrey(id: id)
      case .trample(let blocks,let plants):
        PerformanceTrace.measure(.colossalDestruction) {
          for block in blocks { edits[block.position] = .air }
          let removed=plants.map { PlantEdit(position:$0.position,kind:nil) }
          for plant in removed { plantEdits[plant.position]=plant }
          renderer.trample(blocks,plants:removed)
        }
        autonomousDirty=true
      }
    }
    return true
  }

  private func applyResidentInterventions(now: Double) {
    for (name, point) in renderer.settlementLife.homesteads.takeInterventions() {
      guard !inVehicle, !player.flying, !rockets.isInside(player.position) else { continue }
      resetGathering()
      let away = player.position - point
      let direction = simd_normalize(SIMD3<Float>(away.x + 0.01, 0, away.z + 0.01))
      // Swept, short steps cannot shove a player through a wall or off a ledge.
      for _ in 0..<5 {
        let next = player.position + direction * 0.12
        guard renderer.loadedChunks.contains(BlockPosition(next).chunk),
          !player.collides(at: next, block: renderer.actorBlock),
          renderer.block(at: BlockPosition(next) + .init(0, -1, 0)).isSolid,
          !renderer.vehicles.obstructsPlayer(at: next), !rockets.obstructs(next) else { break }
        player.position = next
      }
      gatheringMessage("\(name) stopped you from damaging the home", now: now)
    }
  }

  private func progress() -> SavedPlanet {
    let savedPosition = mount.flatMap { $0.dismount(block: renderer.actorBlock) ?? $0.boardedAt }
      ?? elevators.safeSavePosition ?? rocketJourney?.port.exit ?? renderer.vehicles.safeSavePosition(block: renderer.actorBlock) ?? player.position
    return .init(
      index: planetIndex, edits: edits.map { .init(position: $0.key, block: $0.value) },
      player: [savedPosition.x, savedPosition.y, savedPosition.z], heading: heading,
      worldTime: environment.elapsed, residents: renderer.settlementLife.records, vehicles: renderer.vehicles.records,
      plantEdits: Array(plantEdits.values), droppedItems: renderer.pickups.records, animalBonds: renderer.wildlife.records,
      homes: renderer.settlementLife.homesteads.records, fauna: renderer.fauna.records, boats:renderer.boats.records)
  }

  /// The old scene keeps rendering while its simulation drains. This barrier is
  /// only for world changes; a RealityKit frame callback never awaits an actor.
  private func transitionLife(_ action: @escaping @MainActor () -> Void) {
    guard lifeTransition == nil else { return }
    let lifetime = lifecycle
    renderer.suspendLife()
    lifeTransition = Task { [weak self] in
      guard let self else { return }
      await self.renderer.life.flush()
      guard !Task.isCancelled, self.isImmersed, self.lifecycle == lifetime else { return }
      action()
      self.lifeTransition = nil
    }
  }

  private func departPlanet() {
    transitionLife { [weak self] in self?.finishDeparture() }
  }
  private func finishDeparture() {
    mount=nil; renderer.mount=nil; mountCandidate=nil; ridePrompt=""
    renderer.wildlife.riddenID=nil; renderer.dinosaurs.riddenID=nil
    resetGathering()
    rockets.root.isEnabled = false
    rocketStatus = ""
    renderer.suspendLife()
    planetProgress[planetIndex] = progress()
    let origin=solarSystem.planets[planetIndex]
    var departing=SpaceFlight(departing:origin,heading:heading,time:systemTime)
    let ground=Float(origin.terrain.height(atX:Int(player.position.x),z:Int(player.position.z)))
    // Space has a compressed planetary scale. Keep the surface/space charts
    // continuous without placing the ship beyond a neighboring orbit.
    let shellHeight: Float = 85+max(0,player.position.y-ground-SolarSystem.departureAltitude)
    departing.position=origin.position(at:systemTime)+[0,origin.radius+shellHeight,0]
    departing.velocity=player.velocity
    space=departing
    atmosphereTransition = .init(surface:player.position+[0,PlayerPhysics.eyeHeight,0],space:departing.position,arriving:false)
    universe.root.components.set(OpacityComponent(opacity:0))
    isInSpace = true
    isLoading = false
    flying = true
    swimming = false
    destinationIndex = (planetIndex + 1) % solarSystem.planets.count
    renderer.root.isEnabled = true
    underwaterOverlay.isEnabled = false
    cloudOverlay.isEnabled = false
    biteOverlay.isEnabled = false
    renderer.showSelection(nil)
    targetName = ""
    hands.configure(parent: headAnchor, lighting: universe.lighting)
    audio.setSpace(true)
    scheduleSave()
  }

  private func updateSpace(
    frame: InputFrame, deltaTime: Float, now: Double, reference: SIMD3<Float>,
    trackedPosition: SIMD3<Float>, pose: simd_float4x4
  ) {
    guard var ship = space else { return }
    rockets.root.isEnabled = false
    isInSpace = true
    isLoading = !universe.isReady
    flying = true
    if !isLoading && !isPaused && !inventoryOpen && !exitRequested && lifeTransition == nil {
      environment.advance(Double(deltaTime))
      systemTime += Double(deltaTime)
      destinationIndex =
        (destinationIndex + frame.destinationDelta + solarSystem.planets.count)
        % solarSystem.planets.count
      selectedSlot =
        (selectedSlot + frame.slotDelta % Inventory.hotbarCount + Inventory.hotbarCount)
        % Inventory.hotbarCount
      if let slot = frame.selectedSlot { selectedSlot = slot }
      ship.heading += frame.turn
      viewPitch = LocomotionInput.clampSpacePitch(viewPitch + frame.lookPitch)
      var movement = LocomotionInput.spaceMovement(frame.movement, ascend: frame.ascend,
        heading: ship.heading, pitch: viewPitch)
      if headDirectedMovement {
        let local = SIMD3<Float>(frame.movement.x, frame.ascend, -frame.movement.y)
        let head = simd_quatf(pose)
        movement = worldFromTrackingRotation(heading: ship.heading).act(head.act(local))
      }
      if let planet = ship.update(
        deltaTime: deltaTime, movement: movement, sprint: frame.sprint, system: solarSystem, time: systemTime)
      {
        space = ship
        arriveOnPlanet(planet)
        return
      }
    }
    space = ship
    updateAudioScene(now: now)
    heading = ship.heading
    renderer.root.isEnabled = false
    let coordinateFrame = cameraFrame(reference: reference, trackedPosition: trackedPosition,
      feet: ship.position - [0, PlayerPhysics.eyeHeight, 0], seconds: isPaused || inventoryOpen ? 0 : deltaTime,
      inSpace: true)
    updateAvatar(frame: coordinateFrame, pose: pose, seconds: isPaused || inventoryOpen ? 0 : deltaTime,
      inSpace: true)
    universe.update(ship, frame: coordinateFrame, selectedPlanet: destinationIndex,
      system: solarSystem, time: systemTime)
    if var blend=atmosphereTransition, !blend.arriving {
      blend.advance(isPaused || inventoryOpen ? 0:deltaTime)
      var surfaceFrame=coordinateFrame
      surfaceFrame.feet=blend.surfacePoint(coordinateFrame.feet+[0,PlayerPhysics.eyeHeight,0])-[0,PlayerPhysics.eyeHeight,0]
      placeWorld(surfaceFrame)
      renderer.root.isEnabled=true
      renderer.root.components.set(OpacityComponent(opacity:blend.surfaceOpacity))
      universe.root.components.set(OpacityComponent(opacity:1-blend.surfaceOpacity))
      atmosphereTransition=blend
      if blend.finished { atmosphereTransition=nil; renderer.root.isEnabled=false; renderer.root.components.remove(OpacityComponent.self); universe.root.components.remove(OpacityComponent.self) }
    }
    renderer.atmosphere.update(
      environment: environment, eye: coordinateFrame.worldPoint(fromTracked: trackedPosition),
      worldRotation: coordinateFrame.trackingFromWorldRotation, trackedPosition: trackedPosition, space: true)
    hands.update(
      deltaTime: isPaused || inventoryOpen ? 0 : deltaTime, movement: 0,
      visible: showHands && !thirdPerson && !isPaused && !inventoryOpen)
    do { try hands.select(selectedItem, materials: renderer.materials) } catch {
      errorMessage = "Could not display your held block: \(error.localizedDescription)"
    }
    let destination = solarSystem.planets[destinationIndex]
    destinationName = destination.name
    let delta = destination.position(at: systemTime) - ship.position
    let bearing = atan2(-delta.x, -delta.z) - ship.heading
    let angle = atan2(sin(bearing), cos(bearing)) * 180 / .pi
    navigation =
      "\(Int(WorldScale.metres(ship.distance(to: destination, time: systemTime)))) m · \(angle >= 0 ? "left" : "right") \(Int(abs(angle)))° · \(delta.y >= 0 ? "rise" : "descend") \(Int(WorldScale.metres(abs(delta.y)))) m"
    refreshHUD(now: now)
    if now - lastSaveTime > 5 {
      lastSaveTime = now
      scheduleSave()
    }
  }

  private func arriveOnPlanet(_ index: Int) {
    transitionLife { [weak self] in self?.finishArrival(index) }
  }
  private func finishArrival(_ index: Int) {
    rocketSearch?.cancel(); rocketRegion = nil
    elevators.clear(); rockets.setPort(nil, lighting: renderer.atmosphere.lighting)
    rocketStatus = ""
    viewPitch = LocomotionInput.clampLookPitch(viewPitch)
    planetProgress[planetIndex] = progress()
    let arrivingHeading = space?.heading ?? heading
    arrivingSpace=space
    planetIndex = index
    let planet = solarSystem.planets[index]
    let terrain = planet.terrain
    seed = planet.seed
    planetName = planet.name
    if let saved = planetProgress[index] {
      edits = Dictionary(
        saved.edits.map { ($0.position, $0.block) }, uniquingKeysWith: { _, latest in latest })
      environment = .init(elapsed: saved.worldTime)
      player = .init(position: [saved.player[0], saved.player[1], saved.player[2]])
      let ground = terrain.height(atX: Int(player.position.x), z: Int(player.position.z))
      player.position.y = Float(ground)+SolarSystem.departureAltitude*0.95
    } else {
      edits = [:]
      environment = .init()
      player = .init(position: terrain.spawn())
      player.position.y += SolarSystem.departureAltitude*0.95
    }
    while player.position.y < 175
      && player.collides(at: player.position, block: { edits[$0] ?? terrain.block(at: $0) })
    { player.position.y += 2 }
    heading = arrivingHeading
    player.flying = true
    flying = true
    if let observer=arrivingSpace {
      atmosphereTransition = .init(surface:player.position+[0,PlayerPhysics.eyeHeight,0],space:observer.position,arriving:true)
    }
    space = nil
    isInSpace = false
    universe.root.isEnabled = arrivingSpace != nil
    universe.root.components.remove(OpacityComponent.self)
    doubleJump.reset()
    wasTouchingWater = false
    swimming = false
    ambienceCenter = nil
    lastStepPosition = player.position
    lastAnimalSound = environment.elapsed
    isLoading = true
    do {
      try renderer.configure(
        seed: seed, style: planet.style, edits: edits, environment: environment)
      renderer.root.components.set(OpacityComponent(opacity:0))
      restoreGathering(planetProgress[index])
      renderer.settlementLife.restore(planetProgress[index]?.residents ?? [], homes: planetProgress[index]?.homes ?? [])
      renderer.vehicles.restore(planetProgress[index]?.vehicles ?? [])
      renderer.boats.restore(planetProgress[index]?.boats ?? [])
      renderer.stream(around: player.position, radius: renderDistance, detailRadius: detailDistance)
      hands.configure(parent: headAnchor, lighting: renderer.atmosphere.lighting)
    } catch {
      errorMessage = "Could not land on \(planet.name): \(error.localizedDescription)"
      setPaused(true)
    }
    let lifetime = lifecycle
    Task { [weak self] in
      guard let self, self.isImmersed && lifetime == self.lifecycle else { return }
      do {
        try await self.audio.start(
          root: self.renderer.root, generator: terrain, player: self.player.position)
      } catch {
        self.errorMessage = "Could not start planetary sounds: \(error.localizedDescription)"
      }
      if self.isPaused { self.audio.setPaused(true) }
    }
    scheduleSave()
  }

  func beginWorldRecenter() {
    isRecentering = true
    input.reset()
  }

  func recenterOrientation() {
    // Capture on the next valid ARKit frame, after the system has moved its origin.
    // Keep the virtual position/heading and let this physical pose become neutral.
    reference = nil
    viewPitch = 0
    isRecentering = false
    doubleJump.reset()
    input.reset()
    resetGathering()
  }

  func sceneActivityChanged(isActive: Bool) {
    input.setSceneActive(isActive)
    // The iPad scene also owns the lobby. Losing focus there must never save an
    // unprepared/default world over the player's existing save.
    if !isActive && isImmersed { setPaused(true) }
  }

  func setPaused(_ paused: Bool) {
    if paused { setInventoryOpen(false); resetGathering() }
    isPaused = paused
    doubleJump.reset()
    audio.setPaused(paused)
    rockets.update(deltaTime: 0, player: player.position, phase: rocketJourney?.phase,
      clock: systemTime, paused: paused, effectsVolume: effectsVolume)
    if paused { renderer.suspendLife() }
    if paused { biteOverlay.isEnabled = false; dinosaurMessage = "" }
    if paused { scheduleSave() }
  }

  private func snapshot() -> WorldSave {
    var worlds = planetProgress
    let current = progress()
    worlds[planetIndex] = current
    return .init(
      seed: baseSeed, edits: edits.map { .init(position: $0.key, block: $0.value) },
      player: current.player, flying: player.flying,
      heading: heading, selectedSlot: selectedSlot, worldTime: environment.elapsed,
      planetIndex: planetIndex,
      visitedPlanets: worlds.values.sorted { $0.index < $1.index }, space: space,
      systemTime: systemTime, viewPitch: viewPitch, residents: renderer.settlementLife.records, vehicles: renderer.vehicles.records,
      rocket: rocketJourney, inventory: inventory, plantEdits: Array(plantEdits.values),
      droppedItems: renderer.pickups.records, animalBonds: renderer.wildlife.records,
      homes: renderer.settlementLife.homesteads.records, fauna: renderer.fauna.records, hayHays: hayHays, boats:renderer.boats.records, boatDriver:renderer.boats.driverID)
  }

  private func scheduleSave() {
    guard isImmersed else { return }
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(500))
        guard let self else { return }
        await self.renderer.life.flush()
        try Task.checkCancellation()
        let save = self.snapshot()
        try await self.saveStore.write(save)
        self.restoredSave = save
      } catch is CancellationError {} catch {
        self?.errorMessage = "Could not save your world: \(error.localizedDescription)"
      }
    }
  }

  /// iPad can be suspended before a debounced autosave runs. The scene grants a
  /// short background task while this checkpoint drains in-flight life effects.
  func saveCheckpoint() async {
    guard isImmersed else { return }
    let lifetime = lifecycle
    saveTask?.cancel()
    await renderer.life.flush()
    guard isImmersed, lifecycle == lifetime, !Task.isCancelled else { return }
    do {
      let save = snapshot()
      try await saveStore.write(save)
      restoredSave = save
    } catch { errorMessage = "Could not save your world: \(error.localizedDescription)" }
  }

  func saveAndStop() async {
    guard isImmersed else { return }
    isStopping = true
    defer { isStopping = false }
    isImmersed = false
    renderer.suspendLife()
    lifecycle = UUID()
    preparation.cancel()
    startupWatchdog?.cancel(); startupWatchdog = nil
    saveTask?.cancel()
    subscription?.cancel()
    subscription = nil
    trackingTask?.cancel()
    trackingTask = nil
    #if os(visionOS)
    arSession.stop()
    #endif
    input.stop()
    audio.stop()
    rocketSearch?.cancel(); rocketSearch = nil; rocketLaunch?.cancel(); rocketLaunch = nil
    lifeTransition?.cancel(); lifeTransition = nil
    await renderer.life.flush()
    let save = snapshot()
    do {
      try await saveStore.write(save)
      restoredSave = save
      status = "World saved. See you out there."
    } catch { errorMessage = "Could not save your world: \(error.localizedDescription)" }
    renderer.clear()
    camera.reset(); avatar.reset()
    hands.clear()
    universe.clear()
    atmosphereTransition=nil; arrivingSpace=nil
    universe.root.components.remove(OpacityComponent.self); renderer.root.components.remove(OpacityComponent.self)
    elevators.clear(); rockets.clear()
    reference = nil
    headAnchor.children.removeAll()
  }

  func report(_ message: String) {
    errorMessage = message
    isLoading = false
  }
}

extension GameSession {
  private func findNearbyRocket() {
    guard rocketJourney == nil, space == nil else { return }
    if rocketLocalSite != renderer.settlementLife.currentSite?.id {
      rocketLocalSite = renderer.settlementLife.currentSite?.id
      if let local = renderer.settlementLife.currentSite?.rocketPort,
        local != rockets.port, !rockets.isInside(player.position),
        local.accepts(edits: edits.map { .init(position: $0.key, block: $0.value) }) {
        rockets.setPort(local, lighting: renderer.atmosphere.lighting)
      }
    }
    let cell = BlockPosition(player.position)
    let region = ChunkCoordinate(floorDivide(cell.x, by: SettlementGenerator.regionSize),
      floorDivide(cell.z, by: SettlementGenerator.regionSize))
    guard rocketRegion != region else { return }
    rocketRegion = region; rocketSearch?.cancel()
    let terrain = renderer.terrain, point = player.position, index = planetIndex, lifetime = lifecycle
    let changes = edits.map { SavedEdit(position: $0.key, block: $0.value) }
    rocketSearch = Task { [weak self] in
      let port = await Task.detached(priority: .utility) {
        RocketPort.nearest(to: point, terrain: terrain, edits: changes)
      }.value
      guard let self, !Task.isCancelled, self.lifecycle == lifetime, self.planetIndex == index,
        self.rocketJourney == nil, self.space == nil, self.rocketRegion == region else { return }
      self.rocketSearch = nil
      guard !self.rockets.isInside(self.player.position) else { return }
      let local = self.renderer.settlementLife.currentSite?.rocketPort
      let currentEdits = self.edits.map { SavedEdit(position: $0.key, block: $0.value) }
      let preferred = local.flatMap { $0.accepts(edits: currentEdits) ? $0 : nil } ?? port
      self.rockets.setPort(preferred, lighting: self.renderer.atmosphere.lighting)
      if port == nil { self.rocketStatus = "No spaceport in this area" }
    }
  }

  private func changeRocketDestination(_ delta: Int) {
    let count = solarSystem.planets.count, step = delta >= 0 ? 1 : -1
    destinationIndex = (destinationIndex + step + count) % count
    if destinationIndex == planetIndex { destinationIndex = (destinationIndex + step + count) % count }
    rocketNotice = ""
  }

  private func requestRocketLaunch() {
    guard rocketLaunch == nil, rocketJourney == nil, !isPaused, !inVehicle,
      let origin = rockets.port, rockets.isInside(player.position) else { return }
    guard origin.accepts(edits: edits.map { .init(position: $0.key, block: $0.value) }) else {
      rocketNotice = "Clear the launch pad and the sky above it before launching."
      return
    }
    if destinationIndex == planetIndex { changeRocketDestination(1) }
    let destination = solarSystem.planets[destinationIndex], originIndex = planetIndex, lifetime = lifecycle
    let saved = planetProgress[destination.index]
    rocketNotice = "Finding a clear landing pad…"; rocketStatus = rocketNotice
    rocketLaunch = Task { [weak self] in
      let port = await Task.detached(priority: .userInitiated) {
        let terrain = destination.terrain
        let point: SIMD3<Float> = saved.map { [$0.player[0], $0.player[1], $0.player[2]] } ?? terrain.spawn()
        return RocketPort.nearest(to: point, terrain: terrain, edits: saved?.edits ?? [], maximumRegionRadius: 12)
      }.value
      guard let self, !Task.isCancelled, self.isImmersed, lifetime == self.lifecycle else { return }
      await self.renderer.life.flush()
      guard !Task.isCancelled, self.isImmersed, lifetime == self.lifecycle else { return }
      self.rocketLaunch = nil
      guard self.planetIndex == originIndex, self.rockets.port == origin,
        self.rockets.isInside(self.player.position), !self.isPaused else {
        self.rocketNotice = "Launch cancelled · return to the cabin button"; return
      }
      guard let port else {
        self.rocketNotice = "No clear spaceport found on \(destination.name). Choose another planet."; return
      }
      self.planetProgress[originIndex] = self.progress()
      self.rocketJourney = .init(originPlanet: originIndex, destinationPlanet: destination.index,
        origin: origin, destination: port, passenger: self.player.position - origin.center)
      self.destinationIndex = destination.index
      self.rocketWelcomePrepared = false
      self.rocketNotice = ""
      self.resetGathering()
      self.rockets.closeForLaunch()
      self.player.flying = false; self.player.verticalVelocity = 0; self.flying = false
      self.swimming = false; self.doubleJump.reset(); self.input.reset()
      self.renderer.showSelection(nil); self.targetName = ""
      print("WORLDCRAFT_ROCKET event=launch origin=\(originIndex) destination=\(destination.index) landing_x=\(port.x) landing_z=\(port.z)")
      self.scheduleSave()
    }
  }

  private func prepareRocketDestination(_ journey: RocketJourney) throws {
    guard planetIndex != journey.destinationPlanet else { return }
    planetProgress[planetIndex] = progress()
    let planet = solarSystem.planets[journey.destinationPlanet]
    let saved = planetProgress[journey.destinationPlanet]
    let changes = Dictionary((saved?.edits ?? []).map { ($0.position, $0.block) }, uniquingKeysWith: { _, last in last })
    let clock = WorldEnvironment(elapsed: saved?.worldTime ?? WorldEnvironment.dayDuration * 0.38)
    try renderer.configure(seed: planet.seed, style: planet.style, edits: changes, environment: clock)
    restoreGathering(saved)
    renderer.settlementLife.restore(saved?.residents ?? [], homes: saved?.homes ?? [])
    renderer.vehicles.restore(saved?.vehicles ?? [])
    renderer.boats.restore(saved?.boats ?? [])
    planetIndex = planet.index; seed = planet.seed; planetName = planet.name
    edits = changes; environment = clock; ambienceCenter = nil; lastAnimalSound = clock.elapsed
    rockets.setPort(journey.destination, lighting: universe.lighting)
    rocketRegion = nil
    let lifetime = lifecycle
    Task { [weak self] in
      guard let self, self.isImmersed, lifetime == self.lifecycle else { return }
      do {
        try await self.audio.start(root: self.renderer.root, generator: planet.terrain, player: journey.destination.center)
        guard self.isImmersed, lifetime == self.lifecycle else { return }
        self.audio.setSpace(self.rocketJourney?.phase == .cruise)
        if self.isPaused { self.audio.setPaused(true) }
      } catch { self.errorMessage = "Could not start planetary sounds: \(error.localizedDescription)" }
    }
  }

  private func updateRocket(frame: InputFrame, deltaTime: Float, now: Double,
    reference: SIMD3<Float>, trackedPosition: SIMD3<Float>, pose: simd_float4x4) {
    guard var journey = rocketJourney else { return }
    let waitingForSpace = journey.phase == .cruise && !universe.isReady
    let active = !waitingForSpace && !isPaused && !inventoryOpen && !exitRequested && lifeTransition == nil
    let dt: Float = active ? deltaTime : 0
    renderer.stream(around: journey.port.center, radius: renderDistance, detailRadius: detailDistance)
    let terrainReady = journey.port.chunks.isSubset(of: renderer.loadedChunks)
    if journey.usesDestination && terrainReady && !rocketWelcomePrepared {
      rocketWelcomePrepared = renderer.settlementLife.prepareRocketWelcome(port: journey.destination,
        terrain: renderer.terrain, time: environment.elapsed)
    }
    if (journey.phase == .cruise || journey.phase == .landed) && rocketWelcomePrepared {
      renderer.updateLife(deltaTime: dt, player: journey.destination.center, environment: environment)
      renderer.settlementLife.update(terrain: renderer.terrain, player: journey.destination.center,
        deltaTime: dt, environment: environment, threats: [], root: renderer.root,
        loaded: renderer.loadedChunks, block: renderer.actorBlock)
    }
    if active {
      environment.advance(Double(dt)); systemTime += Double(dt)
      heading += frame.turn; heading.formTruncatingRemainder(dividingBy: .pi * 2)
      viewPitch = LocomotionInput.clampLookPitch(viewPitch + frame.lookPitch)
      journey.passenger = RocketCabin.passenger(journey.passenger,
        movement: worldMovement(frame, pose: pose, heading: heading), deltaTime: dt)
    }
    if journey.phase == .countdown && rockets.doorOpen<0.001 {
      let beat=Int(journey.elapsed)
      if beat != lastCountdown {
        lastCountdown=beat; audio.play("countdown",at:player.position,root:renderer.root,time:now)
      }
    } else { lastCountdown = -1 }
    let previous = journey.phase
    journey.advance(seconds: journey.phase == .countdown && !terrainReady ? 0 : Double(dt),
      doorClosed: rockets.doorOpen < 0.001,
      landingReady: terrainReady && rocketWelcomePrepared && renderer.settlementLife.welcomeReady)
    rocketJourney = journey
    updateAudioScene(now: now)
    if journey.usesDestination && planetIndex != journey.destinationPlanet {
      transitionLife { [weak self] in
        guard let self else { return }
        do { try self.prepareRocketDestination(journey) }
        catch { self.errorMessage = "Could not prepare the rocket landing: \(error.localizedDescription)"; self.setPaused(true) }
      }
      return
    }
    if journey.phase != previous {
      print("WORLDCRAFT_ROCKET phase=\(journey.phase.rawValue) planet=\(planetIndex) terrain_ready=\(terrainReady) welcome_ready=\(renderer.settlementLife.welcomeReady)")
    }
    let inSpace = journey.phase == .cruise
    isInSpace = inSpace; isLoading = waitingForSpace; flying = false
    let destination = solarSystem.planets[journey.destinationPlanet].name
    if destinationName != destination { destinationName = destination }
    let shipPosition = inSpace ? journey.spacePosition(system: solarSystem, time: systemTime) : journey.surfacePosition
    player.position = journey.surfacePosition + journey.passenger
    let coordinateFrame = cameraFrame(reference: reference, trackedPosition: trackedPosition,
      feet: shipPosition + journey.passenger, seconds: dt, inSpace: inSpace, rocketPosition: shipPosition)
    updateAvatar(frame: coordinateFrame, pose: pose, seconds: dt, inSpace: inSpace)
    let lighting = inSpace ? universe.lighting : renderer.atmosphere.lighting
    rockets.place(at: shipPosition, frame: coordinateFrame, lighting: lighting)
    rockets.root.isEnabled = true
    rockets.update(deltaTime: dt, player: shipPosition + journey.passenger, phase: journey.phase,
      clock: systemTime, paused: !active, effectsVolume: effectsVolume)
    if inSpace {
      universe.root.components.remove(OpacityComponent.self)
      renderer.root.components.remove(OpacityComponent.self)
      renderer.root.isEnabled = false
      var observer = SpaceFlight(departing: solarSystem.planets[journey.originPlanet], heading: heading, time: systemTime)
      observer.position = coordinateFrame.eye
      universe.update(observer, frame: coordinateFrame, selectedPlanet: journey.destinationPlanet,
        system: solarSystem, time: systemTime)
      renderer.atmosphere.update(environment: environment, eye: coordinateFrame.worldPoint(fromTracked: trackedPosition),
        worldRotation: coordinateFrame.trackingFromWorldRotation, trackedPosition: trackedPosition, space: true)
    } else {
      let orbitalBlend=journey.phase == .ascent || journey.phase == .descent
        ? smoothstep(SolarSystem.departureAltitude*0.72,SolarSystem.departureAltitude+80,
          journey.surfacePosition.y-Float(journey.port.floor)):0
      universe.root.isEnabled=orbitalBlend>0
      if orbitalBlend>0 {
        let world=solarSystem.planets[journey.phase == .ascent ? journey.originPlanet:journey.destinationPlanet]
        let anchor=world.position(at:systemTime)+[0,world.radius+43+12*orbitalBlend,0]
        var orbitFrame=coordinateFrame
        orbitFrame.feet=anchor+journey.passenger
        var observer=SpaceFlight(departing:world,heading:heading,time:systemTime)
        observer.position=orbitFrame.eye
        universe.update(observer,frame:orbitFrame,selectedPlanet:journey.destinationPlanet,system:solarSystem,time:systemTime)
        universe.root.components.set(OpacityComponent(opacity:orbitalBlend))
      }
      renderer.root.components.set(OpacityComponent(opacity:1-orbitalBlend))
      renderer.root.isEnabled = true
      placeWorld(coordinateFrame)
      renderer.settlementLife.homesteads.playerFlying = player.flying
      renderer.settlementLife.homesteads.playerDriving = true
      renderer.updateEnvironment(environment, deltaTime: dt, player: player.position,
        frame: coordinateFrame, trackedPosition: trackedPosition,
        trackedForward: -SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z))
    }
    if journey.phase != previous {
      audio.setSpace(inSpace); hands.configure(parent: headAnchor, lighting: lighting)
      if inSpace { renderer.suspendLife() }
    }
    // Also select the correct ambience when restoring a cruise checkpoint.
    if previous == .cruise { audio.setSpace(inSpace) }
    underwaterOverlay.isEnabled = false; biteOverlay.isEnabled = false
    cloudOverlay.isEnabled = !inSpace && renderer.atmosphere.cloudDensity > 0.01
    cloudOverlay.components.set(OpacityComponent(opacity: renderer.atmosphere.cloudDensity))
    hands.update(deltaTime: dt, movement: 0, visible: showHands && !thirdPerson && active)
    renderer.showSelection(nil); targetName = ""
    let message: String
    switch journey.phase {
    case .countdown:
      message = rockets.doorOpen > 0.001 ? "Sealing airlock…" : "Launch in \(max(1, 3 - Int(journey.elapsed))) · \(destinationName)"
    case .ascent: message = "Climbing through the atmosphere · \(destinationName)"
    case .cruise: message = journey.elapsed >= journey.phase.duration ? "Holding in orbit · Preparing landing pad" : "Cruising to \(destinationName)"
    case .descent: message = "Landing at \(journey.destination.town) · \(destinationName)"
    case .landed: message = "Welcome to \(destinationName)! Airlock opening."
    }
    if rocketStatus != message { rocketStatus = message }
    rockets.setDisplay("\(destinationName.uppercased())\n\(journey.phase.rawValue.uppercased())")
    if navigation != rocketStatus { navigation = rocketStatus }
    if journey.phase == .landed && terrainReady && renderer.settlementLife.welcomeReady {
      renderer.settlementLife.celebrateRocketArrival(planet: destinationName, time: environment.elapsed)
      rockets.openAfterLanding(); rockets.celebrate()
      rocketJourney = nil; player.flying = false; player.grounded = true
      rocketRegion = .init(floorDivide(journey.destination.x, by: SettlementGenerator.regionSize),
        floorDivide(journey.destination.z, by: SettlementGenerator.regionSize))
      destinationIndex = (planetIndex + 1) % solarSystem.planets.count
      lastStepPosition = player.position; doubleJump.reset(); input.reset()
      scheduleSave()
    } else if now - lastSaveTime > 5 || journey.phase != previous {
      lastSaveTime = now; scheduleSave()
    }
    refreshHUD(now: now)
  }
}
