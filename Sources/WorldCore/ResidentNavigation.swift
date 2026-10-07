import Foundation

/// Bounded A* over walkable cells. Collision/route feasibility stays local even
/// when Jev chooses the destination. Callers amortize a few replans per tick.
public enum ResidentNavigation {
  public static let radius: Float = 0.62
  public static let height: Float = 3.65
  /// Preserve sub-voxel X/Z for steering while checking the whole body against
  /// walls. A clear centre cell alone lets sidestepping actors clip corners.
  public static func clear(at feet: SIMD3<Float>, block: (BlockPosition) -> Block) -> Bool {
    let lo = feet + [-radius, 0.015, -radius], hi = feet + [radius, height, radius]
    let low = BlockPosition(lo), high = BlockPosition(hi - SIMD3<Float>(repeating: 0.001))
    for x in low.x...high.x { for z in low.z...high.z { for y in low.y...high.y {
      let cell = BlockPosition(x,y,z), material = block(cell)
      if material.isLiquid { return false }
      guard material.isSolid else { continue }
      let origin = SIMD3<Float>(Float(x),Float(y),Float(z))
      for box in material.collisionBoxes {
        let a = origin + box.center - box.size/2, b = origin + box.center + box.size/2
        if lo.x < b.x && hi.x > a.x && lo.y < b.y && hi.y > a.y && lo.z < b.z && hi.z > a.z { return false }
      }
    } } }
    return true
  }
  public static func walkingPosition(at point: SIMD3<Float>, block: (BlockPosition) -> Block) -> SIMD3<Float>? {
    guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return nil }
    // Half steps follow the actual stair collision boxes. Never snap X/Z back
    // to a cell centre: a one-metre doorway needs its full usable width.
    let base = floor((point.y+0.04)*2)/2
    for dy: Float in [0,0.5,1,-0.5,-1] {
      let feet = SIMD3<Float>(point.x,base+dy,point.z)
      guard abs(feet.y-point.y)<1.06, clear(at:feet,block:block) else { continue }
      var supported = false
      for d: SIMD2<Float> in [[0,0],[-radius*0.75,0],[radius*0.75,0],[0,-radius*0.75],[0,radius*0.75]] {
        let probe=feet+[d.x,-0.025,d.y], cell=BlockPosition(probe), material=block(cell)
        guard material.isSolid else { continue }
        let local=probe-SIMD3<Float>(Float(cell.x),Float(cell.y),Float(cell.z))
        if material.collisionBoxes.contains(where:{ box in
          let a=box.center-box.size/2,b=box.center+box.size/2
          return local.x>=a.x && local.x<b.x && local.z>=a.z && local.z<b.z && local.y>=a.y && local.y<b.y
        }) { supported=true; break }
      }
      if supported { return feet }
    }
    return nil
  }
  public static func standing(at point: SIMD3<Float>, block: (BlockPosition) -> Block) -> SIMD3<Float>? {
    let cell=BlockPosition(point), center=SIMD3<Float>(Float(cell.x)+0.5,point.y,Float(cell.z)+0.5)
    for d: SIMD3<Float> in [.zero,[0.25,0,0],[-0.25,0,0],[0,0,0.25],[0,0,-0.25],
      [0.25,0,0.25],[-0.25,0,0.25],[0.25,0,-0.25],[-0.25,0,-0.25]] {
      if let feet=walkingPosition(at:center+d,block:block) { return feet }
    }
    return nil
  }

  /// A resident occupies a full body volume, and every cell must contain water.
  /// This also prevents swimming through windows, above the surface or into lava.
  public static func swimPosition(at point: SIMD3<Float>, block: (BlockPosition) -> Block) -> SIMD3<Float>? {
    let low = BlockPosition(point + [-radius, 0.05, -radius])
    let high = BlockPosition(point + [radius, height, radius])
    for x in low.x...high.x { for y in low.y...high.y { for z in low.z...high.z {
      guard block(.init(x, y, z)) == .water else { return nil }
    } } }
    return point
  }

  public static func path(from start: SIMD3<Float>, to target: SIMD3<Float>,
    maximumVisited: Int = 512, swimming: Bool = false, avoiding: Set<BlockPosition> = [],
    block: (BlockPosition) -> Block) -> [SIMD3<Float>] {
    func navigable(_ point: SIMD3<Float>) -> SIMD3<Float>? {
      swimming ? swimPosition(at: point, block: block) : standing(at: point, block: block)
    }
    guard maximumVisited > 0, let destination = navigable(target),
      let origin = navigable(start) else { return [] }
    let first = BlockPosition(origin), goal = BlockPosition(destination)
    if first == goal { return [] }
    func heuristic(_ p: BlockPosition) -> Int { abs(p.x - goal.x) + abs(p.z - goal.z) + abs(p.y - goal.y) * (swimming ? 2 : 1) }
    struct Node { let cell: BlockPosition; let cost: Int; let estimate: Int }
    var open = [Node(cell: first, cost: 0, estimate: heuristic(first))]
    var costs = [first: 0]
    var parent: [BlockPosition: BlockPosition] = [:]
    var positions: [BlockPosition: SIMD3<Float>] = [first:origin]
    var visited = Set<BlockPosition>()
    var closest = first
    let neighbors = [BlockPosition(1, 0, 0), .init(-1, 0, 0), .init(0, 0, 1), .init(0, 0, -1)]
      + (swimming ? [.init(0, 1, 0), .init(0, -1, 0)] : [])
    while !open.isEmpty && visited.count < maximumVisited {
      let index = open.indices.min {
        open[$0].estimate == open[$1].estimate ? open[$0].cost > open[$1].cost
          : open[$0].estimate < open[$1].estimate
      }!
      let node = open.remove(at: index)
      if visited.contains(node.cell) { continue }
      visited.insert(node.cell)
      if heuristic(node.cell) < heuristic(closest) { closest = node.cell }
      if node.cell == goal { closest = goal; break }
      for delta in neighbors {
        let candidate = node.cell + delta
        guard let step = navigable([Float(candidate.x) + 0.5, Float(candidate.y), Float(candidate.z) + 0.5]) else { continue }
        let next = BlockPosition(step)
        guard !avoiding.contains(next) else { continue }
        let cost = node.cost + 1 + abs(next.y - node.cell.y)
        if !visited.contains(next) && cost < costs[next, default: .max] {
          costs[next] = cost; parent[next] = node.cell; positions[next] = step
          open.append(.init(cell: next, cost: cost, estimate: cost + heuristic(next)))
        }
      }
    }
    // Partial routes make progress toward distant destinations without an
    // unbounded search. Replan when this segment finishes.
    var route: [SIMD3<Float>] = []
    var current = closest
    while current != first, let previous = parent[current] {
      if let point=positions[current] { route.append(point) }
      current = previous
    }
    return route.reversed()
  }
}
