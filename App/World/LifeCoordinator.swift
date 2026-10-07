import Foundation
import QuartzCore
import WorldCore

@MainActor final class LifePresentation {
  var view = LifeView()
  var revision: UInt64 = 0
  var send: ((LifeCommand) -> Void)?
  var flying = false
  var driving = false
  var logs = false
  var time: Double = 0
  var interventions: [(String, SIMD3<Float>)] = []
}

/// Render-facing caches have synchronous reads. None waits for the simulation
/// actor, provider response, pathfinder, resource survey or save serialization.
@MainActor final class FaunaLife {
  private let presentation: LifePresentation
  init(_ presentation: LifePresentation) { self.presentation = presentation }
  var records: [FaunaRecord] { presentation.view.fauna }
  var status: String { presentation.view.faunaStatus }
  func restore(_ records: [FaunaRecord]) {
    presentation.view.fauna = records.filter(\.isValid)
    presentation.view.faunaByID = Dictionary(presentation.view.fauna.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    presentation.view.directives = [:]
    presentation.send?(.restoreFauna(records))
  }
  func canSpawn(id: UInt64, time: Double) -> Bool { (presentation.view.faunaByID[id]?.absentUntil ?? 0) <= time }
  func restoredPosition(id: UInt64) -> SIMD3<Float>? { presentation.view.faunaByID[id]?.position }
  func knownKind(id: UInt64) -> AnimalKind? {
    guard let species = presentation.view.faunaByID[id]?.species else { return nil }
    return AnimalKind.allCases.first { String(describing: $0) == species }
  }
  func knownDinosaur(id: UInt64) -> DinosaurKind? { presentation.view.faunaByID[id].flatMap { DinosaurKind(rawValue: $0.species) } }
  func directive(id: UInt64) -> AnimalDecisionOption? { presentation.view.directives[id] }
  func goal(id: UInt64) -> String { presentation.view.faunaByID[id]?.goal.label ?? "Exploring" }
  func fed(id: UInt64, at position: SIMD3<Float>, time: Double) { presentation.send?(.fed(id, position, time)) }
  func petted(id: UInt64, at position: SIMD3<Float>, time: Double) { presentation.send?(.petted(id, position, time)) }
}
@MainActor final class HomesteadLife {
  private let presentation: LifePresentation
  init(_ presentation: LifePresentation) { self.presentation = presentation }
  var records: [HomeRecord] { presentation.view.homes }
  var playerFlying: Bool { get { presentation.flying } set { presentation.flying = newValue } }
  var playerDriving: Bool { get { presentation.driving } set { presentation.driving = newValue } }
  func title(at p: BlockPosition) -> String? {
    guard let home = presentation.view.properties.first(where: { $0.contains(p) }) else { return nil }
    return "\(ResidentState(index: home.ownerIndex, site: home.site).name)'s home"
  }
  func takeInterventions() -> [(String, SIMD3<Float>)] {
    defer { presentation.interventions.removeAll(keepingCapacity: true) }
    return presentation.interventions
  }
}
@MainActor final class DeliberationPresentation {
  private let presentation: LifePresentation
  init(_ presentation: LifePresentation) { self.presentation = presentation }
  var status: String { presentation.view.reasoningStatus }
  func configure(key: String?, enabled: Bool, hourlyLimit: Double) { presentation.send?(.reasoning(key, enabled, hourlyLimit)) }
}

@MainActor final class LifeCoordinator {
  let presentation = LifePresentation()
  lazy var fauna = FaunaLife(presentation)
  lazy var deliberation = DeliberationPresentation(presentation)
  private lazy var worker = Task { await LifeWorker() }
  private var task: Task<Void, Never>?
  private var commands: [LifeCommand] = []
  private var generation: UInt64 = 0
  private var commandRevision: UInt64 = 0
  private var accumulator: Float = 0
  private var saveBarriers = 0
  private var latestCompletion: Double?
  private var timing = DurationTiming()
  private var captureTiming = DurationTiming()
  private var publicationTiming = DurationTiming()
  struct Metrics: Sendable, Encodable {
    let workerCPU: DurationTiming.Snapshot
    let snapshotCPU: DurationTiming.Snapshot
    let publicationCPU: DurationTiming.Snapshot
    let snapshotAgeMilliseconds: Double?
    let busy: Bool
    let pendingCommands: Int
    let completedStepsTotal: Int
    let discardedProposalsTotal: Int
    let coalescedFrameCallsTotal: Int
    let mainThreadViolationsTotal: Int
  }
  private(set) var coalescedFrames = 0
  private(set) var rejectedFrames = 0
  private(set) var completedFrames = 0
  private(set) var mainThreadViolations = 0
  var currentWorldRevision: (() -> UInt64)?
  var commitEffects: (([LifeEffect]) -> Bool)?
  var onApplied: ((CreatureStep) -> Void)?
  var busy: Bool { task != nil }
  var pendingCommandCount: Int { commands.count }
  var snapshotAgeMilliseconds: Double { latestCompletion.map { (CACurrentMediaTime() - $0) * 1_000 } ?? 0 }
  init() { presentation.send = { [weak self] in self?.enqueue($0) } }
  func reset() {
    generation &+= 1; accumulator = 0
    presentation.view = .init(); presentation.revision &+= 1; presentation.interventions = []
    enqueue(.reset)
  }
  func suspend() { accumulator = 0; enqueue(.suspend) }
  func enqueue(_ command: LifeCommand) {
    commands.append(command); commandRevision &+= 1
    if task == nil { start(nil) }
  }
  /// Snapshot creation is also skipped while busy. We retain elapsed time and
  /// use the newest world next time, instead of queuing dozens of stale frames.
  func tick(seconds: Float, makeFrame: (Float) -> LifeFrame) {
    guard seconds > 0 else { return }
    accumulator = min(0.2, accumulator + seconds)
    guard accumulator >= 1 / 30 else { return }
    guard task == nil, saveBarriers == 0 else { coalescedFrames += 1; return }
    let dt = accumulator; accumulator = 0
    let startTime = CACurrentMediaTime(), frame = makeFrame(dt)
    captureTiming.record(seconds: CACurrentMediaTime() - startTime)
    start(frame)
  }
  /// Only saves/transitions await this barrier. Rendering never calls it.
  func flush() async {
    saveBarriers += 1
    defer { saveBarriers -= 1 }
    while task != nil || !commands.isEmpty {
      if task == nil { start(nil) }
      await task?.value
    }
  }
  func consumePerformance() -> Metrics {
    defer { timing.reset(); captureTiming.reset(); publicationTiming.reset() }
    return .init(workerCPU: timing.snapshot, snapshotCPU: captureTiming.snapshot,
      publicationCPU: publicationTiming.snapshot, snapshotAgeMilliseconds: latestCompletion == nil ? nil : snapshotAgeMilliseconds,
      busy: busy, pendingCommands: commands.count, completedStepsTotal: completedFrames,
      discardedProposalsTotal: rejectedFrames, coalescedFrameCallsTotal: coalescedFrames,
      mainThreadViolationsTotal: mainThreadViolations)
  }
  private func start(_ frame: LifeFrame?) {
    guard task == nil else { return }
    let batch = commands; commands.removeAll(keepingCapacity: true)
    let epoch = generation, revision = commandRevision, worker = worker
    task = Task { [weak self] in
      let simulation = await worker.value
      let proposal = await simulation.propose(frame, commands: batch)
      guard let self else { await simulation.resolve(proposal.id, accepted: false); return }
      let publishStart = CACurrentMediaTime()
      let valid = self.generation == epoch && self.commandRevision == revision
        && (frame == nil || self.currentWorldRevision?() == frame?.world.revision)
      let accepted = valid && (proposal.effects.isEmpty || self.commitEffects?(proposal.effects) == true)
      self.timing.record(seconds: proposal.milliseconds / 1_000)
      if proposal.ranOnMainThread { self.mainThreadViolations += 1 }
      if accepted {
        self.presentation.view = proposal.view; self.presentation.revision &+= 1
        self.presentation.interventions += proposal.view.interventions
        if frame != nil { self.onApplied?(proposal.creatures) }
        if frame != nil { self.completedFrames += 1; self.latestCompletion = CACurrentMediaTime() }
      } else { self.rejectedFrames += 1 }
      self.publicationTiming.record(seconds: CACurrentMediaTime() - publishStart)
      await simulation.resolve(proposal.id, accepted: accepted)
      self.task = nil
      if !self.commands.isEmpty { self.start(nil) }
    }
  }
}
