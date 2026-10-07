import AVFAudio
import RealityKit
import WorldCore

@MainActor final class WorldAudio {
  private struct Loop {
    let entity: Entity
    let controller: AudioPlaybackController
    let event: String
    let gain: Double
    var activity: Float = 0
  }
  private struct OneShot {
    let entity: Entity
    let controller: AudioPlaybackController
    let gain: Double
  }
  private var library: AudioLibrary?
  private var assets: [String: [SoundEffectAsset]] = [:]
  private var resources: [String: AudioFileResource] = [:]
  private var resourceTask: Task<Void, Never>?
  private var liquidAmbience: (position: SIMD3<Float>, event: String)?
  private let soundtrack = SoundtrackPlayer()
  private var musicSession = UUID()
  private var musicStarted = false
  private var loops: [String: Loop] = [:]
  private var transients: [UInt64: OneShot] = [:]
  private var spareEntities: [Entity] = []
  private var budget = SoundVoiceBudget()
  private var lastVariant: [String: Int] = [:]
  private var lifecycle = 0
  private var ambienceRequest = 0
  private var lastEnvironmentUpdate = -Double.infinity
  private var lastThunder = -Double.infinity
  private var inSpace = false
  private var paused = false
  private var interrupted = false
  private var interruptionObserver: NSObjectProtocol?
  private var terrain = TerrainGenerator(seed: 0)
  private weak var root: Entity?
  private var player = SIMD3<Float>.zero
  private var mood: MusicMood = .meadow
  private var ducked = false
  var effectsVolume: Float = 0.8 {
    didSet {
      guard effectsVolume != oldValue else { return }
      for shot in transients.values { shot.entity.spatialAudio?.gain = shot.gain + decibels(effectsVolume) }
    }
  }
  var musicVolume: Float = 0.45 {
    didSet {
      guard musicVolume != oldValue else { return }
      let mood = mood, volume = musicVolume, ducked = ducked
      Task { await soundtrack.update(mood: mood, volume: volume, ducked: ducked) }
    }
  }

  func start(root: Entity, generator: TerrainGenerator, player: SIMD3<Float>) async throws {
    clearScene()
    self.root = root; terrain = generator; self.player = player; inSpace = false
    let lifetime = lifecycle
    try await AudioSessionActivator.shared.activate()
    guard !Task.isCancelled, lifecycle == lifetime else { return }
    if library == nil {
      let decoded = try await Task.detached(priority: .utility) {
        guard let url = Bundle.main.url(forResource: "AudioLibrary", withExtension: "json") else {
          throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(AudioLibrary.self, from: Data(contentsOf: url))
      }.value
      guard !Task.isCancelled, lifecycle == lifetime else { return }
      library = decoded
      assets = Dictionary(grouping: decoded.effects, by: \.event)
    }
    guard let library else { return }
    prepareEffects(library.effects, lifetime: lifetime)
    if !musicStarted {
      musicStarted = true
      let session = musicSession
      await soundtrack.start(session: session, library: library.tracks, seed: generator.seed, volume: musicVolume)
      guard !Task.isCancelled, lifecycle == lifetime else {
        if musicSession != session { await soundtrack.stop(session: session) }
        return
      }
      await soundtrack.setPaused(paused || interrupted)
    }
    guard !Task.isCancelled, lifecycle == lifetime else { return }
    if interruptionObserver == nil {
      interruptionObserver = NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
          let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
          Task { @MainActor [weak self] in
            guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            self.interrupted = type == .began
            if type == .ended { try? await AudioSessionActivator.shared.activate() }
            self.applyPause()
          }
        }
    }
    updateAmbience(root: root, generator: generator, player: player)
  }

  private func prepareEffects(_ effects: [SoundEffectAsset], lifetime: Int) {
    resourceTask?.cancel()
    let plan = SoundPreloadPlan.ordered(effects).filter { resources[$0.file] == nil }
    resourceTask = Task(priority: .utility) { [weak self] in
      var missing = 0
      for asset in plan {
        guard !Task.isCancelled, self?.lifecycle == lifetime else { return }
        do {
          let resource = try await AudioFileResource(named: asset.file,
            configuration: .init(loadingStrategy: asset.loop ? .stream : .preload,
              shouldLoop: asset.loop, shouldRandomizeStartTime: asset.loop))
          guard !Task.isCancelled, let self, self.lifecycle == lifetime else { return }
          self.resources[asset.file] = resource
        } catch is CancellationError { return }
        catch { missing += 1 }
        // Limit resource preparation traffic and leave time for terrain, input
        // and tracking. Never sleep or wait in the frame callback.
        do { try await Task.sleep(for: SoundPreloadPlan.interval) } catch { return }
      }
      guard let self, !Task.isCancelled, self.lifecycle == lifetime else { return }
      self.resourceTask = nil
      print("WORLDCRAFT_AUDIO effects_ready=\(self.resources.count) missing_effect_files=\(missing)")
    }
  }

  func updateAmbience(root: Entity, generator: TerrainGenerator, player: SIMD3<Float>) {
    self.root = root; terrain = generator; self.player = player
    ambienceRequest += 1
    let request = ambienceRequest, epoch = lifecycle
    // Only geography moves to this utility task. RealityKit objects remain on
    // MainActor, and no frame waits for the survey or an audio file.
    Task { [weak self] in
      let closest = await Task.detached(priority: .utility) { () -> (SIMD3<Float>, String)? in
        let cx = Int(floor(player.x)), cz = Int(floor(player.z))
        var found: (SIMD3<Float>, String)?
        var distance = Int.max
        for dx in stride(from: -32, through: 32, by: 8) {
          for dz in stride(from: -32, through: 32, by: 8) {
            guard dx*dx+dz*dz < distance,
              let body = generator.waterBody(atX: cx+dx, z: cz+dz) else { continue }
            distance = dx*dx+dz*dz
            found = ([Float(cx+dx), body.level, Float(cz+dz)],
              body.kind == .lava ? "lava" : body.kind == .river ? "river" : body.kind == .ocean ? "ocean" : "lake")
          }
        }
        return found
      }.value
      guard let self, epoch == self.lifecycle, request == self.ambienceRequest else { return }
      self.liquidAmbience = closest.map { (position: $0.0, event: $0.1) }
      if let closest { self.loop("liquid", event: closest.1, at: closest.0, activity: 1) }
      else { self.retireLoop("liquid") }
    }
  }

  func updateEnvironment(_ environment: WorldEnvironment, player: SIMD3<Float>,
    mood: MusicMood, submerged: Bool = false, underground: Bool = false, town: Bool = false,
    ducked: Bool = false, vehicles: [VehicleSoundState] = [], fires: [SIMD3<Float>] = []) {
    self.player = player; self.mood = inSpace ? .space : mood; self.ducked = ducked
    guard environment.elapsed-lastEnvironmentUpdate >= 0.1 else { return }
    lastEnvironmentUpdate = environment.elapsed
    let musicMood = self.mood, volume = musicVolume
    Task { await soundtrack.update(mood: musicMood, volume: volume, ducked: ducked) }
    guard !paused, !interrupted, !inSpace else { return }
    let weather = WorldWeather.sample(seed: terrain.seed, time: environment.elapsed, style: terrain.style)
    let wind = WorldWind.sample(seed: terrain.seed, time: environment.elapsed, position: player, weather: weather)
    let exterior: Float = submerged || underground ? 0 : 1
    let greenery: Float = terrain.style == .solar || terrain.style == .ember ? 0 : exterior
    loop("birds", event: "birds", at: player+[15,9,-11], activity: environment.daylight*greenery)
    loop("crickets", event: "crickets", at: player+[-14,1,13], activity: (1-environment.daylight)*greenery)
    let direction = wind.velocity / max(1, wind.speed)
    loop("wind", event: "wind", at: player-direction*12+[0,5,0], activity: min(1,wind.speed/13)*exterior)
    loop("rain", event: "rain", at: player+[0,8,0], activity: weather.precipitation*exterior)
    loop("underwater", event: "underwater", at: player+[0,1,0], activity: submerged ? 1 : 0)
    loop("cave", event: "cave", at: player+[6,1,-8], activity: underground && !submerged ? 1 : 0)
    loop("town", event: "town", at: player+[12,2,7], activity: town && !underground && !submerged ? 0.65 : 0)
    if let liquid = liquidAmbience {
      loop("liquid", event: liquid.event, at: liquid.position,
        activity: submerged ? 0.2 : underground ? 0 : 1)
    }
    if weather.storminess > 0.7 && environment.elapsed-lastThunder > 24 {
      lastThunder = environment.elapsed
      if let root {
        play("thunder", at: player+[80,55,-95], root: root,
          time: ProcessInfo.processInfo.systemUptime, level: -4)
      }
    }
    if let fire=fires.min(by:{ simd_distance_squared($0,player)<simd_distance_squared($1,player) }),
      simd_distance_squared(fire,player)<32*32 {
      loop("fire",event:"fire",at:fire,activity:submerged ? 0:1)
    } else { retireLoop("fire") }
    let nearest = vehicles.sorted { simd_distance_squared($0.position,player) < simd_distance_squared($1.position,player) }.prefix(3)
    var active = Set<String>()
    for car in nearest where simd_distance_squared(car.position,player) < 100*100 && (car.occupied || car.speed > 0.4) {
      let key = "car_\(car.id)"; active.insert(key)
      loop(key, event: car.racing ? "race_engine" : "car_engine", at: car.position+[0,0.8,-1],
        activity: min(1,0.32+car.speed/35), speed: Double(0.7+min(1.2,car.speed/32)))
    }
    for key in Array(loops.keys) where key.hasPrefix("car_") && !active.contains(key) { retireLoop(key) }
  }

  private func loop(_ key: String, event: String, at position: SIMD3<Float>, activity: Float, speed: Double = 1) {
    if loops[key]?.event != event { retireLoop(key) }
    if loops[key] == nil {
      guard loops.count < 14, let asset = assets[event]?.first, let resource = resources[asset.file],
        let root else { return }
      let entity = Entity(); entity.position = position
      entity.spatialAudio = .init(gain: -.infinity, reverbLevel: -.infinity)
      root.addChild(entity)
      let controller = entity.prepareAudio(resource)
      loops[key] = .init(entity: entity, controller: controller, event: event, gain: asset.gain)
    }
    guard var source = loops[key] else { return }
    if source.entity.position != position { source.entity.position = position }
    source.activity += (max(0,activity)-source.activity)*0.28
    if abs(source.controller.speed-speed) > 0.01 { source.controller.speed = speed }
    loops[key] = source
    mixLoop(key)
  }
  private func mixLoop(_ key: String) {
    guard let source = loops[key] else { return }
    let audible = !paused && !interrupted && !inSpace && source.activity*effectsVolume > 0.002
    let gain = source.gain+decibels(source.activity*effectsVolume)
    if let old = source.entity.spatialAudio?.gain, old != gain,
      !old.isFinite || !gain.isFinite || abs(old-gain) > 0.05 {
      source.entity.spatialAudio?.gain = gain
    }
    if audible && !source.controller.isPlaying { source.controller.play() }
    else if !audible && source.controller.isPlaying { source.controller.pause() }
  }
  private func retireLoop(_ key: String) {
    guard let source = loops.removeValue(forKey: key) else { return }
    source.controller.stop(); source.entity.stopAllAudio(); source.entity.removeFromParent()
  }

  func play(_ event: String, at position: SIMD3<Float>, root: Entity, time: Double, level: Float = 0) {
    guard effectsVolume > 0, !interrupted else { return }
    if paused && !event.hasPrefix("inventory") && event != "hotbar" { return }
    let aliases = ["break":"break_stone","place":"place_stone","water":"ocean"]
    let name = aliases[event] ?? event
    // A ready take stays playable while the remaining recordings load.
    guard let choices = assets[name]?.filter({ resources[$0.file] != nil }), !choices.isEmpty else { return }
    var index = Int.random(in: choices.indices)
    if choices.count > 1 && index == lastVariant[name] { index = (index+1)%choices.count }
    let asset = choices[index]
    guard let resource = resources[asset.file] else { return }
    tick(time: time)
    let speed = name.contains("engine") || name == "thunder" ? 1 : Double.random(in: 0.96...1.04)
    let priority = name.hasPrefix("step") || name.hasPrefix("npc") ? 0 : 1
    guard let admitted = budget.admit(event: name, time: time, duration: asset.duration/speed, priority: priority) else { return }
    if let replaced = admitted.replaced { retire(replaced) }
    lastVariant[name] = index
    let source = spareEntities.popLast() ?? Entity()
    source.position = position
    let gain = asset.gain + Double(level)
    source.spatialAudio = .init(gain: gain+decibels(effectsVolume),
      reverbLevel: mood == .cave || mood == .castle ? -10 : -.infinity, directivity: .beam(focus: 0))
    root.addChild(source)
    let controller = source.playAudio(resource); controller.speed = speed
    transients[admitted.id] = .init(entity: source, controller: controller, gain: gain)
  }
  func tick(time: Double) {
    for id in budget.expire(at: time) { retire(id) }
  }
  private func retire(_ id: UInt64) {
    guard let source = transients.removeValue(forKey: id) else { return }
    source.controller.stop(); source.entity.stopAllAudio(); source.entity.removeFromParent()
    if spareEntities.count < SoundVoiceBudget.limit { spareEntities.append(source.entity) }
  }
  func setPaused(_ value: Bool) { paused = value; applyPause() }
  private func applyPause() {
    let value = paused || interrupted
    Task { await soundtrack.setPaused(value) }
    for key in loops.keys { mixLoop(key) }
    if value { for id in Array(transients.keys) { retire(id) }; budget.clear() }
  }
  func setSpace(_ space: Bool) {
    guard inSpace != space else { return }
    inSpace = space
    if space { mood = .space }
    for key in loops.keys { mixLoop(key) }
    let mood = mood, volume = musicVolume
    Task { await soundtrack.update(mood: mood, volume: volume, ducked: false) }
  }
  private func clearScene() {
    lifecycle += 1; ambienceRequest += 1; lastEnvironmentUpdate = -.infinity; lastThunder = -.infinity
    resourceTask?.cancel(); resourceTask = nil; liquidAmbience = nil
    for key in Array(loops.keys) { retireLoop(key) }
    for id in Array(transients.keys) { retire(id) }
    budget.clear()
  }
  func stop() {
    clearScene()
    let oldSession = musicSession
    musicSession = UUID(); musicStarted = false
    Task { await soundtrack.stop(session: oldSession) }
    if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    interruptionObserver = nil; interrupted = false
    resources.removeAll(); spareEntities.removeAll(); root = nil
  }
  private func decibels(_ volume: Float) -> Double {
    volume <= 0 ? -.infinity : 20*log10(Double(volume))
  }
}
/// Session negotiation can block on a system service. Keep it off the UI
/// executor, including on older visionOS versions without asynchronous activation.
private actor AudioSessionActivator {
  static let shared = AudioSessionActivator()

  func activate() async throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    if #available(visionOS 27.0, iOS 27.0, *) {
      guard try await session.activate(options: []) else {
        throw NSError(domain: "Worldcraft.Audio", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "The audio session could not be activated."])
      }
    } else {
      try session.setActive(true)
    }
  }
}
