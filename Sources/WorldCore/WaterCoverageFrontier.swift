/// Bounded selection for a detailed water footprint meeting retained coarse
/// water. This resolves occupancy discontinuities, not tide/shore burial or
/// submerged volumes, and does not authorize publishing terrain or water.
public enum WaterCoverageFrontier {
  public typealias Point = WaterSurfaceRefinement.Point
  public typealias Cell = WaterSurfaceRefinement.Cell
  public typealias CellKey = WaterSurfaceRefinement.CellKey

  public struct Limits: Sendable {
    public let cells, columns: Int
    public init(cells: Int = 4_096, columns: Int = 65_536) {
      precondition(cells >= 0 && columns >= 0)
      self.cells = cells; self.columns = columns
    }
  }
  public struct Result: Sendable {
    /// Whole cells to refine together. All other source footprints are retained.
    public let refining: Set<CellKey>
    public let sourceCells, sampledColumns, expansionTriggers, boundaryChecks: Int
  }
  public enum Outcome: Sendable {
    case ready(Result)
    case missingSource(Point)
    case missingOccupancy(Point)
    case invalidSource
    case limitExceeded
    case cancelled
  }

  /// Both callbacks must read one immutable snapshot and the same occupancy
  /// convention used for subsequent topology. A source cell with nil corners
  /// is known absent water, not missing input. Only mismatched one-sided edges
  /// query the retained side's occupancy; matching retained coverage stays put.
  /// Natural wet/dry edges stop expansion. Unknown input and exhausted limits
  /// reject the entire selection; an unfinished frontier is never called ready.
  /// `inspecting` may include cells changed only to share wave vertices. Their
  /// outer one-sided edges need the same check. After topology construction,
  /// inspect its complete replacement set and rebuild if selection grows;
  /// bound that outer iteration too and never publish an intermediate result.
  public static func select(refining columns: [Point], inspecting: Set<CellKey> = [], limits: Limits = .init(),
    source: (Point) -> Cell?, occupancy: (Point) -> Bool?) -> Outcome {
    if Task.isCancelled { return .cancelled }
    var cells: [CellKey: Cell] = [:], ancestors = Set<CellKey>()
    var values: [Point: Bool] = [:], selected = Set<CellKey>(), pending: [CellKey] = []
    var failure: Outcome?
    func fetch(_ p: Point) -> Cell? {
      let supplied = source(p)
      guard !Task.isCancelled else { failure = .cancelled; return nil }
      guard let cell = supplied else { failure = .missingSource(p); return nil }
      guard cell.valid, cell.key.contains(p) else { failure = .invalidSource; return nil }
      if let held = cells[cell.key] {
        guard held.corners == cell.corners, held.shallow == cell.shallow else {
          failure = .invalidSource; return nil
        }
      } else {
        guard cells.count < limits.cells else { failure = .limitExceeded; return nil }
        guard !ancestors.contains(cell.key) else { failure = .invalidSource; return nil }
        var parents: [CellKey] = [], size = cell.key.size * 2
        while size <= 64 {
          let parent = CellKey(x: floorDivide(cell.key.x,by:size)*size,
            z: floorDivide(cell.key.z,by:size)*size, size:size)
          guard cells[parent] == nil else { failure = .invalidSource; return nil }
          parents.append(parent); size *= 2
        }
        ancestors.formUnion(parents); cells[cell.key] = cell
      }
      return cell
    }
    func wet(_ p: Point) -> Bool? {
      if let held = values[p] { return held }
      guard values.count < limits.columns else { failure = .limitExceeded; return nil }
      let supplied = occupancy(p)
      guard !Task.isCancelled else { failure = .cancelled; return nil }
      guard let value = supplied else { failure = .missingOccupancy(p); return nil }
      values[p] = value; return value
    }
    for p in columns.sorted(by: { ($0.z,$0.x)<($1.z,$1.x) }) {
      if Task.isCancelled { return .cancelled }
      guard let cell = fetch(p) else { return failure! }
      selected.insert(cell.key)
    }
    var triggers = 0, checks = 0
    // A retained cell receiving new edge vertices can expose an existing bad
    // footprint on one of its other edges. Check all replacement boundaries,
    // while allowing correctly retained full-water regions to stay coarse.
    for key in inspecting.sorted(by: { ($0.z,$0.x,$0.size)<($1.z,$1.x,$1.size) }) {
      if Task.isCancelled { return .cancelled }
      guard key.valid else { return .invalidSource }
      guard let cell = fetch(.init(key.x,key.z)) else { return failure! }
      guard cell.key == key else { return .invalidSource }
      for i in 0..<key.size {
        let edges: [(Point, Point)] = [
          (.init(key.x,key.z+i), .init(key.x-1,key.z+i)),
          (.init(key.x+key.size-1,key.z+i), .init(key.x+key.size,key.z+i)),
          (.init(key.x+i,key.z), .init(key.x+i,key.z-1)),
          (.init(key.x+i,key.z+key.size-1), .init(key.x+i,key.z+key.size)),
        ]
        for (a,b) in edges {
          guard let first = fetch(a), let second = fetch(b) else { return failure! }
          let drawnA: Bool, drawnB: Bool
          if selected.contains(first.key) {
            guard let actual = wet(a) else { return failure! }; drawnA = actual
          } else { drawnA = first.corners != nil }
          if selected.contains(second.key) {
            guard let actual = wet(b) else { return failure! }; drawnB = actual
          } else { drawnB = second.corners != nil }
          checks += 1
          guard drawnA != drawnB else { continue }
          guard let actualA = wet(a), let actualB = wet(b) else { return failure! }
          for (candidate,drawn,actual) in [(first,drawnA,actualA),(second,drawnB,actualB)] where drawn != actual {
            if selected.insert(candidate.key).inserted { triggers += 1 }
          }
        }
      }
    }
    pending = selected.sorted { ($0.z,$0.x,$0.size)<($1.z,$1.x,$1.size) }
    var cursor = 0
    while cursor < pending.count {
      if Task.isCancelled { return .cancelled }
      let key = pending[cursor]; cursor += 1
      // Full-cell ownership is deliberate: the topology builder replaces whole
      // source quads, so surveying only the triggering edge would omit holes or
      // disconnected wet portions inside the newly selected cell.
      for z in key.z..<(key.z+key.size) { for x in key.x..<(key.x+key.size) {
        if Task.isCancelled { return .cancelled }
        let p = Point(x,z)
        guard let cell = fetch(p) else { return failure! }
        guard cell.key == key else { return .invalidSource }
        guard wet(p) != nil else { return failure! }
      }}
      for i in 0..<key.size {
        if Task.isCancelled { return .cancelled }
        let edges: [(Point, Point)] = [
          (.init(key.x,key.z+i), .init(key.x-1,key.z+i)),
          (.init(key.x+key.size-1,key.z+i), .init(key.x+key.size,key.z+i)),
          (.init(key.x+i,key.z), .init(key.x+i,key.z-1)),
          (.init(key.x+i,key.z+key.size-1), .init(key.x+i,key.z+key.size)),
        ]
        for (inner,outer) in edges {
          guard let neighbor = fetch(outer) else { return failure! }
          guard !selected.contains(neighbor.key) else { continue }
          checks += 1
          let retainedWet = neighbor.corners != nil
          guard values[inner]! != retainedWet else { continue }
          guard let actualWet = wet(outer) else { return failure! }
          guard actualWet != retainedWet else { continue } // A natural shoreline.
          selected.insert(neighbor.key); pending.append(neighbor.key); triggers += 1
        }
      }
    }
    if Task.isCancelled { return .cancelled }
    return .ready(.init(refining:selected, sourceCells:cells.count,
      sampledColumns:values.count, expansionTriggers:triggers, boundaryChecks:checks))
  }
}
