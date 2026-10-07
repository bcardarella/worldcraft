import QuartzCore
import RealityKit
import UIKit
import WorldCore

/// Scene-only presentation. All needs, jobs, pathfinding, social decisions and
/// provider work live on SimulationActor and arrive as completed value snapshots.
@MainActor final class SettlementLife {
  private struct Person {
    let rig: ActorRig
    var root: Entity { rig.root }
    let head: Entity
    let arms: [Entity]
    let legs: [Entity]
    var state: ResidentState
  }
  private let presentation: LifePresentation
  let homesteads: HomesteadLife
  private var residents: [Person] = []
  private var latestTime: Double = 0
  private var appliedRevision: UInt64?
  private var selectedResident: UInt64?
  private var conversationUntil: Double = 0
  private var localConversation = ""
  private(set) var prompt = ""
  init(presentation: LifePresentation) {
    self.presentation = presentation; homesteads = HomesteadLife(presentation)
  }
  var currentSite: Settlement? { presentation.view.site }
  var settlementName: String { currentSite?.name ?? "" }
  var count: Int { residents.count }
  var positions: [SIMD3<Float>] { presentation.view.residentPositions }
  var soundSources: [(String,SIMD3<Float>)] {
    residents.compactMap { person in
      if celebratingArrival { return ("npc_cheer",person.root.position+[0,2.8,0]) }
      if !person.state.moving && [.work,.gather,.craft,.repair].contains(person.state.activity) {
        return ("npc_work",person.root.position+[0,2,0])
      }
      if !person.state.moving && [.socialize,.greet,.help].contains(person.state.activity) {
        return ("npc_talk",person.root.position+[0,2.8,0])
      }
      return nil
    }
  }
  var records: [ResidentRecord] { presentation.view.residentRecords }
  var conversation: String { latestTime < conversationUntil ? localConversation : presentation.view.conversation }
  var decisionStatus: String { presentation.view.decisionStatus }
  var decisionLatencyMilliseconds: Double { presentation.view.decisionLatencyMilliseconds }
  var acceptedDecisions: Int { presentation.view.acceptedDecisions }
  var rejectedDecisions: Int { presentation.view.rejectedDecisions }
  var logsDecisions: Bool { get { presentation.logs } set { presentation.logs = newValue } }
  var welcomeReady: Bool { presentation.view.welcomeReady && residents.count >= 8 }
  var celebratingArrival: Bool { presentation.view.celebrating }
  func restore(_ records: [ResidentRecord], homes: [HomeRecord] = []) {
    presentation.view.residentRecords = records; presentation.view.homes = homes
    presentation.send?(.restoreResidents(records, homes))
  }
  func configureJev(key: String?, enabled: Bool) { presentation.send?(.jev(key, enabled)) }
  func prepareRocketWelcome(port: RocketPort, terrain: TerrainGenerator, time: Double) -> Bool {
    presentation.send?(.welcome(port, terrain, time)); return true
  }
  func celebrateRocketArrival(planet: String, time: Double) { presentation.send?(.celebrate(planet, time)) }
  func update(terrain: TerrainGenerator, player: SIMD3<Float>, deltaTime: Float,
    environment: WorldEnvironment, threats: [SIMD3<Float>], root: Entity,
    loaded: Set<ChunkCoordinate>, block: (BlockPosition) -> Block) {
    latestTime = environment.elapsed
    if appliedRevision != presentation.revision {
      appliedRevision = presentation.revision
      let states = Dictionary(uniqueKeysWithValues: presentation.view.residents.map { ($0.id, $0) })
      for person in residents where states[person.state.id] == nil { person.root.removeFromParent() }
      residents.removeAll { states[$0.state.id] == nil }
      for i in residents.indices { if let state = states[residents[i].state.id] { residents[i].state = state } }
    }
    let visible = Set(residents.map { $0.state.id })
    // One GPU rig upload per frame, independent of simulation completion bursts.
    if let state = presentation.view.residents.first(where: { !visible.contains($0.id) }), let person = makePerson(state: state) {
      root.addChild(person.root); residents.append(person)
    }
    for i in residents.indices {
      let person = residents[i]
      let enabled = loaded.contains(BlockPosition(person.state.position).chunk)
        && simd_distance_squared(person.state.position, player) < 110 * 110
      if person.root.isEnabled != enabled { person.root.isEnabled = enabled }
      guard enabled else { continue }
      // Simulation stays at 15 Hz; interpolate visible actors at headset cadence.
      person.root.position += (person.state.position - person.root.position) * min(1, deltaTime * 22)
      person.root.orientation = simd_slerp(person.root.orientation,
        simd_quatf(angle: person.state.heading, axis: [0, 1, 0]), min(1, deltaTime * 22))
      guard person.rig.updateDetail(distanceSquared: simd_distance_squared(person.state.position, player)) else { continue }
      let speaking = (!person.state.moving && person.state.activity == .socialize)
        || (selectedResident == person.state.id && latestTime < conversationUntil)
      person.rig.face(time: latestTime, id: person.state.id,
        asleep: person.state.activity == .rest && !person.state.moving, talking: speaking)
      let moving = person.state.moving
      let aquatic = person.state.habitat == .aquatic
      let phase = Float(environment.elapsed.truncatingRemainder(dividingBy: 1_000))
      let cheering = celebratingArrival && i < 8 && person.state.activity != .flee
      if cheering { person.root.position.y = person.state.position.y + max(0, sin(phase * 4 + Float(i))) * 0.28 }
      for (j, leg) in person.legs.enumerated() {
        leg.orientation = simd_quatf(angle: aquatic ? sin(person.state.gait + Float(j) * .pi) * 0.24 - 0.35 : moving ? sin(person.state.gait + Float(j) * .pi) * 0.38 : 0, axis: [1, 0, 0])
      }
      for (j, arm) in person.arms.enumerated() {
        var angle: Float = moving ? -sin(person.state.gait + Float(j) * .pi) * 0.3 : 0
        if !moving && [.work, .gather, .craft, .repair, .defend].contains(person.state.activity) { angle = -0.7 + sin(phase * 3) * 0.28 }
        if !moving && [.socialize, .greet, .help].contains(person.state.activity) && j == 1 { angle = -0.8 + sin(phase * 2) * 0.2 }
        if person.state.activity == .eat && !moving { angle = -1.1 }
        if aquatic { angle = -0.55 + sin(phase * 1.8 + Float(j) * .pi) * (moving ? 0.6 : 0.2) }
        if cheering { angle = -2.5 + sin(phase * 6 + Float(i + j)) * 0.35 }
        arm.orientation = simd_quatf(angle: angle, axis: [1, 0, 0])
          * simd_quatf(angle: aquatic ? (j == 0 ? -0.3 : 0.3) : 0, axis: [0, 0, 1])
      }
      let glance = player - person.state.position
      let relative = atan2(-glance.x, -glance.z) - person.state.heading
      let headTurn = simd_length_squared(glance) < 64 ? max(-0.6, min(0.6, atan2(sin(relative), cos(relative)))) : 0
      person.head.orientation = simd_quatf(angle: headTurn, axis: [0, 1, 0])
        * simd_quatf(angle: person.state.activity == .rest && !moving ? 0.3 : 0, axis: [1, 0, 0])
    }
  }

  func focus(eye: SIMD3<Float>, direction: SIMD3<Float>, interact: Bool, terrain: TerrainGenerator,
    block: (BlockPosition) -> Block) {
    guard let site = currentSite else { prompt = ""; return }
    let forward = simd_normalize(direction)
    let found = residents.indices.filter { i in
      let delta = residents[i].state.position + [0, 2.5, 0] - eye
      let distance = simd_length(delta)
      return residents[i].root.isEnabled && distance < 7 && distance > 0.001 && simd_dot(delta / distance, forward) > 0.88
        && VoxelRaycast.cast(origin: eye, direction: delta, reach: distance - 0.4, block: block) == nil
    }.min { simd_distance_squared(residents[$0].state.position, eye) < simd_distance_squared(residents[$1].state.position, eye) }
    guard let i = found else { prompt = ""; selectedResident = nil; return }
    selectedResident = residents[i].state.id
    prompt = "\(residents[i].state.name) · \(residents[i].state.roleName) · R / LT to talk"
    guard interact else { return }
    let state = residents[i].state
    localConversation = "\(state.name): " + state.line(settlement: site.name, biome: site.setting,
      familiar: state.record.playerConversations > 0)
    conversationUntil = latestTime + 7
    presentation.send?(.talk(state.id))
  }
  func witnessedEdit(at point: BlockPosition, old: Block, new: Block, terrain: TerrainGenerator) {
    presentation.send?(.edited(point, old, new, terrain, latestTime))
  }
  private func makePerson(state: ResidentState) -> Person? {
    let look = ResidentAppearance(id: state.id, role: state.role, habitat: state.habitat)
    guard let geometry = ActorModelLibrary.shared.geometry(for: .resident(look)) else { return nil }
    let rig = ActorRig(geometry, library: .shared)
    rig.root.position = state.position
    rig.root.orientation = simd_quatf(angle: state.heading, axis: [0, 1, 0])
    return .init(rig: rig, head: rig[.head], arms: [rig[.limb0], rig[.limb1]], legs: [rig[.limb2], rig[.limb3]], state: state)
  }
  func clear() {
    residents.forEach { $0.root.removeFromParent() }; residents.removeAll()
    appliedRevision = nil
    prompt = ""; localConversation = ""; selectedResident = nil; conversationUntil = 0
  }
}
