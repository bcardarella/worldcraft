import Foundation

/// Experimental static-terrain page layout. No renderer uses pages by default.
/// A patch uploads only changed tiles, but reconstructs the complete destination
/// buffers using GPU copies. It is NOT a promise of subrange GPU write savings.
public struct TerrainPageGroup: Hashable, Sendable {
  public let world: UUID
  public let x, z, span, surface, haze: Int
  public let materialGeneration: UInt64
  public let castsShadows: Bool
  public var origin: SIMD3<Float> { [Float(x * 16), 0, Float(z * 16)] }

  public init(world: UUID, tile: TerrainTile, regionChunks: Int, haze: Int,
    materialGeneration: UInt64, castsShadows: Bool) {
    precondition(regionChunks > 0 && regionChunks <= 32 && regionChunks.nonzeroBitCount == 1)
    self.world = world
    span = max(tile.size, regionChunks)
    x = floorDivide(tile.x, by: span) * span
    z = floorDivide(tile.z, by: span) * span
    surface = tile.fullDetail ? 0 : tile.retainsBlockSurface ? 1 : 2
    self.haze = haze; self.materialGeneration = materialGeneration; self.castsShadows = castsShadows
  }
  func accepts(_ tile: TerrainTile) -> Bool {
    tile.x >= x && tile.z >= z && tile.x + tile.size <= x + span && tile.z + tile.size <= z + span
      && surface == (tile.fullDetail ? 0 : tile.retainsBlockSurface ? 1 : 2)
  }
}

public struct TerrainPageSource: Sendable {
  public let group: TerrainPageGroup
  public let tile: TerrainTile
  public let mesh: PackedTerrainMesh
  public let visible: Bool
  public init(group: TerrainPageGroup, tile: TerrainTile, mesh: PackedTerrainMesh, visible: Bool = true) {
    self.group = group; self.tile = tile; self.mesh = mesh; self.visible = visible
  }
}

public enum TerrainPageChange: Sendable {
  case upsert(TerrainPageSource)
  case remove(TerrainTile)
  case visibility(TerrainTile, Bool)
  var tile: TerrainTile {
    switch self {
    case .upsert(let source): source.tile
    case .remove(let tile), .visibility(let tile, _): tile
    }
  }
}

public struct TerrainPageVersion: Hashable, Sendable {
  public let identity: UUID
  public let revision: UInt64
}

/// Metadata only: unchanged CPU vertices/indices need not remain resident.
/// Compact vertex runs avoid fragmentation. Growing/removing a member can move
/// later runs; their indices are then rebased on the GPU, without CPU readback.
public struct TerrainPageLayout: Sendable {
  public struct Member: Sendable {
    public let tile: TerrainTile
    public let vertexOffset, vertexCount: Int
    public let visible: Bool
    /// Buffer ranges are retained for hidden members, after all visible ranges.
    /// They do not create draw parts or degenerate triangles.
    public let ranges: [PackedTerrainMesh.Part]
  }
  public let group: TerrainPageGroup
  public let version: TerrainPageVersion
  public let members: [Member]
  public let parts: [PackedTerrainMesh.Part]
  public let vertexCount, indexCount: Int
  public let capacity: TerrainMeshCapacity
  public var byteCount: Int { vertexCount * 40 + indexCount * 4 }
}

public enum TerrainPageError: Error, Equatable {
  case incompatibleGroup, duplicateChange, unknownMember, overlappingMembers
  case invalidMesh, animatedMesh, capacityExceeded, revisionExhausted
}

public struct TerrainPagePatch: Sendable {
  public struct Copy: Sendable {
    /// Element offsets/counts, not bytes. delta is only used for UInt32 indices.
    public let source, destination, count, delta: Int
  }
  public struct Upload: Sendable {
    public let source, destination, count: Int
  }
  public let sourceVersion: TerrainPageVersion?
  public let target: TerrainPageLayout
  public let vertices: [TerrainVertex]
  public let indices: [UInt32]
  public let vertexCopies, indexCopies: [Copy]
  public let vertexUploads, indexUploads: [Upload]
  public var uploadedBytes: Int { vertices.count * 40 + indices.count * 4 }
  public var copiedBytes: Int {
    vertexCopies.reduce(0) { $0 + $1.count * 40 } + indexCopies.reduce(0) { $0 + $1.count * 4 }
  }
  public var rebasedIndexCount: Int { indexCopies.filter { $0.delta != 0 }.reduce(0) { $0 + $1.count } }
  /// Only unused capacity is cleared. Every live element has one copy/upload.
  public var clearedBytes: Int { target.capacity.bytes - target.byteCount }

  public static func build(group: TerrainPageGroup, previous: TerrainPageLayout? = nil,
    changes: [TerrainPageChange], maximumBytes: Int = 4 * 1_024 * 1_024,
    maximumMembers: Int = 32) throws -> Self {
    guard maximumBytes >= 0, maximumMembers >= 0,
      maximumBytes <= 16 * 1_024 * 1_024, maximumMembers <= 32 else { throw TerrainPageError.capacityExceeded }
    if let previous, previous.group != group { throw TerrainPageError.incompatibleGroup }
    if previous?.version.revision == UInt64.max { throw TerrainPageError.revisionExhausted }
    guard Set(changes.map(\.tile)).count == changes.count else { throw TerrainPageError.duplicateChange }
    struct Pending {
      let tile: TerrainTile
      let old: TerrainPageLayout.Member?
      let source: PackedTerrainMesh?
      var visible: Bool
      var count: Int { source?.vertices.count ?? old!.vertexCount }
      var ranges: [PackedTerrainMesh.Part] { source?.parts ?? old!.ranges }
    }
    var members = Dictionary(uniqueKeysWithValues: (previous?.members ?? []).map {
      ($0.tile, Pending(tile: $0.tile, old: $0, source: nil, visible: $0.visible))
    })
    for change in changes {
      switch change {
      case .upsert(let input):
        guard input.group == group, group.accepts(input.tile) else { throw TerrainPageError.incompatibleGroup }
        try validate(input.mesh, maximumBytes: maximumBytes)
        members[input.tile] = Pending(tile: input.tile, old: nil, source: input.mesh, visible: input.visible)
      case .remove(let tile):
        guard members.removeValue(forKey: tile) != nil else { throw TerrainPageError.unknownMember }
      case .visibility(let tile, let visible):
        guard members[tile] != nil else { throw TerrainPageError.unknownMember }
        members[tile]!.visible = visible
      }
    }
    guard members.count <= maximumMembers else { throw TerrainPageError.capacityExceeded }
    let ordered = members.values.sorted { ($0.tile.z, $0.tile.x, $0.tile.size) < ($1.tile.z, $1.tile.x, $1.tile.size) }
    for i in ordered.indices {
      for j in ordered.indices where j < i && ordered[i].tile.overlaps(ordered[j].tile) {
        throw TerrainPageError.overlappingMembers
      }
    }
    let vertexCount = ordered.reduce(0) { $0 + $1.count }
    let indexCount = ordered.reduce(0) { $0 + $1.ranges.reduce(0) { $0 + $1.count } }
    let capacity = TerrainMeshCapacity(vertices: vertexCount, indices: indexCount)
    guard capacity.bytes <= maximumBytes else { throw TerrainPageError.capacityExceeded }

    var vertices: [TerrainVertex] = [], indices: [UInt32] = []
    var vc: [Copy] = [], ic: [Copy] = [], vu: [Upload] = [], iu: [Upload] = []
    var bases: [Int] = [], base = 0
    for member in ordered {
      bases.append(base)
      if let source = member.source {
        let offset = member.tile.origin - group.origin
        vu.append(.init(source: vertices.count, destination: base, count: source.vertices.count))
        for var vertex in source.vertices {
          vertex.px += offset.x; vertex.py += offset.y; vertex.pz += offset.z
          vertices.append(vertex)
        }
      } else if member.count > 0 {
        vc.append(.init(source: member.old!.vertexOffset, destination: base, count: member.count, delta: 0))
      }
      base += member.count
    }
    struct Segment { let member, range: Int; let part: PackedTerrainMesh.Part }
    var segments: [Segment] = []
    for i in ordered.indices {
      for (r, part) in ordered[i].ranges.enumerated() { segments.append(.init(member: i, range: r, part: part)) }
    }
    // Opaque material ranges are shared. Glass (2) keeps one draw range per
    // tile/part for sorting and tighter bounds, as in the existing prototype.
    segments.sort {
      let a = ordered[$0.member].visible, b = ordered[$1.member].visible
      if a != b { return a }
      return ($0.part.material, $0.member, $0.range) < ($1.part.material, $1.member, $1.range)
    }
    var ranges = Array(repeating: [PackedTerrainMesh.Part](), count: ordered.count)
    var parts: [PackedTerrainMesh.Part] = [], indexOffset = 0
    for segment in segments {
      let i = segment.member, member = ordered[i], part = segment.part
      let translation = member.source == nil ? SIMD3<Float>.zero : member.tile.origin - group.origin
      let next = PackedTerrainMesh.Part(offset: indexOffset, count: part.count, material: part.material,
        minimum: part.minimum + translation, maximum: part.maximum + translation)
      ranges[i].append(next)
      if let source = member.source {
        iu.append(.init(source: indices.count, destination: indexOffset, count: part.count))
        for index in source.indices[part.offset..<(part.offset + part.count)] { indices.append(index + UInt32(bases[i])) }
      } else {
        ic.append(.init(source: part.offset, destination: indexOffset, count: part.count,
          delta: bases[i] - member.old!.vertexOffset))
      }
      if member.visible {
        if part.material != 2, let last = parts.last, last.material == part.material {
          parts[parts.count - 1] = .init(offset: last.offset, count: last.count + next.count, material: last.material,
            minimum: componentMin(last.minimum, next.minimum), maximum: componentMax(last.maximum, next.maximum))
        } else { parts.append(next) }
      }
      indexOffset += part.count
    }
    let layout = TerrainPageLayout(group: group,
      version: .init(identity: previous?.version.identity ?? UUID(), revision: (previous?.version.revision ?? 0) + 1),
      members: ordered.indices.map {
        .init(tile: ordered[$0].tile, vertexOffset: bases[$0], vertexCount: ordered[$0].count,
          visible: ordered[$0].visible, ranges: ranges[$0])
      }, parts: parts, vertexCount: vertexCount, indexCount: indexCount, capacity: capacity)
    return .init(sourceVersion: previous?.version, target: layout, vertices: vertices, indices: indices,
      vertexCopies: vc, indexCopies: ic, vertexUploads: vu, indexUploads: iu)
  }

  private static func validate(_ mesh: PackedTerrainMesh, maximumBytes: Int) throws {
    guard mesh.byteCount <= maximumBytes, mesh.indices.count % 3 == 0,
      mesh.parts.count <= 64 else { throw TerrainPageError.invalidMesh }
    var cursor = 0
    for part in mesh.parts.sorted(by: { $0.offset < $1.offset }) {
      guard part.offset == cursor, part.count > 0, part.count % 3 == 0,
        part.count <= mesh.indices.count - cursor, (0...6).contains(part.material),
        finite(part.minimum), finite(part.maximum),
        part.minimum.x <= part.maximum.x, part.minimum.y <= part.maximum.y, part.minimum.z <= part.maximum.z
      else { throw TerrainPageError.invalidMesh }
      for raw in mesh.indices[cursor..<(cursor + part.count)] {
        guard Int(raw) < mesh.vertices.count else { throw TerrainPageError.invalidMesh }
        let v = mesh.vertices[Int(raw)], p = SIMD3(v.px, v.py, v.pz)
        guard p.x >= part.minimum.x, p.y >= part.minimum.y, p.z >= part.minimum.z,
          p.x <= part.maximum.x, p.y <= part.maximum.y, p.z <= part.maximum.z else { throw TerrainPageError.invalidMesh }
      }
      cursor += part.count
    }
    guard cursor == mesh.indices.count else { throw TerrainPageError.invalidMesh }
    for v in mesh.vertices {
      guard finite([v.px, v.py, v.pz]) else { throw TerrainPageError.invalidMesh }
      guard v.normal.w == 0 else { throw TerrainPageError.animatedMesh }
    }
  }
  private static func finite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }
}

/// A completed GPU job still needs a source-version and lifecycle check before
/// publishing. One pending transaction per page; reset invalidates old tickets.
public struct TerrainPagePublication: Sendable {
  public struct Ticket: Equatable, Sendable {
    fileprivate let id: UUID
    fileprivate let target: TerrainPageVersion
  }
  public private(set) var current: TerrainPageVersion?
  private var pending: Ticket?
  public init() {}
  public mutating func begin(_ patch: TerrainPagePatch) -> Ticket? {
    guard pending == nil, current == patch.sourceVersion else { return nil }
    let ticket = Ticket(id: UUID(), target: patch.target.version)
    pending = ticket
    return ticket
  }
  @discardableResult public mutating func finish(_ ticket: Ticket, succeeded: Bool) -> Bool {
    guard pending == ticket else { return false }
    pending = nil
    guard succeeded else { return false }
    current = ticket.target
    return true
  }
  public mutating func reset() { current = nil; pending = nil }
}
