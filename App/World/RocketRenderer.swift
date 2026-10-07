import RealityKit
import UIKit
import WorldCore

/// One detailed ship near the player. Ports are much farther apart than a
/// settlement, so distant pads need no ticking actors or individual voxel nodes.
@MainActor
final class RocketRenderer {
  enum Control { case door, previous, next, launch }
  let root = Entity()
  private let ship = Entity()
  private let door = Entity()
  private let exhaust = Entity()
  private let engine = Entity()
  private let exhaustSmoke = Entity()
  private let groundSmoke = Entity()
  private var emissionState: String = ""
  private let effects = Entity()
  private let display = Entity()
  private var displayText = ""
  private var resources: [String: AudioFileResource] = [:]
  private var enginePlaying = false
  private var audioEpoch = UUID()
  private var built = false
  private weak var currentLighting: Entity?
  private(set) var port: RocketPort?
  private(set) var doorOpen: Float = 0
  private var doorTarget: Float = 0
  private(set) var focused: Control?
  var prompt: String {
    switch focused {
    case .door: "R / LT · \(doorTarget > 0 ? "Close" : "Open") airlock"
    case .previous: "R / LT · Previous planet"
    case .next: "R / LT · Next planet"
    case .launch: "R / LT · Launch to selected planet"
    case nil: ""
    }
  }
  var position: SIMD3<Float> { ship.position }
  func isInside(_ feet: SIMD3<Float>) -> Bool { port != nil && RocketCabin.contains(feet - position) }
  func obstructs(_ feet: SIMD3<Float>) -> Bool {
    guard port != nil else { return false }
    let local = feet - position
    guard abs(local.x) < 6 && abs(local.z) < 6 && (-4...19).contains(local.y) else { return false }
    return RocketCabin.obstructs(local, doorOpen: doorOpen)
  }
  func obstructsCamera(_ point: SIMD3<Float>, radius: Float, shipPosition: SIMD3<Float>? = nil) -> Bool {
    guard port != nil else { return false }
    let local = point - (shipPosition ?? position)
    guard abs(local.x) < 7 && abs(local.z) < 7 && (-1...16).contains(local.y) else { return false }
    return RocketCabin.walls.contains { $0.overlaps(center: local, radius: radius) }
      || RocketCabin.nose.contains { $0.overlaps(center: local, radius: radius) }
      || RocketCabin.fins.contains { $0.overlaps(center: local, radius: radius) }
      || (doorOpen < 0.98 && RocketCabin.door.overlaps(center: local, radius: radius))
  }
  func setPort(_ port: RocketPort?, lighting: Entity) {
    if !built { build(); built = true }
    if self.port != port { doorOpen = 0; doorTarget = 0; focused = nil }
    self.port = port
    if let port { ship.position = port.center }
    root.isEnabled = port != nil
    setLighting(lighting)
  }
  func place(at position: SIMD3<Float>, frame: PlayerFrame, lighting: Entity) {
    ship.position = position
    transform(frame)
    setLighting(lighting)
  }
  private func setLighting(_ lighting: Entity) {
    guard currentLighting !== lighting else { return }
    currentLighting = lighting
    root.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lighting))
  }
  func transform(_ frame: PlayerFrame) {
    guard root.orientation.vector != frame.trackingFromWorldRotation.vector || root.position != frame.worldOriginInTracking else { return }
    root.transform = .init(scale: .init(repeating: WorldScale.metresPerBlock),
      rotation: frame.trackingFromWorldRotation, translation: frame.worldOriginInTracking)
  }
  func openAfterLanding() { doorTarget = 1; focused = nil; play("rocket_door") }
  func closeForLaunch() { doorTarget = 0; focused = nil; play("rocket_door") }
  func toggleDoor(player: SIMD3<Float>) {
    // A body in the aperture holds the door open; never pinch or trap the player.
    if doorTarget > 0 && RocketCabin.inDoorway(player - position) { return }
    doorTarget = doorTarget > 0 ? 0 : 1
    play("rocket_door")
  }
  func focus(eye: SIMD3<Float>, direction: SIMD3<Float>, feet: SIMD3<Float>,
    block: (BlockPosition) -> Block) {
    focused = nil
    guard port != nil, simd_length_squared(direction) > 0.001 else { return }
    let inside = isInside(feet)
    let panel = inside ? RocketCabin.innerDoorPanel : RocketCabin.outerDoorPanel
    let candidates: [(Control, SIMD3<Float>)] = inside ? [(.door, panel), (.previous, RocketCabin.previousPlanet), (.next, RocketCabin.nextPlanet), (.launch, RocketCabin.button)] : [(.door, panel)]
    var best: Float = 0.83
    for (control, local) in candidates {
      // The outer door is only operable from in front of the ship, not through a window.
      if !inside && eye.z < position.z + 4 { continue }
      let d = position + local - eye, distance = simd_length(d)
      guard distance > 0.01 && distance < 7 else { continue }
      let aim = simd_dot(d / distance, simd_normalize(direction))
      if aim > best && VoxelRaycast.cast(origin: eye, direction: d, reach: max(0, distance - 0.5), block: block) == nil {
        best = aim; focused = control
      }
    }
  }
  func update(deltaTime: Float, player: SIMD3<Float>, phase: RocketPhase?, clock: Double,
    paused: Bool, effectsVolume: Float) {
    if phase == nil && RocketCabin.inDoorway(player - position) { doorTarget = 1 }
    let dt = paused ? 0 : max(0, min(0.05, deltaTime))
    doorOpen += min(abs(doorTarget - doorOpen), dt * 1.4) * (doorTarget >= doorOpen ? 1 : -1)
    let slide = doorOpen * 3.4
    if door.position.x != slide { door.position.x = slide }
    let powered = phase == .ascent || phase == .cruise || phase == .descent
    let atmospheric = phase == .ascent || phase == .descent
    let low = atmospheric && abs(position.y - (port?.center.y ?? position.y)) < 24
    let emission = "\(powered)-\(atmospheric)-\(low)-\(paused)"
    if emission != emissionState {
      emissionState = emission
      for (entity, active) in [(exhaust, powered), (exhaustSmoke, atmospheric), (groundSmoke, low)] {
        if var emitter = entity.components[ParticleEmitterComponent.self] {
          emitter.isEmitting = active && !paused
          emitter.simulationState = paused ? .pause : .play
          entity.components.set(emitter)
        }
      }
    }
    // This plume remains on the pad as the engine climbs away.
    if let port { groundSmoke.position = port.center + [0, 0.3, 0] }
    let audible = powered && !paused && effectsVolume > 0
    engine.spatialAudio?.gain = -24 + 20 * log10(Double(max(0.0001, effectsVolume)))
    effects.spatialAudio?.gain = -14 + 20 * log10(Double(max(0.0001, effectsVolume)))
    if audible != enginePlaying {
      enginePlaying = audible
      if audible, let resource = resources["rocket_engine"] { engine.playAudio(resource) }
      else { engine.stopAllAudio() }
    }
    if paused { effects.stopAllAudio() }
  }
  func setDisplay(_ text: String) {
    guard text != displayText else { return }
    displayText = text; display.children.removeAll()
    let lines = text.split(separator: "\n").map(String.init)
    addLabel("WORLDCRAFT  /  FLIGHT COMPUTER", at: [0,4.35,-3.33], size: [2.65,0.16], color: .init(red:0.32,green:0.68,blue:0.49,alpha:1), parent:display)
    addLabel(lines.first ?? "SELECT PLANET", at: [0,3.87,-3.32], size: [2.7,0.38], parent:display)
    addLabel(lines.dropFirst().joined(separator:"  "), at: [0,3.35,-3.32], size: [2.65,0.22], parent:display)
  }
  private func addLabel(_ text: String, at center: SIMD3<Float>, size: SIMD2<Float>,
    color: UIColor = .init(red:0.55,green:1,blue:0.7,alpha:1), parent: Entity) {
    guard !text.isEmpty else { return }
    let mesh = MeshResource.generateText(text,extrusionDepth:0.001,
      font:.monospacedSystemFont(ofSize:1,weight:.bold))
    let label = ModelEntity(mesh:mesh,materials:[UnlitMaterial(color:color)])
    let bounds = mesh.bounds
    let scale = min(size.x/max(0.001,bounds.extents.x),size.y/max(0.001,bounds.extents.y))
    label.scale = .init(repeating:scale)
    label.position = center - SIMD3<Float>(bounds.center.x*scale,bounds.center.y*scale,0)
    parent.addChild(label)
  }
  func prepareAudio() async {
    let epoch = audioEpoch
    for name in ["rocket_engine", "rocket_door", "rocket_arrival"] {
      guard !Task.isCancelled, epoch == audioEpoch else { return }
      guard resources[name] == nil else { continue }
      do {
        let sound = try await AudioFileResource(named: "fx_\(name)_01.wav", configuration: .init(shouldLoop: name == "rocket_engine"))
        guard !Task.isCancelled, epoch == audioEpoch else { return }
        resources[name] = sound
      } catch { /* A missing optional effect must not prevent boarding or travel. */ }
    }
  }
  func celebrate() { play("rocket_arrival") }
  private func play(_ name: String) {
    effects.position = name == "rocket_arrival" ? [6, 2, 0] : [0, 2.8, 4]
    if let resource = resources[name] { effects.playAudio(resource) }
  }
  func clear() {
    audioEpoch = UUID(); engine.stopAllAudio(); effects.stopAllAudio(); enginePlaying = false
    emissionState = ""; port = nil; root.isEnabled = false; focused = nil; doorOpen = 0; doorTarget = 0; displayText = ""
  }

  private func configureExhaust() {
    var jet = ParticleEmitterComponent()
    jet.emitterShape = .sphere; jet.emitterShapeSize = [0.85,0.15,0.85]
    jet.birthDirection = .local; jet.emissionDirection = [0,-1,0]
    jet.speed = 14; jet.speedVariation = 3
    jet.mainEmitter.birthRate = 140; jet.mainEmitter.lifeSpan = 0.45
    jet.mainEmitter.size = 1.1; jet.mainEmitter.sizeVariation = 0.4
    jet.mainEmitter.sizeMultiplierAtEndOfLifespan = 0.25
    jet.mainEmitter.stretchFactor = 3; jet.mainEmitter.noiseStrength = 0.6
    jet.mainEmitter.opacityCurve = .quickFadeInOut; jet.mainEmitter.blendMode = .additive
    jet.mainEmitter.isLightingEnabled = false
    jet.mainEmitter.color = .evolving(start:.random(a:.init(red:0.65,green:0.85,blue:1,alpha:1),b:.white),
      end:.single(.init(red:1,green:0.32,blue:0.02,alpha:0)))
    jet.isEmitting = false
    exhaust.position = [0,-0.4,0]; exhaust.components.set(jet); ship.addChild(exhaust)
    var smoke = jet
    smoke.speed = 6; smoke.speedVariation = 2
    smoke.mainEmitter.birthRate = 30; smoke.mainEmitter.lifeSpan = 3.2
    smoke.mainEmitter.size = 1.8; smoke.mainEmitter.sizeMultiplierAtEndOfLifespan = 4
    smoke.mainEmitter.stretchFactor = 1; smoke.mainEmitter.noiseStrength = 0.8
    smoke.mainEmitter.acceleration = [0,1,0]; smoke.mainEmitter.dampingFactor = 0.3
    smoke.mainEmitter.blendMode = .alpha; smoke.mainEmitter.opacityCurve = .gradualFadeInOut
    smoke.mainEmitter.color = .evolving(start:.single(.init(white:0.75,alpha:0.55)),end:.single(.init(white:0.55,alpha:0)))
    exhaustSmoke.position = [0,-1,0]; exhaustSmoke.components.set(smoke); ship.addChild(exhaustSmoke)
    var dust = smoke
    dust.emitterShapeSize = [4,0.25,4]; dust.birthDirection = .normal
    dust.emissionDirection = [0,1,0]; dust.speed = 3; dust.mainEmitter.birthRate = 45
    dust.mainEmitter.lifeSpan = 4; dust.mainEmitter.acceleration = [0,0.4,0]
    groundSmoke.components.set(dust); root.addChild(groundSmoke)
  }

  private func build() {
    root.scale = .init(repeating: WorldScale.metresPerBlock); root.addChild(ship)
    var metal = PhysicallyBasedMaterial()
    metal.baseColor = .init(tint: UIColor(white: 0.88, alpha: 1)); metal.metallic = .init(floatLiteral: 0.6)
    metal.roughness = .init(floatLiteral: 0.28)
    let dark = SimpleMaterial(color: UIColor(white: 0.12, alpha: 1), roughness: 0.6, isMetallic: true)
    let trim = SimpleMaterial(color: UIColor(red: 0.10, green: 0.40, blue: 0.63, alpha: 1), roughness: 0.3, isMetallic: true)
    let glow = UnlitMaterial(color: UIColor(red: 0.45, green: 1, blue: 0.92, alpha: 1))
    var glass = PhysicallyBasedMaterial()
    glass.baseColor = .init(tint: UIColor(red: 0.7, green: 0.9, blue: 1, alpha: 1))
    glass.blending = .transparent(opacity: .init(floatLiteral: 0.08))
    glass.roughness = .init(floatLiteral: 0.08); glass.faceCulling = .none
    let builder = SculptureBuilder(materials: [metal, dark, trim, glow, glass, UnlitMaterial(color: .systemOrange),
      UnlitMaterial(color:.init(red:0.015,green:0.075,blue:0.05,alpha:1)),
      UnlitMaterial(color:.init(red:0.02,green:0.10,blue:0.065,alpha:1))])
    // Window apertures are real holes in the opaque hull, with thin clear panes.
    for x: Float in [-4, 4] {
      builder.box([0.5, 1.7, 8.5], [x, 0.85, 0], 0, parent: ship)
      builder.box([0.5, 1.3, 8.5], [x, 5.85, 0], 0, parent: ship)
      for z: Float in [-3.2, 3.2] { builder.box([0.5, 3.5, 2.1], [x, 3.45, z], 0, parent: ship) }
      builder.box([0.08, 3.5, 4.3], [x, 3.45, 0], 4, parent: ship)
      builder.box([0.7, 0.2, 4.6], [x, 1.7, 0], 2, parent: ship)
      builder.box([0.7, 0.2, 4.6], [x, 5.2, 0], 2, parent: ship)
    }
    for wall in RocketCabin.walls.dropFirst(2) { builder.box(wall.size, wall.center, 0, parent: ship) }
    builder.box([7.5, 0.05, 7.5], [0, 0, 0], 1, parent: ship)
    // A stepped nose, banded tanks and four chunky landing fins.
    for (i, part) in RocketCabin.nose.enumerated() { builder.box(part.size, part.center, i == 1 ? 2 : 0, parent: ship) }
    for part in RocketCabin.fins { builder.box(part.size, part.center, part.size.y > 1 ? 2 : 1, parent: ship) }
    // Recessed CRT, with text IN FRONT of the phosphor screen and bezel.
    // The old glyphs were embedded inside the console's opaque box.
    builder.box([3.7,2.7,0.45],[0,3.45,-3.62],1,parent:ship)
    builder.box([3.12,1.72,0.035],[0,3.88,-3.375],6,parent:ship)
    for row in 0..<32 {
      builder.box([3.02,0.008,0.003],[0,3.10+Float(row)*0.05,-3.353],7,parent:ship)
    }
    for p in [RocketCabin.previousPlanet,RocketCabin.nextPlanet] { builder.box([0.78,0.55,0.18],p,2,parent:ship) }
    builder.box([1.8,0.58,0.18],RocketCabin.button,5,parent:ship)
    addLabel("<",at:RocketCabin.previousPlanet+[0,0,0.10],size:[0.35,0.32],parent:ship)
    addLabel(">",at:RocketCabin.nextPlanet+[0,0,0.10],size:[0.35,0.32],parent:ship)
    addLabel("LAUNCH",at:RocketCabin.button+[0,0,0.10],size:[1.45,0.27],color:.black,parent:ship)
    for p in [RocketCabin.innerDoorPanel, RocketCabin.outerDoorPanel] {
      builder.box([0.65, 0.9, 0.16], p, 2, parent: ship)
      builder.box([0.35, 0.25, 0.2], p, 3, parent: ship)
    }
    for x: Float in [-3.65, 3.65] { builder.box([0.1, 0.1, 6.5], [x, 5.9, 0], 3, parent: ship) }
    ship.addChild(door)
    builder.box(RocketCabin.door.size, RocketCabin.door.center, 2, parent: door)
    builder.box([0.10, 4.5, 0.43], [0, 2.8, 4], 3, parent: door)
    configureExhaust()
    builder.finish()
    ship.addChild(display)
    engine.position = [0, -2, 0]; engine.spatialAudio = .init(gain: -24, reverbLevel: -.infinity)
    effects.position = [0, 2, -3]; effects.spatialAudio = .init(gain: -14, reverbLevel: -.infinity)
    ship.addChild(engine); ship.addChild(effects)
    let cabinLight = PointLight()
    cabinLight.position = [0, 5.8, 0]
    cabinLight.light.color = UIColor(red: 0.67, green: 0.88, blue: 1, alpha: 1)
    cabinLight.light.intensity = 120; cabinLight.light.attenuationRadius = 5
    ship.addChild(cabinLight)
    setDisplay("SELECT PLANET\nLAUNCH")
  }
}
