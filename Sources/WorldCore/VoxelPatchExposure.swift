import Foundation

/// Conservative air connectivity within a bounded voxel patch. Vertical air
/// spans avoid allocating a voxel-sized graph or seeding unknown side borders.
/// Used to distinguish enclosed cavities from potentially visible seam caps.
public struct VoxelPatchExposure: Sendable {
  public struct Input: Sendable {
    public let chunk: ChunkData
    public let columns: VoxelColumnMask
    public init(chunk: ChunkData, columns: VoxelColumnMask) { self.chunk = chunk; self.columns = columns }
  }
  public enum BuildResult: Sendable {
    case ready(VoxelPatchExposure)
    case limitExceeded
    case cancelled
  }
  private struct Column: Hashable, Sendable { let x, z: Int }
  private struct Span { let lower, upper: Int16 }
  private let visible: [Column: [Range<Int>]]
  public let columnCount, spanCount: Int
  public func contains(_ point: BlockPosition) -> Bool {
    visible[.init(x: point.x, z: point.z)]?.contains { $0.contains(point.y) } ?? false
  }
  /// Candidate cells are immediately outside an ownership boundary. A void is
  /// potentially visible when an adjacent in-patch air span can see the sky or
  /// a caller-supplied exterior opening. This is connectivity, not a PVS/ray test.
  public func exposedFrontier(_ candidates: [BlockPosition]) -> [BlockPosition] {
    candidates.filter { p in
      contains(p + .init(1,0,0)) || contains(p + .init(-1,0,0))
        || contains(p + .init(0,0,1)) || contains(p + .init(0,0,-1))
    }
  }
  /// `exteriorOpening` should also seed spans visible from the coarse side of
  /// a patch boundary (for example under a bridge). The top of the finite voxel
  /// domain is always open sky. Opaque cells block the conservative flood;
  /// foliage, glass, liquids and partial shapes transmit it and cannot hide a
  /// real hole. `Block.isOpaque` alone also includes cutout leaf textures.
  /// Budget exhaustion/cancellation returns no partial result for publication.
  public static func build(_ chunks: [ChunkCoordinate: Input], maximumColumns: Int = 65_536,
    maximumSpans: Int = 1_000_000, exteriorOpening: (Int, Int, Range<Int>) -> Bool = { _,_,_ in false }) -> BuildResult {
    if Task.isCancelled { return .cancelled }
    precondition(maximumColumns >= 0 && maximumSpans >= 0 && maximumSpans <= Int(Int32.max))
    precondition(ChunkData.minimumY >= Int(Int16.min) && ChunkData.height <= Int(Int16.max))
    var columns: [Column: Range<Int>] = [:], spans: [Span] = []
    var parents: [Int32] = [], ranks: [UInt8] = [], reached: [Bool] = []
    let keys = chunks.keys.sorted { ($0.z, $0.x) < ($1.z, $1.x) }
    for key in keys {
      if Task.isCancelled { return .cancelled }
      let input = chunks[key]!
      precondition(input.chunk.coordinate == key)
      for z in 0..<16 { for x in 0..<16 where input.columns.contains(x: x, z: z) {
        if columns.count >= maximumColumns { return .limitExceeded }
        if Task.isCancelled { return .cancelled }
        let column = Column(x: key.x * 16 + x, z: key.z * 16 + z), first = spans.count
        var y = ChunkData.minimumY
        while y < ChunkData.height {
          let block = input.chunk[x,y,z]
          if block.isOpaque && !block.isFoliage { y += 1; continue }
          let lower = y
          repeat { y += 1 } while y < ChunkData.height
            && (!input.chunk[x,y,z].isOpaque || input.chunk[x,y,z].isFoliage)
          if spans.count >= maximumSpans { return .limitExceeded }
          parents.append(Int32(spans.count)); ranks.append(0)
          reached.append(y == ChunkData.height || exteriorOpening(column.x, column.z, lower..<y))
          spans.append(.init(lower: Int16(lower), upper: Int16(y)))
        }
        columns[column] = first..<spans.count
      } }
    }
    func root(_ value: Int) -> Int {
      var index = value
      while Int(parents[index]) != index { index = Int(parents[index]) }
      var child = value
      while Int(parents[child]) != index {
        let next = Int(parents[child]); parents[child] = Int32(index); child = next
      }
      return index
    }
    func join(_ a: Int, _ b: Int) {
      var x = root(a), y = root(b)
      guard x != y else { return }
      if ranks[x] < ranks[y] { swap(&x, &y) }
      parents[y] = Int32(x); reached[x] = reached[x] || reached[y]
      if ranks[x] == ranks[y] { ranks[x] += 1 }
    }
    // Sorting also makes the build reproducible across dictionary order. Only
    // +X/+Z pairs are visited; interval overlap is linear in the two run counts.
    let ordered = columns.keys.sorted { ($0.z, $0.x) < ($1.z, $1.x) }
    for column in ordered {
      if Task.isCancelled { return .cancelled }
      let a = columns[column]!
      for other in [Column(x: column.x + 1, z: column.z), Column(x: column.x, z: column.z + 1)] {
        guard let b = columns[other] else { continue }
        var i = a.lowerBound, j = b.lowerBound
        while i < a.upperBound && j < b.upperBound {
          let p = spans[i], q = spans[j]
          if p.lower < q.upper && q.lower < p.upper { join(i,j) }
          if p.upper < q.upper { i += 1 } else { j += 1 }
        }
      }
    }
    var visible: [Column: [Range<Int>]] = [:]
    for column in ordered {
      if Task.isCancelled { return .cancelled }
      let runs = columns[column]!.compactMap { index -> Range<Int>? in
        guard reached[root(index)] else { return nil }
        return Int(spans[index].lower)..<Int(spans[index].upper)
      }
      if !runs.isEmpty { visible[column] = runs }
    }
    return .ready(.init(visible: visible, columnCount: columns.count, spanCount: spans.count))
  }
}

extension VoxelPatchExposure {
  /// One immutable chunk/halo version. Copies preserve identity; construct a
  /// new source after any edit/reload so an incremental graph cannot use old
  /// connectivity. The graph retains identity/masks, not the voxel payload.
  public struct Source: Sendable {
    fileprivate let identity = UUID()
    public let chunk: ChunkData
    public init(_ chunk: ChunkData) { self.chunk = chunk }
  }
  public struct IncrementalInput: Sendable {
    public let source: Source
    public let columns: VoxelColumnMask
    public init(source: Source, columns: VoxelColumnMask) {
      self.source = source; self.columns = columns
    }
  }

  /// Local air cells in components with no sky or supplied exterior opening.
  /// This is a snapshot of a successful graph update, not a view-validity or
  /// publication certificate. Callers must seed every exterior opening and any
  /// camera-containing component, and rebuild after relevant world/view changes.
  /// Unknown columns and the chunk halo are deliberately never marked enclosed.
  public struct EnclosedAir: Sendable {
    fileprivate let sourceIdentity: UUID
    fileprivate let rows: [UInt16]
    func matches(_ source: Source) -> Bool { sourceIdentity == source.identity }
    func contains(x: Int, y: Int, z: Int) -> Bool {
      guard (0..<16).contains(x), (0..<16).contains(z),
        (ChunkData.minimumY..<ChunkData.height).contains(y) else { return false }
      return rows[(y - ChunkData.minimumY) * 16 + z] & (UInt16(1) << x) != 0
    }
  }

  /// Worker-owned monotonic connectivity. Only new columns are voxel-scanned
  /// and joined; every update refreshes external openings, including removals.
  /// It is a value snapshot, not a shared mutable graph or publication policy.
  /// Count limits bound graph payload, not elapsed time or allocator/RSS usage.
  public struct Incremental: Sendable {
    public struct Change: Sendable, Equatable {
      public let addedColumns, addedSpans, refreshedOpenings: Int
    }
    public enum UpdateResult: Sendable {
      case ready(Change)
      case limitExceeded
      /// Changed chunk/halo identity or removed ownership needs a new graph.
      case requiresRebuild
      case cancelled
    }
    private struct Owner: Sendable {
      let identity: UUID
      let mask: VoxelColumnMask
    }
    private struct Node: Sendable {
      let lower, upper: Int16
      var parent: Int32
      var rank: UInt8 = 0
      /// Number of sky/exterior seeds in this component, valid on roots only.
      var seeds: Int32
      var exterior = false
    }
    private struct Addition {
      let column: Column
      let spans: [Range<Int>]
    }
    private let maximumColumns, maximumSpans: Int
    private var owners: [ChunkCoordinate: Owner] = [:]
    private var columns: [Column: Range<Int>] = [:]
    private var order: [Column] = []
    private var nodes: [Node] = []
    public var columnCount: Int { columns.count }
    public var spanCount: Int { nodes.count }

    public init(maximumColumns: Int = 65_536, maximumSpans: Int = 1_000_000) {
      precondition(maximumColumns >= 0 && maximumSpans >= 0 && maximumSpans <= Int(Int32.max))
      precondition(ChunkData.minimumY >= Int(Int16.min) && ChunkData.height <= Int(Int16.max))
      self.maximumColumns = maximumColumns; self.maximumSpans = maximumSpans
    }
    private func root(_ value: Int) -> Int {
      var index = value
      while Int(nodes[index].parent) != index { index = Int(nodes[index].parent) }
      return index
    }
    private mutating func compress(_ value: Int) -> Int {
      let ancestor = root(value)
      var child = value
      while Int(nodes[child].parent) != ancestor {
        let next = Int(nodes[child].parent)
        nodes[child].parent = Int32(ancestor); child = next
      }
      return ancestor
    }
    private mutating func join(_ a: Int, _ b: Int) {
      var x = compress(a), y = compress(b)
      guard x != y else { return }
      if nodes[x].rank < nodes[y].rank { swap(&x, &y) }
      nodes[y].parent = Int32(x); nodes[x].seeds += nodes[y].seeds
      if nodes[x].rank == nodes[y].rank { nodes[x].rank += 1 }
    }
    public func contains(_ point: BlockPosition) -> Bool {
      guard let range = columns[.init(x: point.x, z: point.z)] else { return false }
      for index in range {
        let node = nodes[index]
        if Int(node.lower) <= point.y && point.y < Int(node.upper) {
          return nodes[root(index)].seeds > 0
        }
      }
      return false
    }
    public func exposedFrontier(_ candidates: [BlockPosition]) -> [BlockPosition] {
      candidates.filter { p in
        contains(p + .init(1,0,0)) || contains(p + .init(-1,0,0))
          || contains(p + .init(0,0,1)) || contains(p + .init(0,0,-1))
      }
    }
    /// Materialize one small local bitset, so mesh face traversal needs no
    /// hash lookup, union-root traversal or actor hop. A replaced chunk/halo
    /// source or cancellation returns nil; it cannot reuse stale connectivity.
    public func enclosedAir(in source: Source) -> EnclosedAir? {
      let key = source.chunk.coordinate
      guard !Task.isCancelled, let owner = owners[key], owner.identity == source.identity else { return nil }
      var rows = [UInt16](repeating: 0, count: (ChunkData.height - ChunkData.minimumY) * 16)
      for z in 0..<16 {
        if Task.isCancelled { return nil }
        for x in 0..<16 where owner.mask.contains(x: x, z: z) {
          let range = columns[.init(x: key.x * 16 + x, z: key.z * 16 + z)]!
          for index in range where nodes[root(index)].seeds == 0 {
            let span = nodes[index], bit = UInt16(1) << x
            for y in Int(span.lower)..<Int(span.upper) where source.chunk[x,y,z] == .air {
              rows[(y - ChunkData.minimumY) * 16 + z] |= bit
            }
          }
        }
      }
      guard !Task.isCancelled else { return nil }
      return .init(sourceIdentity: source.identity, rows: rows)
    }
    /// Pass the complete next ownership set. Existing columns may remain or
    /// grow, never disappear or change source. Any non-ready result preserves
    /// the previous successful snapshot; it is not valid for the new demand.
    /// Cancellation during a callback also rolls back all work in this call.
    /// Exterior openings use exactly the full builder's span/sky semantics.
    /// The callback must query an immutable snapshot without depending on call
    /// order; graph growth need not visit older and newer columns in grid order.
    public mutating func update(_ inputs: [ChunkCoordinate: IncrementalInput],
      exteriorOpening: (Int, Int, Range<Int>) -> Bool = { _,_,_ in false }) -> UpdateResult {
      if Task.isCancelled { return .cancelled }
      for (key, old) in owners {
        if Task.isCancelled { return .cancelled }
        guard let input = inputs[key], input.source.identity == old.identity else { return .requiresRebuild }
        for z in 0..<16 where old.mask.row(z) & ~input.columns.row(z) != 0 { return .requiresRebuild }
      }
      let keys = inputs.keys.sorted { ($0.z, $0.x) < ($1.z, $1.x) }
      var additions: [Addition] = [], additionalSpans = 0
      for key in keys {
        if Task.isCancelled { return .cancelled }
        let input = inputs[key]!, chunk = input.source.chunk, old = owners[key]?.mask
        precondition(chunk.coordinate == key)
        for z in 0..<16 { for x in 0..<16 where input.columns.contains(x: x, z: z)
          && !(old?.contains(x: x, z: z) ?? false) {
          if Task.isCancelled { return .cancelled }
          if additions.count >= maximumColumns - columns.count { return .limitExceeded }
          var spans: [Range<Int>] = [], y = ChunkData.minimumY
          while y < ChunkData.height {
            let block = chunk[x,y,z]
            if block.isOpaque && !block.isFoliage { y += 1; continue }
            let lower = y
            repeat { y += 1 } while y < ChunkData.height
              && (!chunk[x,y,z].isOpaque || chunk[x,y,z].isFoliage)
            if additionalSpans >= maximumSpans - nodes.count { return .limitExceeded }
            spans.append(lower..<y); additionalSpans += 1
          }
          additions.append(.init(column: .init(x: key.x * 16 + x, z: key.z * 16 + z), spans: spans))
        } }
      }
      // CoW keeps existing value snapshots immutable and provides transactional
      // cancellation. Only graph arrays/maps copy, never input voxel buffers.
      var next = self
      for key in keys {
        let input = inputs[key]!
        if !input.columns.isEmpty { next.owners[key] = .init(identity: input.source.identity, mask: input.columns) }
      }
      for addition in additions {
        if Task.isCancelled { return .cancelled }
        let first = next.nodes.count
        for span in addition.spans {
          next.nodes.append(.init(lower: Int16(span.lowerBound), upper: Int16(span.upperBound),
            parent: Int32(next.nodes.count), seeds: span.upperBound == ChunkData.height ? 1 : 0))
        }
        next.columns[addition.column] = first..<next.nodes.count; next.order.append(addition.column)
      }
      // New columns connect to old and new neighbours in every direction.
      // Repeated joins of two new columns are harmless and deterministic.
      for addition in additions {
        if Task.isCancelled { return .cancelled }
        let p = addition.column, a = next.columns[p]!
        for q in [Column(x: p.x-1, z: p.z), Column(x: p.x+1, z: p.z),
          Column(x: p.x, z: p.z-1), Column(x: p.x, z: p.z+1)] {
          guard let b = next.columns[q] else { continue }
          var i = a.lowerBound, j = b.lowerBound
          while i < a.upperBound && j < b.upperBound {
            let u = next.nodes[i], v = next.nodes[j]
            if u.lower < v.upper && v.lower < u.upper { next.join(i,j) }
            if u.upper < v.upper { i += 1 } else { j += 1 }
          }
        }
      }
      var refreshed = 0
      for column in next.order {
        if Task.isCancelled { return .cancelled }
        for index in next.columns[column]! {
          let node = next.nodes[index]
          // Sky is permanent; the full builder also skips its exterior callback.
          guard node.upper != Int16(ChunkData.height) else { continue }
          let exposed = exteriorOpening(column.x, column.z, Int(node.lower)..<Int(node.upper))
          refreshed += 1
          if exposed != node.exterior {
            let root = next.compress(index)
            next.nodes[root].seeds += exposed ? 1 : -1
            precondition(next.nodes[root].seeds >= 0)
            next.nodes[index].exterior = exposed
          }
        }
      }
      if Task.isCancelled { return .cancelled }
      self = next
      return .ready(.init(addedColumns: additions.count, addedSpans: additionalSpans, refreshedOpenings: refreshed))
    }
  }
}
