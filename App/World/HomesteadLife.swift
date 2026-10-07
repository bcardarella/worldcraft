import Foundation
import WorldCore
import simd

@SimulationActor final class HomesteadSimulation {
  struct Source: Sendable { let point: BlockPosition; let material: Block }
  private(set) var properties: [OwnedHome] = []
  private var saved: [UInt64: HomeRecord] = [:]
  private var sources: [Source] = []
  private var survey: Task<Void, Never>?
  private var nextSurvey: Double = 0
  private var lifetime = UUID()
  private var pendingPlans: [UInt64: (UUID, AgencyPlan)] = [:]
  private var nextIntervention: Double = 0
  var planner: DeliberationService?
  var playerFlying = false
  var playerDriving = false
  var onEdit: ((BlockPosition, Block, Block) -> Bool)?
  private(set) var interventions: [(String, SIMD3<Float>)] = []
  var records: [HomeRecord] { saved.values.sorted { $0.lastDamage > $1.lastDamage }.prefix(256).map { $0 } }
  func checkpoint() -> @SimulationActor () -> Void {
    let saved = saved, properties = properties, interventions = interventions
    let pendingPlans = pendingPlans, nextIntervention = nextIntervention, lifetime = lifetime, sources = sources
    return {
      if self.lifetime != lifetime {
        // A rejected region change must not publish its resource survey into
        // the restored settlement. Restart that survey on the next accepted step.
        self.survey?.cancel(); self.survey = nil; self.lifetime = UUID()
        self.sources = sources; self.nextSurvey = 0
      }
      self.saved = saved; self.properties = properties; self.interventions = interventions
      self.pendingPlans.merge(pendingPlans) { current, _ in current }
      self.nextIntervention = nextIntervention
    }
  }
  func restore(_ records: [HomeRecord]) {
    clearSite()
    saved = Dictionary(records.filter(\.isValid).prefix(256).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
  }
  func clearSite() {
    survey?.cancel(); survey = nil; properties = []; sources = []; pendingPlans = [:]
    nextSurvey = 0; lifetime = UUID(); interventions = []
  }
  func configure(site: Settlement, terrain: TerrainGenerator) {
    guard properties.first?.site.id != site.id else { return }
    clearSite(); properties = OwnedHome.properties(in: site, terrain: terrain)
    for home in properties where saved[home.id] == nil { saved[home.id] = .init(home: home) }
    if saved.count > 256 { saved = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }) }
  }
  func homePosition(index: Int) -> SIMD3<Float>? {
    guard !properties.isEmpty else { return nil }
    let group = index / properties.count
    let property=properties[index % properties.count]
    let home=property.building.use == .home ? property : properties.filter {$0.building.use == .home}
      .min {simd_distance_squared($0.entrance,property.entrance)<simd_distance_squared($1.entrance,property.entrance)} ?? property
    return home.entrance + [Float(group % 3 - 1) * 1.1, 1, 4 + Float(group / 3) * 1.1]
  }
  func workplace(index:Int,site:Settlement) -> SIMD3<Float>? {
    let role=ResidentRole.allCases[(index+Int(site.id%8))%ResidentRole.allCases.count]
    let use:SettlementLotUse = switch role {
      case .farmer: .grocery;case .baker: .bakery;case .builder: .hardware;case .merchant: .grocery
      case .gardener: .home;case .guard: .office;case .scholar: .school;case .musician: .cafe
    }
    let home=homePosition(index:index) ?? site.center
    return properties.filter {$0.building.use == use && simd_distance_squared($0.entrance,home)<180*180}
      .min {simd_distance_squared($0.entrance,home)<simd_distance_squared($1.entrance,home)}?.entrance
  }
  func owner(at p: BlockPosition) -> UInt64? { properties.first { $0.contains(p) }?.ownerID }
  func title(at p: BlockPosition) -> String? {
    guard let home = properties.first(where: { $0.contains(p) }) else { return nil }
    let name=ResidentState(index:home.ownerIndex,site:home.site).name
    return home.building.use == .home ? "\(name)'s home" : "\(home.building.use.sign.capitalized) · \(name)"
  }
  @discardableResult func edited(at p: BlockPosition, old: Block, new: Block, terrain: TerrainGenerator, time: Double) -> UInt64? {
    guard let home = properties.first(where: { $0.contains(p) }), home.original(at: p, terrain: terrain).isSolid else { return nil }
    var record = saved[home.id] ?? .init(home: home)
    if old.isSolid && !new.isSolid { record.damage(at: p, original: home.original(at: p, terrain: terrain), time: time) }
    else if new.isSolid { record.acknowledgeRepair(at: p) }
    saved[home.id] = record
    return home.ownerID
  }
  func takeInterventions() -> [(String, SIMD3<Float>)] {
    defer { interventions.removeAll(keepingCapacity: true) }
    return interventions
  }
  func plan(for id: UInt64) -> (UUID, AgencyPlan)? { pendingPlans.removeValue(forKey: id) }
  func damagedHome(for state: ResidentState) -> OwnedHome? {
    let carrying = state.record.agency?.cargo != nil
    if let id = state.record.agency?.helpingHome, let home = properties.first(where: { $0.id == id }), carrying || !(saved[id]?.repairs.isEmpty ?? true) { return home }
    return properties.first { $0.ownerID == state.id && (carrying || !(saved[$0.id]?.repairs.isEmpty ?? true)) }
  }
  func isComplete(_ id: UInt64) -> Bool { saved[id]?.repairs.isEmpty ?? true }

  /// Survey retained snapshots on a worker, never procedural columns in the
  /// render loop. Candidate cells are rechecked before every actual harvest.
  func updateSurvey(terrain: TerrainGenerator, chunks: [ChunkCoordinate: ChunkData], time: Double) {
    guard survey == nil, time >= nextSurvey, let site = properties.first?.site else { return }
    nextSurvey = time + 8
    let epoch = lifetime
    survey = Task { [weak self] in
      let worker = Task.detached(priority: .utility) { () -> [Source] in
        var found: [Source] = [], counts: [Block: Int] = [:]
        for ring in [4, 16, 30] { for step in 0..<48 {
          if Task.isCancelled { return [] }
          let angle = Float(step) * .pi * 2 / 48
          let x = site.x + Int(cos(angle) * Float(site.radius + ring))
          let z = site.z + Int(sin(angle) * Float(site.radius + ring))
          let surface = terrain.height(atX: x, z: z)
          for dy in -2...4 {
            let point = BlockPosition(x, surface + dy, z)
            guard let chunk = chunks[point.chunk], !site.contains(point),
              SettlementGenerator.site(at: point, terrain: terrain) == nil else { continue }
            let block = chunk[x - point.chunk.x * 16, point.y, z - point.chunk.z * 16]
            guard block.isSolid, block != .snow, (counts[block] ?? 0) < 5,
              terrain.block(at: point) == block else { continue }
            let exposed = VoxelMesher.offsets.contains { d in
              let q = point + d
              return chunks[q.chunk].map { !$0[q.x - q.chunk.x * 16, q.y, q.z - q.chunk.z * 16].isSolid } ?? false
            }
            if exposed { found.append(.init(point: point, material: block)); counts[block, default: 0] += 1 }
          }
        } }
        return found
      }
      let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
      guard let self, self.lifetime == epoch, !Task.isCancelled else { return }
      self.sources = result; self.survey = nil
    }
  }

  func options(for resident: ResidentState, neighbors: [ResidentState], player: SIMD3<Float>, time: Double,
    block: (BlockPosition) -> Block) -> [String: NPCDecisionOption] {
    var options: [String: NPCDecisionOption] = [:]
    if let invited = resident.record.agency?.invitationHome,
      let home = properties.first(where: { $0.id == invited }), !isComplete(invited) {
      if HomeDefense.willingToHelp(resident, requester: home.ownerID) {
        options["assist_home"] = .init(activity: .help, partnerID: home.ownerID,
          job: .init(.acceptHelp, home: home.id, target: .init(home.entrance)),
          description: "Accept a neighbor's request to protect and rebuild their damaged home. Share labor and supplies; strengthens this relationship.")
      }
      options["decline_help"] = .init(activity: .askHelp, job: .init(.declineHelp, home: home.id, target: .init(resident.position)),
        description: "Politely decline this request for help because your own needs, safety, responsibilities or relationship take priority.")
    }
    guard let home = damagedHome(for: resident), let record = saved[home.id] else { return options }
    let allies = neighbors.filter { $0.record.agency?.helpingHome == home.id || $0.role == .guard }
    let recentAttack = time - record.lastDamage < 14 && simd_distance_squared(player, home.entrance) < 28 * 28
    func choice(_ id: String, _ activity: ResidentActivity, _ kind: ResidentJobKind, _ target: BlockPosition,
      material: Block? = nil, recipe: VillageRecipe? = nil, description: String) {
      options[id] = .init(activity: activity, job: .init(kind, home: home.id, target: target, material: material, recipe: recipe), description: description)
    }
    if recentAttack {
      if !resident.record.memories.contains(where: { $0.event == "Asked the player to stop damaging the home" && time - $0.time < 12 }) {
        choice("warn_intruder", .defend, .warn, .init(player), description: "Tell the player to stop damaging this home. Approach and object without claiming you can overpower them.")
      }
      if HomeDefense.canIntervene(resident: resident, allies: allies, player: player, flying: playerFlying, driving: playerDriving) {
        choice("stop_intruder", .defend, .confront, .init(player), description: "You and nearby allies have enough strength to intervene: approach, interrupt breaking and push the intruder away. Do not pursue vehicles or airborne players.")
      }
      choice("retreat", .flee, .retreat, .init(home.site.center), description: "Avoid an unsafe confrontation and retreat toward the town square. Protect yourself before returning to repairs.")
    }
    let social = resident.record.agency?.plan?.social ?? .askFriends
    func helpScore(_ other: ResidentState) -> Float {
      let relationship = resident.record.relationships.first { $0.otherID == other.id }
      let skill: Float = other.role == .builder || other.role == .guard ? 2 : 0
      return (social == .askSkilledNeighbors ? skill : (relationship?.trust ?? 0.3) * 3)
        - simd_distance(other.position, resident.position) / 50
    }
    if time - record.lastHelp > 20, let helper = neighbors.filter({ candidate in candidate.id != resident.id
      && candidate.record.agency?.helpingHome != home.id && candidate.record.agency?.invitationHome != home.id
      && !(resident.record.agency?.memory.experiences.contains { memory in memory.kind == .refusedHelp
        && memory.other == candidate.id && time - memory.time < 180 } ?? false)
      && HomeDefense.willingToHelp(candidate, requester: resident.id) })
      .max(by: { helpScore($0) < helpScore($1) }) {
      options["ask_for_help"] = .init(activity: .askHelp, partnerID: helper.id,
        job: .init(.requestHelp, home: home.id, target: .init(helper.position)),
        description: "Ask \(helper.name), a \(helper.roleName), to help \(recentAttack ? "stop the damage and " : "")rebuild. They decide whether to accept according to their needs and relationship.")
    }
    if let cargo = resident.record.agency?.cargo {
      choice("deliver_supplies", .gather, .deliver, .init(home.entrance), material: cargo.block,
        description: "Carry \(cargo.count) collected \(cargo.block.name) to this home's shared stockpile before gathering more.")
      return options
    }
    guard let repair = record.repairs.first else { return options }
    let policy = resident.record.agency?.plan?.materials ?? .craftFirst
    let acceptable = [repair.original] + (policy == .exact ? [] : HomeRecord.alternatives(for: repair.original, habitat: home.site.habitat))
    if let material = acceptable.first(where: { record.stock[$0] > 0 }) {
      choice("patch_home", .repair, .repair, repair.position, material: material,
        description: "Repair one missing part of the home using one real \(material.name) from the stockpile\(material == repair.original ? " (exact match)" : " (suitable substitute for \(repair.original.name))"). \(record.repairs.count) damaged blocks remain.")
    }
    for recipe in VillageRecipe.allCases where acceptable.contains(recipe.product.block) && recipe.canMake(with: record.stock, role: resident.role) {
      choice("craft_\(recipe.rawValue)", .craft, .craft, .init(resident.workplace), recipe: recipe,
        description: "Use your worksite kiln to make \(recipe.product.count) \(recipe.product.block.name), consuming \(recipe.ingredients.map { "\($0.count) \($0.block.name)" }.joined(separator: ", ")).")
    }
    var wanted = acceptable
    if policy != .suitableSubstitutes {
      wanted += VillageRecipe.allCases.filter { $0.product.block == repair.original }.flatMap { $0.ingredients.map(\.block) }
    }
    for material in Array(Set(wanted)).sorted(by: { $0.rawValue < $1.rawValue }) where record.stock[material] < 12 {
      if let source = sources.filter({ source in source.material == material && block(source.point) == material
        && !(resident.record.agency?.memory.experiences.contains { $0.kind == .failedRoute && $0.point == source.point && time - $0.time < 120 } ?? false) })
        .min(by: { simd_distance_squared($0.point.center, resident.position) < simd_distance_squared($1.point.center, resident.position) }) {
        choice("gather_\(material.rawValue)", .gather, .gather, source.point, material: material,
          description: "Walk to a known natural \(material.name) source, harvest one block and bring it home. No supplies appear for free; this changes the landscape. May support an exact repair, kiln recipe or substitute.")
      }
    }
    if record.repairs.count >= 2 || options["patch_home"] == nil {
      considerPlan(resident: resident, home: home, record: record, options: options, recentAttack: recentAttack, time: time)
    }
    return options
  }

  func destination(_ job: ResidentJob, resident: ResidentState, block: (BlockPosition) -> Block) -> SIMD3<Float> {
    guard let home = properties.first(where: { $0.id == job.homeID }) else { return resident.home }
    if job.kind == .repair || job.kind == .acceptHelp || job.kind == .deliver { return home.entrance }
    if job.kind == .gather {
      for d in [BlockPosition(1, 0, 0), .init(-1, 0, 0), .init(0, 0, 1), .init(0, 0, -1), .init(0, 1, 0)] {
        let candidate = (job.target + d).center
        let point = resident.habitat == .aquatic ? ResidentNavigation.swimPosition(at: candidate, block: block)
          : ResidentNavigation.standing(at: candidate, block: block)
        if let point { return point }
      }
    }
    return job.target.center
  }

  /// Returns true once the work step finishes. Mutations are checked by the
  /// world first, so competing workers cannot duplicate resources or repairs.
  func execute(_ job: ResidentJob, resident: inout ResidentState, neighbors: [ResidentState],
    player: SIMD3<Float>, time: Double, block: (BlockPosition) -> Block) -> (finished: Bool, message: String?, invite: UInt64?) {
    guard let home = properties.first(where: { $0.id == job.homeID }), var record = saved[job.homeID] else { return (true, nil, nil) }
    if resident.record.agency == nil { resident.record.agency = .init() }
    let progress = resident.activityProgress
    switch job.kind {
    case .warn:
      guard progress >= 0.4 else { return (false, nil, nil) }
      resident.remember("Asked the player to stop damaging the home", time: time)
      return (true, "Please stop! This is \(home.ownerID == resident.id ? "my" : "my neighbor's") home.", nil)
    case .confront:
      guard progress >= 0.8 else { return (false, nil, nil) }
      let allies = neighbors.filter { $0.record.agency?.helpingHome == home.id || $0.role == .guard }
      if time >= nextIntervention, time - record.lastDamage < 14,
        simd_distance_squared(player, resident.position) < 6 * 6,
        HomeDefense.canIntervene(resident: resident, allies: allies, player: player, flying: playerFlying, driving: playerDriving) {
        interventions.append((resident.name, resident.position)); nextIntervention = time + 2
      }
      return (true, "Stop damaging our home!", nil)
    case .requestHelp:
      guard progress >= 0.5 else { return (false, nil, nil) }
      record.lastHelp = time; saved[home.id] = record
      return (true, "Will you help me protect and rebuild this home?", resident.partnerID)
    case .acceptHelp:
      resident.record.agency?.helpingHome = home.id
      resident.record.agency?.invitationHome = nil
      resident.record.agency?.memory.remember(.helped, "Agreed to help rebuild a neighbor's home", other: home.ownerID, time: time, importance: 0.8)
      resident.meet(home.ownerID, helping: true, time: time)
      return (true, "I'll help. Let's find the supplies we need.", nil)
    case .declineHelp:
      guard progress >= 0.5 else { return (false, nil, nil) }
      resident.record.agency?.invitationHome = nil
      resident.record.agency?.memory.remember(.refusedHelp, "Could not help this neighbor with repairs", other: home.ownerID, time: time)
      return (true, "I'm sorry, I can't help right now. I need to see to my own responsibilities.", nil)
    case .gather:
      guard let material = job.material else { return (true, nil, nil) }
      guard progress >= (material.breakingEffort ?? 2), simd_distance(resident.position, job.target.center) < 5 else { return (false, nil, nil) }
      let eye = resident.position + [0, 1.5, 0], delta = job.target.center - eye
      guard VoxelRaycast.cast(origin: eye, direction: delta, reach: max(0, simd_length(delta) - 0.9), block: block) == nil else {
        resident.record.agency?.memory.remember(.failedRoute, "This source is obstructed", at: job.target, time: time)
        return (true, nil, nil)
      }
      guard resident.record.agency?.cargo == nil, block(job.target) == material,
        onEdit?(job.target, material, .air) == true else { return (true, nil, nil) }
      resident.record.agency?.cargo = .init(material, 1)
      resident.record.agency?.memory.remember(.foundMaterial, "Collected \(material.name) for repairs", at: job.target, time: time)
    case .deliver:
      guard progress >= 0.5 else { return (false, nil, nil) }
      guard let cargo = resident.record.agency?.cargo,
        record.stock.add(cargo.block, count: cargo.count) else { return (true, nil, nil) }
      resident.record.agency?.cargo = nil; saved[home.id] = record
    case .craft:
      guard let recipe = job.recipe else { return (true, nil, nil) }
      guard progress >= recipe.seconds else { return (false, nil, nil) }
      if recipe.make(in: &record.stock, role: resident.role) {
        saved[home.id] = record
        resident.remember("Made \(recipe.product.block.name) from raw materials and fuel at the kiln", time: time)
      }
    case .repair:
      guard progress >= 2 else { return (false, nil, nil) }
      guard let material = job.material, record.repairs.contains(where: { $0.position == job.target }),
        record.stock[material] > 0 else { return (true, nil, nil) }
      let current = block(job.target)
      if current.isSolid { record.acknowledgeRepair(at: job.target); saved[home.id] = record; return (true, nil, nil) }
      guard onEdit?(job.target, current, material) == true else { return (true, nil, nil) }
      record.stock.consume([.init(material, 1)]); record.acknowledgeRepair(at: job.target); saved[home.id] = record
      resident.record.agency?.memory.remember(.repaired, "Repaired this home with \(material.name)", at: job.target,
        other: home.ownerID, time: time, importance: 0.8)
      return (true, record.repairs.isEmpty ? "Our home is whole again. Thank you to everyone who helped." : nil, nil)
    case .retreat: return (progress >= 1, nil, nil)
    }
    return (true, nil, nil)
  }

  func localOption(_ options: [String: NPCDecisionOption], resident: ResidentState) -> NPCDecisionOption? {
    for key in ["stop_intruder", "warn_intruder", "ask_for_help", "deliver_supplies", "patch_home", "assist_home", "decline_help"] {
      if let option = options[key] { return option }
    }
    if let recipe = options.keys.sorted().first(where: { $0.hasPrefix("craft_") }) { return options[recipe] }
    if let gather = options.keys.sorted().first(where: { $0.hasPrefix("gather_") }) { return options[gather] }
    return nil
  }

  private func considerPlan(resident: ResidentState, home: OwnedHome, record: HomeRecord,
    options: [String: NPCDecisionOption], recentAttack: Bool, time: Double) {
    let previous = resident.record.agency?.plannedAt ?? 0
    let blockedSince = resident.record.agency?.memory.experiences.contains { $0.kind == .failedRoute && $0.time > previous } ?? false
    guard (resident.record.agency?.plannedIncident != record.incident || (blockedSince && time - previous > 180)),
      pendingPlans[resident.id] == nil else { return }
    let context = ReasoningSituation(actor: resident.name, kind: "villager", problem: "A home needs protection, supplies and reconstruction",
      facts: ["Role: \(resident.roleName); personality: \(resident.personality)", "Owner: \(home.ownerID); this actor: \(resident.id)",
        "Missing blocks: \(record.repairs.count); attack ongoing: \(recentAttack)",
        "Physical strength: \(HomeDefense.strength(of: resident)); player flying: \(playerFlying); vehicle: \(playerDriving)",
        "Stock: \(record.stock.materials.map { "\($0.count) \($0.block.name)" }.joined(separator: ", "))",
        "Known materials nearby: \(Set(sources.map { $0.material.name }).sorted().joined(separator: ", "))",
        "Relationships: \(resident.record.relationships.prefix(5).map { "\($0.otherID): \($0.description)" }.joined(separator: ", "))"],
      memories: resident.record.agency?.memory.recall(time: time, relevant: [.homeDamaged, .helped, .foundMaterial]).map(\.detail) ?? [],
      availableActions: options.values.map(\.description))
    let epoch = lifetime, incident = record.incident, id = resident.id
    planner?.request(context) { [weak self] plan in
      guard let self, self.lifetime == epoch, self.saved[home.id]?.incident == incident, !self.isComplete(home.id) else { return }
      self.pendingPlans[id] = (incident, plan)
    }
  }
}
