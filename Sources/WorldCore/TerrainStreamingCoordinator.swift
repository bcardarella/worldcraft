import Foundation

/// A short lock protects value exchange only. No generation, allocation of GPU
/// resources, actor waits or I/O occurs while holding it. MainActor owns demand
/// changes; the coordinator and its workers publish immutable results.
public final class TerrainStreamingExchange: @unchecked Sendable {
  public struct Scheduling: Sendable, Encodable {
    public var demandUpdates = 0, pumps = 0
    public var demandUpdateMilliseconds = 0.0, dispatchMilliseconds = 0.0
    public var maximumDemandUpdateMilliseconds = 0.0, maximumDispatchMilliseconds = 0.0
  }
  public struct Metrics: Sendable, Encodable {
    public var indexedWorkQueue = true
    public var scheduling = Scheduling()
    public var queued = 0
    public var workers = 0
    public var readyTiles = 0
    public var readyBytes = 0
    public var queuedByClass: [String: Int] = [:]
    public var oldestQueuedMilliseconds: [String: Double] = [:]
    public var completedTotal = 0
    public var discardedTotal = 0
    public var recentCPU: [String: DurationTiming.Snapshot] = [:]
    public var readyWait: DurationTiming.Snapshot = DurationTiming().snapshot
    public var readyAgingEnabled = true
    public var agedPublications = 0, nativeCapacityDeferrals = 0
    public var oldestReadyMilliseconds = 0.0, maximumReadyWaitMilliseconds = 0.0
  }
  private struct Ready {
    let tile: PreparedTerrainTile
    let arrived: Double
  }
  private let lock = NSLock()
  private var accepted: [TerrainWorkID: TerrainPreparationRequest] = [:]
  private var ready: [TerrainWorkID: Ready] = [:]
  private var collision: [TerrainWorkID: ChunkData] = [:]
  private var bytes = 0
  private var sequence: UInt64 = 0
  private var statistics = Metrics()
  private var readyTiming = DurationTiming()
  private var publicationTurn = 0
  enum Update { case demand([TerrainPreparationRequest], UInt64), resume }
  private var pendingDemand: Update?
  private var resumeRequested = false, notificationScheduled = false
  private var readyNotification: (@Sendable () -> Void)?
  private let agingReadyResults: Bool
  private var agedPublications = 0, nativeCapacityDeferrals = 0
  private var maximumReadyWait = 0.0
  public init(agingReadyResults: Bool = true) { self.agingReadyResults = agingReadyResults }

  /// One native consumer; callbacks must only signal work and never run while
  /// holding the exchange lock. Registration cannot miss already-ready work.
  public func setReadyNotification(_ notification: (@Sendable () -> Void)?) {
    lock.lock(); readyNotification = notification; lock.unlock()
    notification?()
  }

  /// Invalidate old results synchronously before asking the actor to update its
  /// queue. Out-of-order actor tasks cannot reopen acceptance of obsolete work.
  public func expect(_ requests: [TerrainPreparationRequest], sequence: UInt64) {
    lock.lock(); defer { lock.unlock() }
    guard sequence >= self.sequence else { return }
    self.sequence = sequence
    pendingDemand = .demand(requests, sequence)
    accepted = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0) })
    ready = ready.filter { accepted[$0.key] != nil }
    collision = collision.filter { accepted[$0.key] != nil }
    bytes = ready.values.reduce(0) { $0 + $1.tile.byteCount }
  }
  public func invalidate(_ tile: TerrainTile) {
    lock.lock(); defer { lock.unlock() }
    let keys = accepted.keys.filter { $0.tile == tile }
    for key in keys {
      accepted[key] = nil; collision[key] = nil
      bytes -= ready.removeValue(forKey: key)?.tile.byteCount ?? 0
    }
  }
  public func accepts(_ id: TerrainWorkID) -> Bool {
    lock.lock(); defer { lock.unlock() }; return accepted[id] != nil
  }
  func acceptedIDs() -> Set<TerrainWorkID> {
    lock.lock(); defer { lock.unlock() }; return Set(accepted.keys)
  }
  public func publishCollision(_ chunk: ChunkData, id: TerrainWorkID) {
    lock.lock(); defer { lock.unlock() }
    if accepted[id] != nil { collision[id] = chunk }
  }
  public func takeCollisions() -> [TerrainWorkID: ChunkData] {
    lock.lock(); defer { lock.unlock() }
    let result = collision; collision.removeAll(keepingCapacity: true); return result
  }
  @discardableResult func publish(_ tile: PreparedTerrainTile,
    at time: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
    lock.lock()
    guard accepted[tile.id] != nil else { lock.unlock(); return false }
    bytes -= ready[tile.id]?.tile.byteCount ?? 0
    // Demand reprioritization or duplicate publication must not renew a ready
    // result's waiting time. A fresh work identity has its own arrival time.
    ready[tile.id] = .init(tile: tile, arrived: ready[tile.id]?.arrived ?? time)
    bytes += tile.byteCount
    let notification = readyNotification
    lock.unlock()
    notification?()
    return true
  }
  public func takeReady(maximumBytes: Int = .max, maximumPublicationBytes: Int = .max,
    reuseMeshes: Bool = true) -> PreparedTerrainTile? {
    takeReady(maximumBytes: maximumBytes, maximumPublicationBytes: maximumPublicationBytes,
      reuseMeshes: reuseMeshes, at: ProcessInfo.processInfo.systemUptime)
  }
  /// Explicit monotonic time supports deterministic scheduling checks; normal
  /// callers use the public uptime-based method above.
  func takeReady(maximumBytes: Int = .max, maximumPublicationBytes: Int = .max,
    reuseMeshes: Bool = true, at time: Double) -> PreparedTerrainTile? {
    lock.lock(); defer { lock.unlock() }
    let choices = ready.values.filter { $0.tile.byteCount <= maximumBytes }.compactMap { accepted[$0.tile.id] }
    let enqueued = agingReadyResults ? ready.mapValues(\.arrived) : [:]
    var nextTurn = publicationTurn
    guard let request = TerrainServiceOrder.next(choices, turn: &nextTurn, enqueued: enqueued, now: time),
      let candidate = ready[request.id] else { return nil }
    // Let the native stage drain for the next selected result. Continually
    // bypassing a large tile for cheaper arrivals could starve it during flight.
    guard maximumPublicationBytes == .max || candidate.tile.publicationByteCount(reuseMeshes: reuseMeshes) <= maximumPublicationBytes else {
      nativeCapacityDeferrals += 1; return nil
    }
    publicationTurn = nextTurn
    guard let result = ready.removeValue(forKey: request.id) else { return nil }
    bytes -= result.tile.byteCount
    let waited = max(0,time-result.arrived)
    readyTiming.record(seconds: waited); maximumReadyWait = max(maximumReadyWait,waited)
    if waited > 2 { agedPublications += 1 }
    return result.tile
  }
  public var metrics: Metrics {
    lock.lock(); defer { lock.unlock() }
    var result = statistics
    result.readyTiles = ready.count; result.readyBytes = bytes
    result.readyWait = readyTiming.snapshot
    result.readyAgingEnabled = agingReadyResults
    result.agedPublications = agedPublications; result.nativeCapacityDeferrals = nativeCapacityDeferrals
    let now = ProcessInfo.processInfo.systemUptime
    result.oldestReadyMilliseconds = ready.values.map { max(0,now-$0.arrived)*1_000 }.max() ?? 0
    result.maximumReadyWaitMilliseconds = maximumReadyWait*1_000
    return result
  }
  public var occupancy: (tiles: Int, bytes: Int) {
    lock.lock(); defer { lock.unlock() }; return (ready.count, bytes)
  }
  public var counts: (queued: Int, workers: Int, ready: Int, bytes: Int) {
    lock.lock(); defer { lock.unlock() }
    return (statistics.queued, statistics.workers, ready.count, bytes)
  }
  func updateMetrics(_ metrics: Metrics) {
    lock.lock(); defer { lock.unlock() }; statistics = metrics
  }
  func reserveNotification() -> Bool {
    lock.lock(); defer { lock.unlock() }
    if pendingDemand == nil { resumeRequested = true }
    guard !notificationScheduled else { return false }
    notificationScheduled = true; return true
  }
  func nextUpdate() -> Update? {
    lock.lock(); defer { lock.unlock() }
    if let demand = pendingDemand { pendingDemand = nil; resumeRequested = false; return demand }
    if resumeRequested { resumeRequested = false; return .resume }
    notificationScheduled = false; return nil
  }
}

/// Each service class receives opportunities. A continual stream of near-detail
/// requests cannot starve missing horizon coverage (or vice versa).
enum TerrainServiceOrder {
  static let cycle: [TerrainWorkClass] = [.collision, .coverage, .detail, .coverage, .refinement, .detail]
  static func next(_ requests: [TerrainPreparationRequest], turn: inout Int,
    enqueued: [TerrainWorkID: Double] = [:], now: Double = 0) -> TerrainPreparationRequest? {
    guard !requests.isEmpty else { return nil }
    for _ in cycle.indices {
      let service = cycle[turn % cycle.count]; turn = (turn + 1) % cycle.count
      if let result = requests.filter({ $0.service == service }).min(by: {
        let first = enqueued[$0.id] ?? now, second = enqueued[$1.id] ?? now
        if min(first, second) < now - 2, first != second { return first < second }
        return $0.priority == $1.priority ? ($0.id.tile.z, $0.id.tile.x, $0.id.tile.size)
          < ($1.id.tile.z, $1.id.tile.x, $1.id.tile.size) : $0.priority < $1.priority
      }) { return result }
    }
    return nil
  }
}

/// Owns job lifetime and continuous refill, independent of scene callback rate.
/// The actor runs no synchronous meshing. Cancellation retains a worker slot
/// until its detached task actually returns, including across planet changes.
public actor TerrainStreamingCoordinator {
  public typealias Builder = @Sendable (TerrainPreparationRequest, @Sendable (ChunkData) -> Void) async -> PreparedTerrainTile?
  public nonisolated let exchange: TerrainStreamingExchange
  private let builder: Builder
  private let preparedLimit: Int
  private let byteLimit: Int
  private var slots: PreparationSlots<TerrainWorkID>
  private var running: [UUID: (TerrainWorkID, Task<Void, Never>)] = [:]
  private var requests: [TerrainWorkID: TerrainPreparationRequest] = [:]
  private var enqueued: [TerrainWorkID: Double] = [:]
  private var completed: Set<TerrainWorkID> = []
  private var sequence: UInt64 = 0
  private var turn = 0
  private let indexedWorkQueue: Bool
  private var workQueue = TerrainWorkQueue()
  private var scheduling = TerrainStreamingExchange.Scheduling()
  private var completedTotal = 0, discardedTotal = 0
  private var timing: [String: DurationTiming] = [:]

  public init(exchange: TerrainStreamingExchange = .init(), workers: Int = 2,
    preparedLimit: Int = 8, byteLimit: Int = 8 * 1_024 * 1_024,
    indexedWorkQueue: Bool = true,
    builder: @escaping Builder = TerrainPreparation.prepare) {
    precondition(preparedLimit >= workers && workers > 0 && byteLimit > 0)
    self.exchange = exchange; self.builder = builder; self.preparedLimit = preparedLimit
    self.byteLimit = byteLimit; slots = .init(limit: workers)
    self.indexedWorkQueue = indexedWorkQueue
  }

  public func update(_ incoming: [TerrainPreparationRequest], sequence: UInt64) {
    guard sequence >= self.sequence else { return }
    let began = ProcessInfo.processInfo.systemUptime
    self.sequence = sequence
    let next = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
    for (_, job) in running where next[job.0] == nil {
      slots.invalidate(job.0); job.1.cancel()
    }
    let now = ProcessInfo.processInfo.systemUptime
    enqueued = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, enqueued[$0.id] ?? now) })
    requests = next; completed.formIntersection(next.keys)
    if indexedWorkQueue {
      workQueue = .init(incoming.filter { !completed.contains($0.id) && !slots.contains($0.id) },
        enqueued: enqueued, now: now)
    }
    let milliseconds = (ProcessInfo.processInfo.systemUptime-began)*1_000
    scheduling.demandUpdates += 1; scheduling.demandUpdateMilliseconds += milliseconds
    scheduling.maximumDemandUpdateMilliseconds = max(scheduling.maximumDemandUpdateMilliseconds,milliseconds)
    pump()
  }
  public func resume() { pump() }

  /// Coalesce demand changes and publication feedback into one actor wake-up.
  /// A busy actor cannot accumulate an unbounded Task for every render frame.
  public nonisolated func wake() {
    guard exchange.reserveNotification() else { return }
    Task { await consumeUpdates() }
  }
  private func consumeUpdates() {
    while let update = exchange.nextUpdate() {
      switch update {
      case let .demand(requests, sequence): self.update(requests, sequence: sequence)
      case .resume: pump()
      }
    }
  }

  private func pump() {
    let began = ProcessInfo.processInfo.systemUptime
    while slots.available > 0 {
      let state = exchange.occupancy
      // The byte watermark stops new producers. Up to the bounded active worker
      // count can finish above it; an oversized tile is never silently dropped.
      guard slots.count + state.tiles < preparedLimit, state.bytes < byteLimit else { break }
      let request: TerrainPreparationRequest?
      if indexedWorkQueue {
        request = workQueue.next(turn: &turn, now: ProcessInfo.processInfo.systemUptime,
          accepts: { exchange.accepts($0) }).flatMap { requests[$0] }
      } else {
        let accepted = exchange.acceptedIDs()
        let queued = requests.values.filter { !completed.contains($0.id) && !slots.contains($0.id) && accepted.contains($0.id) }
        request = TerrainServiceOrder.next(Array(queued), turn: &turn,
          enqueued: enqueued, now: ProcessInfo.processInfo.systemUptime)
      }
      guard let request, let token = slots.reserve(request.id) else { break }
      let now = ProcessInfo.processInfo.systemUptime
      timing["queue_wait", default: .init()].record(seconds: now - (enqueued[request.id] ?? now))
      let builder = builder, exchange = exchange
      let task = Task.detached(priority: .userInitiated) { [weak self] in
        let began = ProcessInfo.processInfo.systemUptime
        let result = await builder(request) { exchange.publishCollision($0, id: request.id) }
        let duration = ProcessInfo.processInfo.systemUptime - began
        await self?.finished(result, id: request.id, token: token, duration: duration)
      }
      running[token] = (request.id, task)
    }
    publishMetrics(dispatchBegan: began)
  }

  private func finished(_ result: PreparedTerrainTile?, id: TerrainWorkID, token: UUID, duration: Double) {
    let current = slots.isCurrent(token)
    slots.finish(token); running[token] = nil
    timing["preparation", default: .init()].record(seconds: duration)
    if current, requests[id] != nil, let result, result.id == id, exchange.publish(result) {
      completed.insert(id); completedTotal += 1
      for (name, seconds) in result.stages { timing[name, default: .init()].record(seconds: seconds) }
    } else {
      discardedTotal += 1
      // A builder failure keeps the old retry policy; invalidated/cancelled work
      // cannot consume a new slot or resurrect an obsolete request.
      if indexedWorkQueue, let request = requests[id], exchange.accepts(id),
        !completed.contains(id), !slots.contains(id) {
        workQueue.insert(request, enqueued: enqueued[id] ?? ProcessInfo.processInfo.systemUptime)
      }
    }
    pump()
  }
  private func publishMetrics(dispatchBegan: Double) {
    var metrics = TerrainStreamingExchange.Metrics()
    metrics.indexedWorkQueue = indexedWorkQueue
    metrics.workers = slots.count; metrics.completedTotal = completedTotal; metrics.discardedTotal = discardedTotal
    let now = ProcessInfo.processInfo.systemUptime
    if indexedWorkQueue {
      let summary = workQueue.summary(now: now)
      metrics.queued = workQueue.count; metrics.queuedByClass = summary.counts
      metrics.oldestQueuedMilliseconds = summary.ages
    } else {
      for request in requests.values where !completed.contains(request.id) && !slots.contains(request.id) {
        metrics.queued += 1; metrics.queuedByClass[request.service.rawValue, default: 0] += 1
        metrics.oldestQueuedMilliseconds[request.service.rawValue] = max(
          metrics.oldestQueuedMilliseconds[request.service.rawValue] ?? 0, (now - (enqueued[request.id] ?? now)) * 1000)
      }
    }
    metrics.recentCPU = timing.mapValues(\.snapshot)
    // Active coordinator operation duration, including metric preparation but
    // excluding worker generation, actor queue wait and exchange publication.
    let milliseconds = (ProcessInfo.processInfo.systemUptime-dispatchBegan)*1_000
    scheduling.pumps += 1; scheduling.dispatchMilliseconds += milliseconds
    scheduling.maximumDispatchMilliseconds = max(scheduling.maximumDispatchMilliseconds,milliseconds)
    metrics.scheduling = scheduling
    exchange.updateMetrics(metrics)
  }
}
