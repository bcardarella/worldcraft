/// A renderable frontier between bootstrap coverage and the user's final LOD
/// plan. Every replacement is a small complete group, never an entire horizon's
/// descendants. Final detail and draw distances are unchanged.
public struct ProgressiveTerrainPlan: Sendable {
  public let tiles: Set<TerrainTile>
  public init(target: Set<TerrainTile>, visible: Set<TerrainTile>, center: ChunkCoordinate,
    maximumReplacementTiles: Int = 16) {
    self.init(target: ProgressiveTerrainTarget(target), visible: visible, center: center,
      maximumReplacementTiles: min(16, max(4, maximumReplacementTiles)))
  }
  fileprivate init(target prepared: ProgressiveTerrainTarget, visible: Set<TerrainTile>,
    center: ChunkCoordinate, maximumReplacementTiles: Int) {
    let target = prepared.tiles, targetIndex = prepared.index
    let visibleIndex = TerrainOverlapIndex(visible)
    var next: Set<TerrainTile> = []
    func children(_ tile: TerrainTile) -> [TerrainTile] {
      let half = tile.size / 2
      return [TerrainTile(x: tile.x, z: tile.z, size: half),
        .init(x: tile.x + half, z: tile.z, size: half),
        .init(x: tile.x, z: tile.z + half, size: half),
        .init(x: tile.x + half, z: tile.z + half, size: half)]
    }
    func visit(_ tile: TerrainTile) {
      let final = targetIndex.overlapping(tile)
      guard !final.isEmpty else { return }
      if target.contains(tile) { next.insert(tile); return }
      if tile.size == 1 { next.formUnion(final); return }
      if visible.contains(tile) {
        // A 4x4 region can go straight to its sixteen final leaves instead of
        // uploading four temporary 2x2 meshes first. Keep smaller groups in the
        // immediate collision neighbourhood; larger groups stay bounded, and
        // TerrainCoverage retains the old parent until every child is ready.
        let limit = tile.distanceSquared(to: center) <= 4
          ? min(8, maximumReplacementTiles) : maximumReplacementTiles
        if final.count <= limit { next.formUnion(final) }
        else {
          for child in children(tile) where targetIndex.containsOverlap(with: child) {
            if child.size == 1 { next.formUnion(targetIndex.overlapping(child)) }
            else { next.insert(child) }
          }
        }
      } else if visibleIndex.containsOverlap(with: tile) || tile.distanceSquared(to: center) <= 4 {
        // Preserve existing finer coverage; bootstrap the immediate collision
        // neighbourhood directly instead of hiding it behind a giant parent.
        for child in children(tile) { visit(child) }
      } else {
        next.insert(tile)
      }
    }
    for root in prepared.roots { visit(root) }
    tiles = next
  }
}

/// Only immutable geometric demand is retained. Published/visible ownership is
/// read afresh on every plan, so partial groups, edits and failures cannot be
/// hidden behind a cached output. One target replaces the previous target.
fileprivate struct ProgressiveTerrainTarget: Sendable {
  let tiles: Set<TerrainTile>
  let index: TerrainOverlapIndex
  let roots: Set<TerrainTile>
  init(_ tiles: Set<TerrainTile>) {
    self.tiles = tiles
    index = .init(tiles)
    roots = Set(tiles.map {
      TerrainTile(x: floorDivide($0.x, by: 32) * 32,
        z: floorDivide($0.z, by: 32) * 32, size: 32)
    })
  }
}

/// Renderer-owned reuse of target indexing during progressive publication.
/// Target equality includes full/surface ownership, not just spatial extents.
public struct ProgressiveTerrainPlanner: Sendable {
  public struct Metrics: Sendable, Encodable {
    public let enabled: Bool
    public let maximumReplacementTiles: Int
    public let appliedReplacementTiles: Int
    public let initialRefinement: Bool
    public let targetTiles, roots, builds, reuses: Int
  }
  public let enabled: Bool
  public let maximumReplacementTiles: Int
  private var prepared: ProgressiveTerrainTarget?
  private var initialTarget: Set<TerrainTile>?
  private var initialRefinement = true
  private var builds = 0, reuses = 0
  public init(enabled: Bool = true, maximumReplacementTiles: Int = 16) {
    self.enabled = enabled
    self.maximumReplacementTiles = min(16, max(4, maximumReplacementTiles))
  }
  public var metrics: Metrics {
    .init(enabled: enabled, maximumReplacementTiles: maximumReplacementTiles,
      appliedReplacementTiles: replacementLimit, initialRefinement: initialRefinement,
      targetTiles: prepared?.tiles.count ?? 0,
      roots: prepared?.roots.count ?? 0, builds: builds, reuses: reuses)
  }
  public mutating func plan(target: Set<TerrainTile>, visible: Set<TerrainTile>,
    center: ChunkCoordinate) -> ProgressiveTerrainPlan {
    // Large groups save temporary uploads during an unchanged entry demand.
    // Once travel/settings change that demand, keep smaller groups for the
    // remainder of the world visit: cached arrivals must not wait on 15 peers.
    // Stopping or reversing does not restart initial refinement or churn groups.
    if initialRefinement {
      if (initialTarget != nil && initialTarget != target) || visible == target {
        initialRefinement = false; initialTarget = nil
      } else if initialTarget == nil { initialTarget = target }
    }
    if enabled, let prepared, prepared.tiles == target {
      reuses += 1
      return .init(target: prepared, visible: visible, center: center,
        maximumReplacementTiles: replacementLimit)
    }
    let next = ProgressiveTerrainTarget(target)
    builds += 1
    prepared = enabled ? next : nil
    return .init(target: next, visible: visible, center: center,
      maximumReplacementTiles: replacementLimit)
  }
  private var replacementLimit: Int { initialRefinement ? maximumReplacementTiles : min(8, maximumReplacementTiles) }
  public mutating func reset() {
    prepared = nil; initialTarget = nil; initialRefinement = true
    builds = 0; reuses = 0
  }
}

/// CPU-side spatial coverage, not a claim that a frame reached the display.
/// Circle-clipped chunk area avoids treating a tiny leaf like a 256 m tile.
public struct TerrainCoverageMetrics: Sendable, Encodable {
  public let coveredPercent: Double
  public let minimumQuadrantPercent: Double
  public let requestedDetailPercent: Double
  public let requestedChunks: Int
  public let visibleChunks: Int

  public init(center: ChunkCoordinate, radius: Int, target: Set<TerrainTile>, visible: Set<TerrainTile>) {
    let radius = max(1, radius)
    var requested = [Int](repeating: 0, count: 4)
    var covered = [Int](repeating: 0, count: 4)
    func area(_ tile: TerrainTile, into counts: inout [Int]) {
      for z in max(tile.z, center.z - radius)...min(tile.z + tile.size - 1, center.z + radius) {
        let dz = z - center.z
        let reach = Int(Double(max(0, radius * radius - dz * dz)).squareRoot())
        let low = max(tile.x, center.x - reach)
        let high = min(tile.x + tile.size - 1, center.x + reach)
        guard low <= high else { continue }
        let row = dz < 0 ? 0 : 2
        counts[row] += max(0, min(high, center.x - 1) - low + 1)
        counts[row + 1] += max(0, high - max(low, center.x) + 1)
      }
    }
    // Requested cells are counted once without dependence on the target's LOD.
    for dz in -radius...radius {
      let reach = Int(Double(radius * radius - dz * dz).squareRoot())
      let row = dz < 0 ? 0 : 2
      requested[row] += reach; requested[row + 1] += reach + 1
    }
    for tile in visible where tile.z <= center.z + radius && tile.z + tile.size > center.z - radius {
      area(tile, into: &covered)
    }
    requestedChunks = requested.reduce(0, +)
    visibleChunks = covered.reduce(0, +)
    coveredPercent = 100 * Double(visibleChunks) / Double(max(1, requestedChunks))
    minimumQuadrantPercent = zip(covered, requested).map { 100 * Double($0) / Double(max(1, $1)) }.min() ?? 0
    let detail = target.filter(\.fullDetail)
    requestedDetailPercent = detail.isEmpty ? 100 : 100 * Double(detail.intersection(visible).count) / Double(detail.count)
  }
}
