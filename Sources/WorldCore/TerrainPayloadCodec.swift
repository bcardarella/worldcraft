import CryptoKit
import Foundation

/// Versioned local cache format, not a save format. All lengths, indices and
/// material ranges are checked before a decoded payload can reach RealityKit.
/// The only raw arrays are fixed-layout POD on supported little-endian targets.
enum TerrainPayloadCodec {
  static let maximumBytes = 16 * 1_024 * 1_024
  static let magic = Data("WCTILE01".utf8)
  // Ground-source metadata uses schema 5 for coarse payloads. Full-detail data
  // retains schema 2, preserving its existing cache identity and serialized bytes.
  private static func schema(for key: TerrainPayloadKey) -> UInt32 { key.tile.fullDetail ? 2 : 5 }
  enum Invalid: Error { case archive }

  static func keyData(_ key: TerrainPayloadKey) -> Data {
    var out = Writer()
    out.integer(key.seed); out.int(key.style.rawValue)
    out.int(key.tile.x); out.int(key.tile.z); out.int(key.tile.size)
    out.flag(key.tile.fullDetail); out.flag(key.lush); out.flag(key.repeatAtlas); out.flag(key.instanceSeats)
    if key.profileSurface { out.flag(true) }
    out.int(key.generatorVariant)
    out.int(key.generationVersion); out.int(key.representationVersion); out.int(key.atlasVersion)
    out.int(key.blocks.count)
    for edit in key.blocks { out.position(edit.position); out.integer(edit.block.rawValue) }
    out.int(key.plants.count)
    for edit in key.plants { out.position(edit.position); out.int(edit.kind?.rawValue ?? -1) }
    return out.data
  }
  static func filename(_ key: TerrainPayloadKey) -> String {
    // Preserve the on-disk identity without 32 formatter/temporary-string calls
    // on every memory miss and writeback.
    let hexadecimal = Array("0123456789abcdef".utf8)
    var bytes: [UInt8] = []; bytes.reserveCapacity(74)
    for byte in SHA256.hash(data: keyData(key)) {
      bytes.append(hexadecimal[Int(byte >> 4)]); bytes.append(hexadecimal[Int(byte & 15)])
    }
    bytes.append(contentsOf: ".wcterrain".utf8)
    return String(decoding: bytes, as: UTF8.self)
  }
  static func encode(_ payload: PreparedTerrainTile, key: TerrainPayloadKey) -> Data? {
    guard MemoryLayout<TerrainVertex>.stride == 40,
      payload.byteCount + key.byteCount < maximumBytes,
      payload.tile == key.tile, payload.lush == key.lush, payload.id.repeatAtlas == key.repeatAtlas,
      payload.id.instanceSeats == key.instanceSeats, payload.id.profileSurface == key.profileSurface,
      (payload.surfaceProfile != nil) == key.profileSurface else { return nil }
    var out = Writer()
    out.integer(schema(for: key)); out.integer(UInt32(MemoryLayout<TerrainVertex>.stride))
    out.raw([UInt8](keyData(key)))
    out.flag(payload.chunk != nil)
    if let chunk = payload.chunk {
      guard chunk.coordinate == key.tile.coordinate else { return nil }
      out.int(chunk.maximumFilledY); out.raw(chunk.archiveCells)
    }
    out.mesh(payload.mesh); out.flag(payload.animated != nil)
    if let animated = payload.animated { out.mesh(animated) }
    out.int(payload.windAdmissionVertexCount)
    if key.profileSurface { out.flag(payload.surfaceProfile != nil) }
    if let profile = payload.surfaceProfile {
      guard !payload.tile.fullDetail, profile.isValid else { return nil }
      out.float(profile.minimumY); out.float(profile.maximumY)
      out.float(profile.sampledHeightError); out.int(profile.sampleCount)
      out.float(profile.groupedCanopyExtent)
    }
    if !key.tile.fullDetail {
      out.flag(payload.surfaceGrid != nil)
      if let grid = payload.surfaceGrid {
        guard grid.tile == key.tile else { return nil }
        out.raw(grid.heights); out.raw(grid.materials.map(\.rawValue))
      }
    } else if payload.surfaceGrid != nil { return nil }
    out.int(payload.water.samples.count)
    for sample in payload.water.samples {
      out.float(sample.position.x); out.float(sample.position.y); out.float(sample.depth)
      out.integer(sample.body.id); out.int(sample.body.kind.rawValue); out.float(sample.body.level)
      out.vector(sample.body.current)
    }
    out.raw(payload.water.shallowIndices); out.raw(payload.water.deepIndices)
    out.int(payload.plants.count)
    for plant in payload.plants {
      out.position(plant.position); out.int(plant.kind.rawValue); out.float(plant.scale)
    }
    for positions in [payload.lamps, payload.fires] {
      out.int(positions.count)
      for position in positions { out.vector(position) }
    }
    out.int(payload.stadiumSeats.count)
    for seat in payload.stadiumSeats {
      out.vector(seat.position); out.float(seat.forward.x); out.float(seat.forward.y); out.integer(seat.color)
    }
    guard out.data.count <= maximumBytes - magic.count - 32 else { return nil }
    var result = magic
    result.append(contentsOf: SHA256.hash(data: out.data)); result.append(out.data)
    return result
  }
  static func decode(_ data: Data, key: TerrainPayloadKey, id: TerrainWorkID) -> PreparedTerrainTile? {
    guard data.count >= magic.count + 40, data.count <= maximumBytes,
      data.prefix(magic.count) == magic, MemoryLayout<TerrainVertex>.stride == 40,
      id.tile == key.tile, id.lush == key.lush, id.repeatAtlas == key.repeatAtlas,
      id.instanceSeats == key.instanceSeats, id.profileSurface == key.profileSurface else { return nil }
    let body = data.dropFirst(magic.count + 32)
    guard Data(SHA256.hash(data: body)) == data[magic.count..<(magic.count + 32)] else { return nil }
    do {
      var input = Reader(data: Data(body))
      guard try input.integer(UInt32.self) == schema(for: key),
        try input.integer(UInt32.self) == 40,
        try Data(input.raw(UInt8.self)) == keyData(key) else { return nil }
      var chunk: ChunkData?
      if try input.flag() {
        let maximum = try input.int(), cells = try input.raw(UInt8.self)
        chunk = ChunkData(coordinate: key.tile.coordinate, archiveCells: cells, maximumFilledY: maximum)
        guard chunk != nil else { return nil }
      }
      guard (chunk != nil) == key.tile.fullDetail else { return nil }
      let mesh = try input.mesh()
      let animated = try input.flag() ? input.mesh() : nil
      // Repeated UVs require the repeating material. Shaped opaque plant quads
      // can use one repeat each; their independent wind weights are preserved.
      if !key.repeatAtlas && mesh.parts.contains(where: { $0.material == 6 }) { return nil }
      if !key.repeatAtlas && animated?.parts.contains(where: { $0.material == 6 }) == true { return nil }
      let admissionCount = try input.int()
      guard admissionCount >= 0, admissionCount <= maximumBytes / 40 else { return nil }
      var profile: TerrainSurfaceProfile?
      if key.profileSurface, try input.flag() {
        profile = .init(minimumY: try input.float(), maximumY: try input.float(),
          sampledHeightError: try input.float(), sampleCount: try input.int(), groupedCanopyExtent: try input.float())
        guard !key.tile.fullDetail, profile?.isValid == true else { return nil }
      }
      guard (profile != nil) == key.profileSurface else { return nil }
      var grid: TerrainSurfaceGrid?
      if !key.tile.fullDetail, try input.flag() {
        let heights = try input.raw(Float.self), raw = try input.raw(UInt8.self)
        let materials = raw.compactMap(Block.init(rawValue:))
        guard materials.count == raw.count,
          let value = TerrainSurfaceGrid(tile:key.tile,heights:heights,materials:materials) else { return nil }
        grid = value
      }
      var water = WaterGeometry()
      let sampleCount = try input.count(minimumStride: 44)
      water.samples.reserveCapacity(sampleCount)
      for _ in 0..<sampleCount {
        let position = SIMD2(try input.float(), try input.float()), depth = try input.float()
        let bodyID = try input.integer(UInt64.self), kindRaw = try input.int(), level = try input.float()
        guard let kind = WaterBodyKind(rawValue: kindRaw), depth >= 0 else { return nil }
        water.samples.append(.init(position: position, depth: depth,
          body: .init(id: bodyID, kind: kind, level: level, current: try input.vector())))
      }
      water.shallowIndices = try input.indices(vertexCount: sampleCount)
      water.deepIndices = try input.indices(vertexCount: sampleCount)
      var plants: [PlantInstance] = []
      let plantCount = try input.count(minimumStride: 36)
      plants.reserveCapacity(plantCount)
      for _ in 0..<plantCount {
        let position = try input.position(), raw = try input.int(), scale = try input.float()
        guard let kind = PlantKind(rawValue: raw), scale > 0, scale <= 64 else { return nil }
        plants.append(.init(position: position, kind: kind, scale: scale))
      }
      let lamps = try input.vectors(), fires = try input.vectors()
      let seatCount = try input.count(minimumStride: 21)
      guard seatCount == 0 || key.instanceSeats else { return nil }
      var stadiumSeats: [StadiumSeatInstance] = []; stadiumSeats.reserveCapacity(seatCount)
      for _ in 0..<seatCount {
        let seat = StadiumSeatInstance(position: try input.vector(),
          forward: SIMD2(try input.float(), try input.float()), color: try input.integer(UInt8.self))
        guard seat.isValid(in: key.tile) else { return nil }
        stadiumSeats.append(seat)
      }
      guard input.offset == input.data.count else { return nil }
      return .init(id: id, chunk: chunk, mesh: mesh, animated: animated,
        windAdmissionVertexCount: admissionCount, stadiumSeats: stadiumSeats, surfaceProfile: profile, surfaceGrid: grid,
        water: water, plants: plants, lamps: lamps, fires: fires)
    } catch { return nil }
  }

  private struct Writer {
    var data = Data()
    mutating func integer<T: FixedWidthInteger>(_ value: T) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    mutating func int(_ value: Int) { integer(Int64(value)) }
    mutating func flag(_ value: Bool) { integer(UInt8(value ? 1 : 0)) }
    mutating func float(_ value: Float) { integer(value.bitPattern) }
    mutating func vector(_ value: SIMD3<Float>) { float(value.x); float(value.y); float(value.z) }
    mutating func position(_ value: BlockPosition) { int(value.x); int(value.y); int(value.z) }
    mutating func raw<T>(_ values: [T]) {
      int(values.count)
      values.withUnsafeBytes { data.append(contentsOf: $0) }
    }
    mutating func mesh(_ value: PackedTerrainMesh) {
      raw(value.vertices); raw(value.indices); int(value.parts.count)
      for part in value.parts {
        int(part.offset); int(part.count); int(part.material); vector(part.minimum); vector(part.maximum)
      }
    }
  }
  private struct Reader {
    let data: Data
    var offset = 0
    mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
      let size = MemoryLayout<T>.size
      guard size <= data.count - offset else { throw Invalid.archive }
      let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
      offset += size
      return T(littleEndian: value)
    }
    mutating func int() throws -> Int {
      guard let value = Int(exactly: try integer(Int64.self)) else { throw Invalid.archive }
      return value
    }
    mutating func count(minimumStride: Int) throws -> Int {
      let value = try int()
      guard value >= 0, value <= (data.count - offset) / minimumStride else { throw Invalid.archive }
      return value
    }
    mutating func flag() throws -> Bool {
      let value = try integer(UInt8.self)
      guard value <= 1 else { throw Invalid.archive }
      return value == 1
    }
    mutating func float() throws -> Float {
      let value = Float(bitPattern: try integer(UInt32.self))
      guard value.isFinite else { throw Invalid.archive }
      return value
    }
    mutating func vector() throws -> SIMD3<Float> { try .init(float(), float(), float()) }
    mutating func position() throws -> BlockPosition { try .init(int(), int(), int()) }
    mutating func vectors() throws -> [SIMD3<Float>] {
      let size = try count(minimumStride: 12)
      var result: [SIMD3<Float>] = []; result.reserveCapacity(size)
      for _ in 0..<size { result.append(try vector()) }
      return result
    }
    // Called exclusively with TerrainVertex, Float, UInt32 and UInt8 (no reference types).
    mutating func raw<T>(_ type: T.Type) throws -> [T] {
      let size = try count(minimumStride: MemoryLayout<T>.stride)
      let bytes = size * MemoryLayout<T>.stride
      let result = Array<T>(unsafeUninitializedCapacity: size) { buffer, initialized in
        if bytes > 0 {
          data.withUnsafeBytes { source in
            UnsafeMutableRawPointer(buffer.baseAddress!).copyMemory(
              from: source.baseAddress!.advanced(by: offset), byteCount: bytes)
          }
        }
        initialized = size
      }
      offset += bytes
      return result
    }
    mutating func indices(vertexCount: Int) throws -> [UInt32] {
      let values = try raw(UInt32.self)
      guard values.count % 3 == 0, values.allSatisfy({ $0 < vertexCount }) else { throw Invalid.archive }
      return values
    }
    mutating func mesh() throws -> PackedTerrainMesh {
      let vertices = try raw(TerrainVertex.self), indices = try indices(vertexCount: vertices.count)
      for vertex in vertices {
        guard vertex.px.isFinite, vertex.py.isFinite, vertex.pz.isFinite,
          Float16(bitPattern: vertex.u).isFinite, Float16(bitPattern: vertex.v).isFinite else { throw Invalid.archive }
        for vector in [vertex.normal, vertex.tangent, vertex.bitangent] {
          for i in 0..<4 where !Float16(bitPattern: vector[i]).isFinite { throw Invalid.archive }
        }
      }
      let partCount = try count(minimumStride: 48)
      var parts: [PackedTerrainMesh.Part] = [], end = 0
      for _ in 0..<partCount {
        let start = try int(), size = try int(), material = try int()
        let low = try vector(), high = try vector()
        guard start == end, size > 0, size % 3 == 0, size <= indices.count - end,
          (0..<7).contains(material), low.x <= high.x, low.y <= high.y, low.z <= high.z else { throw Invalid.archive }
        for index in indices[start..<(start + size)] {
          let vertex = vertices[Int(index)]
          guard vertex.px >= low.x, vertex.py >= low.y, vertex.pz >= low.z,
            vertex.px <= high.x, vertex.py <= high.y, vertex.pz <= high.z else { throw Invalid.archive }
          if material == 6 {
            let tile = Float(Float16(bitPattern: vertex.tangent.w))
            guard tile >= 0, tile < 128, tile == tile.rounded(.down) else { throw Invalid.archive }
          }
        }
        parts.append(.init(offset: start, count: size, material: material, minimum: low, maximum: high))
        end += size
      }
      guard end == indices.count else { throw Invalid.archive }
      return .init(vertices: vertices, indices: indices, parts: parts)
    }
  }
}
