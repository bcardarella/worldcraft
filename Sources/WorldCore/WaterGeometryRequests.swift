import Foundation

/// Static water inputs awaiting publication. Animated waves, tides, disturbances
/// and materials live outside this registry and keep advancing after a no-op.
/// Kept on the presentation actor; worker jobs receive immutable batch snapshots.
public struct WaterGeometryRequests: Sendable {
  public struct Metrics: Sendable, Encodable {
    public var coalescesIdentical = true
    public var acceptsPartialCompletions = true, prioritizesCoverage = true
    public var geometryUpdates = 0, identicalUpdates = 0, removals = 0
    public var requestedTiles = 0, pendingBatches = 0
    public var preparations = 0, acceptedTiles = 0, discardedTiles = 0
    public var salvagedCompletions = 0, discardedCompletions = 0
    public var redundantCompletions = 0
    public var coverageSelections = 0, visibleSelections = 0, hiddenSelections = 0, agedSelections = 0
    public var oldestPendingMilliseconds: Double = 0
  }
  /// Immutable tile identities travel with the packed geometry. Another tile
  /// entering the same batch cannot invalidate an unchanged member. UUIDs also
  /// distinguish removal/re-entry and a fresh registry for another planet.
  public struct Preparation: Sendable {
    public let key: WaterBatchKey
    public let revision: UUID
    public let geometry: [TerrainTile: WaterGeometry]
    fileprivate let versions: [TerrainTile: UUID]
    /// Identity of the immutable per-tile input, independent of batch repacking.
    /// A published-source registry uses this only after native adoption succeeds.
    public func version(for tile: TerrainTile) -> UUID? { versions[tile] }
  }
  private var geometry: [TerrainTile: WaterGeometry] = [:]
  private var versions: [TerrainTile: UUID] = [:]
  private var publishedVersions: [TerrainTile: UUID] = [:]
  private var regions: [WaterBatchKey: Set<TerrainTile>] = [:]
  private var queuedAt: [WaterBatchKey: Double] = [:]
  private var servicedAt: [WaterBatchKey: Double] = [:]
  public private(set) var dirty: [WaterBatchKey: UUID] = [:]
  public private(set) var count = 0
  public private(set) var triangleCount = 0
  private var counters = Metrics()
  public let coalescesIdentical: Bool
  public let acceptsPartialCompletions, prioritizesCoverage: Bool
  public init(coalescesIdentical: Bool = true, acceptsPartialCompletions: Bool = true,
    prioritizesCoverage: Bool = true) {
    self.coalescesIdentical = coalescesIdentical
    self.acceptsPartialCompletions = acceptsPartialCompletions
    self.prioritizesCoverage = prioritizesCoverage
  }
  public subscript(_ tile: TerrainTile) -> WaterGeometry? { geometry[tile] }

  /// Compare all static inputs, including topology, depth and river identity /
  /// flow. A repeated plant-detail publication must not supersede a water job
  /// that is already preparing or waiting to upload.
  @discardableResult
  public mutating func install(_ value: WaterGeometry, tile: TerrainTile,
    at time: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
    if coalescesIdentical && geometry[tile] == value {
      counters.identicalUpdates += 1
      return false
    }
    if let old = geometry[tile] { account(old, sign: -1) }
    geometry[tile] = value
    versions[tile] = UUID()
    account(value, sign: 1)
    let key = WaterBatchKey(tile)
    regions[key, default: []].insert(tile)
    dirty[key] = UUID()
    if queuedAt[key] == nil { queuedAt[key] = time }
    counters.geometryUpdates += 1
    return true
  }

  public mutating func remove(_ tile: TerrainTile, at time: Double = ProcessInfo.processInfo.systemUptime) {
    guard let old = geometry.removeValue(forKey: tile) else { return }
    versions[tile] = nil
    publishedVersions[tile] = nil
    account(old, sign: -1)
    let key = WaterBatchKey(tile)
    regions[key]?.remove(tile)
    if regions[key]?.isEmpty == true {
      regions[key] = nil; dirty[key] = nil; queuedAt[key] = nil; servicedAt[key] = nil
    } else {
      dirty[key] = UUID()
      if queuedAt[key] == nil { queuedAt[key] = time }
    }
    counters.removals += 1
  }

  public func snapshot(for key: WaterBatchKey) -> [TerrainTile: WaterGeometry] {
    Dictionary(uniqueKeysWithValues: (regions[key] ?? []).compactMap { tile in
      geometry[tile].map { (tile, $0) }
    })
  }

  /// Capture on the presentation actor, then pack/animate on WaterMeshPreparation.
  /// Servicing one hot region resets its scheduling age without resetting the
  /// age of its pending content, allowing other regions to make progress.
  public mutating func beginPreparation(for key: WaterBatchKey,
    at time: Double = ProcessInfo.processInfo.systemUptime) -> Preparation? {
    guard let revision = dirty[key], let tiles = regions[key], !tiles.isEmpty else { return nil }
    servicedAt[key] = time; counters.preparations += 1
    return .init(key: key, revision: revision, geometry: snapshot(for: key),
      versions: Dictionary(uniqueKeysWithValues: tiles.compactMap { tile in versions[tile].map { (tile, $0) } }))
  }

  public func publishableTiles(in input: Preparation) -> Set<TerrainTile> {
    guard dirty[input.key] != nil else { return [] }
    if !acceptsPartialCompletions && dirty[input.key] != input.revision { return [] }
    let valid = Set(input.versions.compactMap { tile, version in versions[tile] == version ? tile : nil })
    // Constant edits to one member must not upload the same unaffected members
    // again on every completion. A current complete batch can still compact its
    // existing owners together after removals or other membership changes.
    if dirty[input.key] != input.revision,
      !valid.contains(where: { publishedVersions[$0] != input.versions[$0] }) { return [] }
    return valid
  }

  /// Call only after native resource creation succeeds, using exactly the tiles
  /// assigned to that resource. A superseded batch can publish unchanged parts,
  /// but cannot clear the newer batch's dirty revision. Failure leaves it queued.
  @discardableResult
  public mutating func acknowledge(_ input: Preparation, published: Set<TerrainTile>) -> Bool {
    let accepted = published.intersection(publishableTiles(in: input))
    if accepted.isEmpty && acceptsPartialCompletions && dirty[input.key] != input.revision {
      let valid = input.versions.filter { versions[$0.key] == $0.value }
      if !valid.isEmpty && valid.allSatisfy({ publishedVersions[$0.key] == $0.value }) {
        counters.redundantCompletions += 1
      }
    }
    counters.acceptedTiles += accepted.count
    counters.discardedTiles += input.geometry.count - accepted.count
    if accepted.isEmpty { counters.discardedCompletions += 1 }
    else if dirty[input.key] != input.revision { counters.salvagedCompletions += 1 }
    for tile in accepted { publishedVersions[tile] = input.versions[tile] }
    guard accepted.count == input.geometry.count else { return false }
    return acknowledge(input.key, revision: input.revision)
  }

  /// Missing visible coverage first, then visible replacements, then hidden
  /// preparation. After two seconds without service, oldest service time wins.
  /// New arrivals/edits cannot continually reset an existing region's age.
  /// This controls job order only; existing water stays visible until its whole
  /// replacement group is available, including dry tiles.
  public mutating func nextBatch(visible: Set<TerrainTile>, covered: Set<TerrainTile>,
    eye: SIMD3<Float>, at time: Double = ProcessInfo.processInfo.systemUptime) -> WaterBatchKey? {
    guard !dirty.isEmpty else { return nil }
    let coverage = TerrainOverlapIndex(covered)
    func fullyCovered(_ tile: TerrainTile) -> Bool {
      let overlaps = coverage.overlapping(tile)
      if overlaps.contains(where: { $0.size >= tile.size }) { return true }
      guard !overlaps.isEmpty, tile.size > 1 else { return false }
      let half = tile.size / 2
      for dz in [0, half] { for dx in [0, half] {
        if !fullyCovered(.init(x: tile.x + dx, z: tile.z + dz, size: half)) { return false }
      } }
      return true
    }
    struct Candidate {
      let key: WaterBatchKey
      let service: Int
      let lastService: Double
      let aged: Bool
      let score, distance: Float
    }
    func candidate(_ key: WaterBatchKey) -> Candidate {
      let eligible = (regions[key] ?? []).intersection(visible)
      let missing = eligible.filter { !fullyCovered($0) }
      let service = !missing.isEmpty ? 0 : !eligible.isEmpty ? 1 : 2
      let age = servicedAt[key] ?? queuedAt[key] ?? time
      let delta = key.center - SIMD3<Float>(eye.x, 0, eye.z)
      let distance = delta.x * delta.x + delta.z * delta.z
      let finiteDistance = distance.isFinite ? distance : 0
      var score = finiteDistance
      if service == 0 {
        score = missing.map { tile in
          let p = tile.center - SIMD3<Float>(eye.x, 0, eye.z)
          let d = (p.x * p.x + p.z * p.z) / Float(tile.size * tile.size)
          return d.isFinite ? d : 0
        }.min() ?? score
      }
      return .init(key: key, service: service, lastService: age,
        aged: time - age >= 2, score: score, distance: finiteDistance)
    }
    func precedes(_ a: Candidate, _ b: Candidate) -> Bool {
      if prioritizesCoverage {
        if a.aged != b.aged { return a.aged }
        if a.aged && a.lastService != b.lastService { return a.lastService < b.lastService }
        if a.service != b.service { return a.service < b.service }
        if a.score != b.score { return a.score < b.score }
      } else if a.distance != b.distance { return a.distance < b.distance }
      return (a.key.size, a.key.z, a.key.x) < (b.key.size, b.key.z, b.key.x)
    }
    var best: Candidate?
    for key in dirty.keys {
      let item = candidate(key)
      if best == nil || precedes(item, best!) { best = item }
    }
    guard let best else { return nil }
    if prioritizesCoverage && best.aged { counters.agedSelections += 1 }
    switch best.service {
    case 0: counters.coverageSelections += 1
    case 1: counters.visibleSelections += 1
    default: counters.hiddenSelections += 1
    }
    return best.key
  }

  /// An obsolete completion must never acknowledge a later edit or re-entry.
  @discardableResult
  public mutating func acknowledge(_ key: WaterBatchKey, revision: UUID) -> Bool {
    guard dirty[key] == revision else { return false }
    for tile in regions[key] ?? [] { publishedVersions[tile] = versions[tile] }
    dirty[key] = nil
    queuedAt[key] = nil; servicedAt[key] = nil
    return true
  }

  public var metrics: Metrics {
    metrics(at: ProcessInfo.processInfo.systemUptime)
  }
  public func metrics(at time: Double) -> Metrics {
    var result = counters
    result.coalescesIdentical = coalescesIdentical
    result.acceptsPartialCompletions = acceptsPartialCompletions
    result.prioritizesCoverage = prioritizesCoverage
    result.requestedTiles = geometry.count; result.pendingBatches = dirty.count
    if let oldest = queuedAt.values.min() { result.oldestPendingMilliseconds = max(0, time - oldest) * 1_000 }
    return result
  }

  private mutating func account(_ value: WaterGeometry, sign: Int) {
    triangleCount += sign * (value.shallowIndices.count + value.deepIndices.count) / 3
    if !value.isEmpty { count += sign }
  }
}
