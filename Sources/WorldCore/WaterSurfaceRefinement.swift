/// Conforming water topology for an immutable preparation snapshot. Refined
/// cells use unit columns; their incident coarse triangles receive the same
/// edge vertices and wave inputs. This is not a publication/shoreline policy.
public enum WaterSurfaceRefinement {
  public struct Point: Hashable, Sendable {
    public let x, z: Int
    public init(_ x: Int, _ z: Int) { self.x = x; self.z = z }
  }
  public struct CellKey: Hashable, Sendable {
    public let x, z, size: Int
    public init(x: Int, z: Int, size: Int) { self.x = x; self.z = z; self.size = size }
    var valid: Bool {
      size > 0 && size <= 64 && size.nonzeroBitCount == 1
        && x % size == 0 && z % size == 0
        && x > Int.min + 64 && z > Int.min + 64
        && x < Int.max - 64 && z < Int.max - 64
    }
    func contains(_ p: Point) -> Bool { p.x >= x && p.x < x + size && p.z >= z && p.z < z + size }
    var corners: [Point] { [.init(x,z), .init(x,z+size), .init(x+size,z), .init(x+size,z+size)] }
    func boundaryContains(_ p: Point) -> Bool {
      p.x >= x && p.x <= x+size && p.z >= z && p.z <= z+size
        && (p.x == x || p.x == x+size || p.z == z || p.z == z+size)
    }
  }
  public struct Sample: Equatable, Sendable {
    public let depth: Float
    public let body: WaterBody
    /// Wetness of the unit column whose northwest corner is this vertex.
    /// Dry rim vertices still need deterministic body/depth wave inputs.
    public let wet: Bool
    public init(depth: Float, body: WaterBody, wet: Bool) {
      self.depth = depth; self.body = body; self.wet = wet
    }
    var valid: Bool {
      depth.isFinite && depth >= 0 && body.level.isFinite
        && body.current.x.isFinite && body.current.y.isFinite && body.current.z.isFinite
    }
  }
  public struct Cell: Sendable {
    public let key: CellKey
    /// Original NW, SW, NE, SE vertex inputs; nil means no original water quad.
    /// Retained triangles preserve this diagonal and their original depth band.
    public let corners: [Sample]?
    public let shallow: Bool
    public init(key: CellKey, corners: [Sample]?, shallow: Bool) {
      self.key = key; self.corners = corners; self.shallow = shallow
    }
    var valid: Bool { key.valid && (corners == nil || (corners!.count == 4 && corners!.allSatisfy(\.valid))) }
  }
  public struct Limits: Sendable {
    public let cells, columns, samples, vertices, indices: Int
    public init(cells: Int = 4_096, columns: Int = 65_536, samples: Int = 65_536,
      vertices: Int = 262_144, indices: Int = 1_572_864) {
      precondition(cells >= 0 && columns >= 0 && samples >= 0 && vertices >= 0 && indices >= 0)
      self.cells = cells; self.columns = columns; self.samples = samples
      self.vertices = vertices; self.indices = indices
    }
  }
  public struct Result: Sendable {
    /// Replace these whole source cells together, including empty replacements.
    /// Unlisted cells remain byte-for-byte owned by their original water mesh.
    public let geometry: [CellKey: WaterGeometry]
    public let refined: Set<CellKey>
    public let sourceCells, surveyedColumns, sampledPoints, vertexCount, indexCount: Int
  }
  public enum Outcome: Sendable {
    case ready(Result)
    case missingSource(Point)
    case missingOccupancy(Point)
    case missingSample(Point)
    case invalidSource
    case invalidSample(Point)
    case limitExceeded
    case cancelled
  }

  /// `source` must partition the requested region with aligned grid cells.
  /// Both callbacks must read the same immutable world/edit snapshot. Querying
  /// an incident dry cell is necessary too: absence cannot mean unknown water.
  /// All results are transactional; cancellation, missing input or exhausted
  /// limits returns no partial geometry. Count limits are not wall-time budgets.
  /// A ready result proves topology construction only. The caller must verify
  /// fluid coverage/shorelines, source revision, bounds and coordinated publish.
  public static func build(refining columns: [Point], limits: Limits = .init(),
    source: (Point) -> Cell?, sample: (Point) -> Sample?) -> Outcome {
    // Compatibility for callers with a combined column/vertex lookup. Cache
    // its bounded union of surveyed columns and required vertices, so a wet
    // column used as a vertex does not repeat an expensive world query.
    var cached: [Point: Sample] = [:]
    func lookup(_ p: Point) -> Sample? {
      if let held = cached[p] { return held }
      guard let value = sample(p) else { return nil }
      cached[p] = value; return value
    }
    return buildTopology(refining: columns, limits: limits, source: source, occupancy: { p in
      guard let value = lookup(p) else { return .failed(.missingSample(p)) }
      guard value.valid else { return .failed(.invalidSample(p)) }
      return .known(value.wet)
    }, sample: lookup)
  }

  /// Column occupancy is independent of vertex wave data. `false` means a
  /// known dry unit column; nil means unavailable input and rejects the whole
  /// transaction. Wave samples are requested only for vertices used by refined
  /// water or the retained wet triangles needed to make its boundary conform.
  /// The sample's `wet` member is ignored by this overload. All three callbacks
  /// must describe the same immutable snapshot; missing data is never dry land.
  public static func build(refining columns: [Point], limits: Limits = .init(),
    source: (Point) -> Cell?, occupancy: (Point) -> Bool?, sample: (Point) -> Sample?) -> Outcome {
    buildTopology(refining: columns, limits: limits, source: source, occupancy: { p in
      guard let wet = occupancy(p) else { return .failed(.missingOccupancy(p)) }
      return .known(wet)
    }, sample: sample)
  }

  private enum ColumnInput { case known(Bool), failed(Outcome) }

  private static func buildTopology(refining columns: [Point], limits: Limits,
    source: (Point) -> Cell?, occupancy: (Point) -> ColumnInput,
    sample: (Point) -> Sample?) -> Outcome {
    if Task.isCancelled { return .cancelled }
    var cells: [CellKey: Cell] = [:], refined = Set<CellKey>()
    var ancestors = Set<CellKey>()
    var failure: Outcome?
    func fetch(_ p: Point) -> Cell? {
      let supplied = source(p)
      guard !Task.isCancelled else { failure = .cancelled; return nil }
      guard let cell = supplied else { failure = .missingSource(p); return nil }
      guard cell.valid, cell.key.contains(p) else { failure = .invalidSource; return nil }
      if let previous = cells[cell.key] {
        guard previous.corners == cell.corners && previous.shallow == cell.shallow else {
          failure = .invalidSource; return nil
        }
      } else {
        guard cells.count < limits.cells else { failure = .limitExceeded; return nil }
        // Aligned power-of-two cells may only overlap by containment. Check
        // both directions without scanning all previously queried cells. This
        // also validates all-dry replacements whose edges need no wave data.
        guard !ancestors.contains(cell.key) else { failure = .invalidSource; return nil }
        var parents: [CellKey] = []
        var size = cell.key.size * 2
        while size <= 64 {
          let parent = CellKey(x: floorDivide(cell.key.x, by: size) * size,
            z: floorDivide(cell.key.z, by: size) * size, size: size)
          guard cells[parent] == nil else { failure = .invalidSource; return nil }
          parents.append(parent); size *= 2
        }
        ancestors.formUnion(parents)
        cells[cell.key] = cell
      }
      return cell
    }
    for p in columns {
      if Task.isCancelled { return .cancelled }
      guard let cell = fetch(p) else { return failure! }
      refined.insert(cell.key)
    }
    let orderedRefined = refined.sorted(by: precedes)
    var wetColumns = Set<Point>(), requiredVertices = Set<Point>(), boundaryVertices = Set<Point>()
    var surveyedColumns = 0
    // Survey only half-open unit columns. The last row/column of vertices has
    // no ownership here, and an entirely dry cell needs no wave samples at all.
    for key in orderedRefined {
      for z in key.z..<(key.z+key.size) {
        for x in key.x..<(key.x+key.size) {
          if Task.isCancelled { return .cancelled }
          guard surveyedColumns < limits.columns else { return .limitExceeded }
          let p = Point(x,z)
          guard let current = fetch(p) else { return failure! }
          guard current.key == key else { return .invalidSource }
          let supplied = occupancy(p)
          if Task.isCancelled { return .cancelled }
          surveyedColumns += 1
          switch supplied {
          case let .failed(reason): return reason
          case .known(false): continue
          case .known(true): wetColumns.insert(p)
          }
          for vertex in [p, .init(x,z+1), .init(x+1,z), .init(x+1,z+1)] {
            requiredVertices.insert(vertex)
            guard requiredVertices.count <= limits.samples else { return .limitExceeded }
            if key.boundaryContains(vertex) { boundaryVertices.insert(vertex) }
          }
        }
      }
    }
    var values: [Point: Sample] = [:], edgePoints: [CellKey: Set<Point>] = [:]
    var replacements = refined, pending: [CellKey] = []
    func value(at p: Point) -> Sample? {
      if let held = values[p] { return held }
      guard values.count < limits.samples else { failure = .limitExceeded; return nil }
      let supplied = sample(p)
      guard !Task.isCancelled else { failure = .cancelled; return nil }
      guard let value = supplied else { failure = .missingSample(p); return nil }
      guard value.valid else { failure = .invalidSample(p); return nil }
      values[p] = value; return value
    }
    func share(_ p: Point) -> Bool {
      guard let canonical = value(at:p) else {return false}
      for dz in [-1,0] {for dx in [-1,0] {
        guard let neighbor = fetch(.init(p.x+dx,p.z+dz)) else {return false}
        guard neighbor.key.boundaryContains(p) else {failure = .invalidSource;return false}
        guard let original = neighbor.corners, !refined.contains(neighbor.key) else {continue}
        edgePoints[neighbor.key,default:[]].insert(p)
        guard !replacements.contains(neighbor.key) else {continue}
        // An unchanged existing endpoint can stay in its current mesh. New
        // edge splits or changed wave inputs require the entire incident cell.
        if let i=neighbor.key.corners.firstIndex(of:p),
          original[i].depth==canonical.depth && original[i].body==canonical.body {continue}
        replacements.insert(neighbor.key);pending.append(neighbor.key)
      }}
      return true
    }
    for p in requiredVertices.sorted(by: pointPrecedes) {
      if Task.isCancelled { return .cancelled }
      guard value(at:p) != nil else {return failure!}
    }
    for p in boundaryVertices.sorted(by: pointPrecedes) {
      if Task.isCancelled { return .cancelled }
      // Every drawn boundary vertex belongs to all incident source cells.
      // Integer probes avoid epsilon/world-float ambiguity at unequal LODs.
      guard share(p) else {return failure!}
    }
    // Include existing finer-cell corners along every replacement boundary.
    // Merely splitting points from the requested patch would leave old LOD
    // T-junctions on the other edges of an incident coarse triangle. Shared
    // canonical inputs may change another incident cell; discover that closure
    // before allocating any output buffers. Dry neighbours provide known
    // absence, not a licence to invent a shoreline outside refined cells.
    var cursor=0
    while cursor<pending.count {
      if Task.isCancelled {return .cancelled}
      let key=pending[cursor];cursor+=1
      var points=Set(key.corners)
      for i in 0..<key.size {
        for p in [Point(key.x-1,key.z+i),.init(key.x+key.size,key.z+i),
          .init(key.x+i,key.z-1),.init(key.x+i,key.z+key.size)] {
          guard let neighbor=fetch(p) else {return failure!}
          // Unit edges of refined cells have already been shared. Empty
          // original neighbours contribute no drawn vertices to constrain.
          guard neighbor.corners != nil, !refined.contains(neighbor.key) else {continue}
          for q in neighbor.key.corners where key.boundaryContains(q) {points.insert(q)}
        }
      }
      for p in points.sorted(by:pointPrecedes) {
        guard share(p) else {return failure!}
      }
    }
    var output: [CellKey: WaterGeometry] = [:], totalVertices = 0, totalIndices = 0
    for key in replacements.sorted(by: precedes) {
      if Task.isCancelled { return .cancelled }
      let cell = cells[key]!
      var mesh = WaterGeometry(), mapping: [Point: UInt32] = [:]
      func append(_ triangle: [Point], shallow: Bool) -> Bool {
        guard totalIndices <= limits.indices - 3 else { failure = .limitExceeded; return false }
        var indices: [UInt32] = []
        for p in triangle {
          if let index = mapping[p] { indices.append(index); continue }
          guard totalVertices < limits.vertices, mesh.samples.count < Int(UInt32.max) else {
            failure = .limitExceeded; return false
          }
          let value: Sample
          if let replacement = values[p] { value = replacement }
          else if let i = key.corners.firstIndex(of: p), let corners = cell.corners { value = corners[i] }
          else { failure = .invalidSource; return false }
          let index = UInt32(mesh.samples.count)
          mesh.samples.append(.init(position: [Float(p.x-key.x),Float(p.z-key.z)], depth: value.depth, body: value.body))
          mapping[p] = index; indices.append(index); totalVertices += 1
        }
        if shallow { mesh.shallowIndices += indices } else { mesh.deepIndices += indices }
        totalIndices += 3
        return true
      }
      if refined.contains(key) {
        for z in key.z..<(key.z+key.size) {
          if Task.isCancelled { return .cancelled }
          for x in key.x..<(key.x+key.size) {
            let a=Point(x,z),b=Point(x,z+1),c=Point(x+1,z),d=Point(x+1,z+1)
            guard wetColumns.contains(a) else { continue }
            guard let value=values[a] else { return .invalidSource }
            guard append([a,b,c],shallow:value.depth<5),append([c,b,d],shallow:value.depth<5) else {return failure!}
          }
        }
      } else if cell.corners != nil {
        let corners=key.corners, extra=edgePoints[key] ?? []
        for triangle in [[corners[0],corners[1],corners[2]],[corners[2],corners[1],corners[3]]] {
          var polygon: [Point] = []
          for i in 0..<3 {
            let a=triangle[i],b=triangle[(i+1)%3]
            polygon.append(a)
            let interior=extra.filter {$0 != a && $0 != b && onSegment($0,a,b)}.sorted {
              (abs($0.x-a.x)+abs($0.z-a.z)) < (abs($1.x-a.x)+abs($1.z-a.z))
            }
            polygon += interior
          }
          guard let triangles=triangulate(polygon) else {return Task.isCancelled ? .cancelled:.invalidSource}
          for triangle in triangles {if !append(triangle,shallow:cell.shallow) {return failure!}}
        }
      }
      output[key]=mesh
    }
    if Task.isCancelled { return .cancelled }
    return .ready(.init(geometry:output,refined:refined,sourceCells:cells.count,
      surveyedColumns:surveyedColumns,sampledPoints:values.count,
      vertexCount:totalVertices,indexCount:totalIndices))
  }
  private static func pointPrecedes(_ a: Point, _ b: Point) -> Bool { (a.z,a.x)<(b.z,b.x) }
  private static func precedes(_ a: CellKey, _ b: CellKey) -> Bool { (a.z,a.x,a.size)<(b.z,b.x,b.size) }
  private static func cross(_ a: Point, _ b: Point, _ c: Point) -> Int {
    (b.x-a.x)*(c.z-a.z)-(b.z-a.z)*(c.x-a.x)
  }
  private static func onSegment(_ p: Point, _ a: Point, _ b: Point) -> Bool {
    cross(a,b,p)==0 && p.x>=min(a.x,b.x) && p.x<=max(a.x,b.x)
      && p.z>=min(a.z,b.z) && p.z<=max(a.z,b.z)
  }
  /// Convex clockwise boundary, including collinear constrained edge points.
  /// Do not clip an ear whose diagonal skips one of those points: that would
  /// reintroduce a T-junction even though the triangle areas still match.
  private static func triangulate(_ boundary: [Point]) -> [[Point]]? {
    var polygon=boundary, result:[[Point]]=[]
    while polygon.count>3 {
      if Task.isCancelled { return nil }
      var removed=false
      for i in polygon.indices {
        let before=(i+polygon.count-1)%polygon.count,after=(i+1)%polygon.count
        let a=polygon[before],b=polygon[i],c=polygon[after]
        guard cross(a,b,c)<0 else {continue}
        if polygon.indices.contains(where: {$0 != before && $0 != i && $0 != after && onSegment(polygon[$0],a,c)}) {continue}
        result.append([a,b,c]);polygon.remove(at:i);removed=true;break
      }
      if !removed {return nil}
    }
    guard polygon.count==3,cross(polygon[0],polygon[1],polygon[2])<0 else {return nil}
    result.append(polygon);return result
  }
}
