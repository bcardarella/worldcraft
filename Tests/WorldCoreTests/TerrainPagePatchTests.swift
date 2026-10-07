import XCTest
@testable import WorldCore

final class TerrainPagePatchTests: XCTestCase {
  private let a = TerrainTile(x: -2, z: -2, fullDetail: true)
  private let b = TerrainTile(x: -1, z: -2, fullDetail: true)
  private func group(_ tile: TerrainTile) -> TerrainPageGroup {
    .init(world: UUID(uuidString: "01010101-0101-0101-0101-010101010101")!, tile: tile,
      regionChunks: 2, haze: 3, materialGeneration: 6, castsShadows: true)
  }
  private func mesh(_ count: Int = 1, material: Int = 6, height: Float = 1) -> PackedTerrainMesh {
    var vertices: [TerrainVertex] = [], indices: [UInt32] = []
    for i in 0..<count {
      for p in [SIMD3<Float>(0, height, 0), [1, height, 0], [0, height, 1]] {
        indices.append(UInt32(vertices.count))
        vertices.append(.init(position: p + [Float(i), 0, 0], normal: [0, 1, 0], uv: [0, 0],
          tangent: [1, 0, 0], bitangent: [0, 0, 1]))
      }
    }
    return .init(vertices: vertices, indices: indices, parts: count == 0 ? [] : [
      .init(offset: 0, count: indices.count, material: material, minimum: [0, height, 0], maximum: [Float(count), height, 1])])
  }
  private func source(_ tile: TerrainTile, _ mesh: PackedTerrainMesh, visible: Bool = true) -> TerrainPageChange {
    .upsert(.init(group: group(tile), tile: tile, mesh: mesh, visible: visible))
  }
  /// Independent CPU executor of the same byte/range contract as the native
  /// blit/compute path. Checks every destination is initialized exactly once.
  private func execute(_ patch: TerrainPagePatch, old: PackedTerrainMesh? = nil) -> PackedTerrainMesh {
    let zero = TerrainVertex(position: .zero, normal: .zero, uv: .zero, tangent: .zero, bitangent: .zero)
    var vertices = Array(repeating: zero, count: patch.target.vertexCount)
    var indices = Array(repeating: UInt32.max, count: patch.target.indexCount)
    var writtenV = Array(repeating: 0, count: vertices.count), writtenI = Array(repeating: 0, count: indices.count)
    for copy in patch.vertexCopies {
      for i in 0..<copy.count { vertices[copy.destination + i] = old!.vertices[copy.source + i]; writtenV[copy.destination + i] += 1 }
    }
    for copy in patch.indexCopies {
      for i in 0..<copy.count {
        indices[copy.destination + i] = UInt32(Int(old!.indices[copy.source + i]) + copy.delta)
        writtenI[copy.destination + i] += 1
      }
    }
    for write in patch.vertexUploads {
      for i in 0..<write.count { vertices[write.destination + i] = patch.vertices[write.source + i]; writtenV[write.destination + i] += 1 }
    }
    for write in patch.indexUploads {
      for i in 0..<write.count { indices[write.destination + i] = patch.indices[write.source + i]; writtenI[write.destination + i] += 1 }
    }
    XCTAssertTrue(writtenV.allSatisfy { $0 == 1 }); XCTAssertTrue(writtenI.allSatisfy { $0 == 1 })
    XCTAssertTrue(indices.allSatisfy { $0 < vertices.count })
    for part in patch.target.parts {
      for index in indices[part.offset..<(part.offset + part.count)] {
        let v = vertices[Int(index)]
        XCTAssertTrue(v.px >= part.minimum.x && v.py >= part.minimum.y && v.pz >= part.minimum.z)
        XCTAssertTrue(v.px <= part.maximum.x && v.py <= part.maximum.y && v.pz <= part.maximum.z)
      }
    }
    XCTAssertEqual(patch.uploadedBytes + patch.copiedBytes, patch.target.byteCount)
    XCTAssertEqual(patch.clearedBytes + patch.target.byteCount, patch.target.capacity.bytes)
    return .init(vertices: vertices, indices: indices, parts: patch.target.parts)
  }
  private func assertEqual(_ lhs: PackedTerrainMesh, _ rhs: PackedTerrainMesh, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(lhs.vertices.withUnsafeBytes { Array($0) }, rhs.vertices.withUnsafeBytes { Array($0) }, file: file, line: line)
    XCTAssertEqual(lhs.indices, rhs.indices, file: file, line: line)
    XCTAssertEqual(lhs.parts.map(\.count), rhs.parts.map(\.count), file: file, line: line)
    XCTAssertEqual(lhs.parts.map(\.material), rhs.parts.map(\.material), file: file, line: line)
    XCTAssertEqual(lhs.parts.map(\.minimum), rhs.parts.map(\.minimum), file: file, line: line)
    XCTAssertEqual(lhs.parts.map(\.maximum), rhs.parts.map(\.maximum), file: file, line: line)
  }

  func testInitialPageTranslatesNegativeCoordinatesAndMergesOnlyOpaqueParts() throws {
    let patch = try TerrainPagePatch.build(group: group(a), changes: [source(b, mesh(2)), source(a, mesh())])
    let result = execute(patch)
    XCTAssertEqual(result.parts.count, 1)
    XCTAssertEqual(result.vertices[3].px, 16)
    XCTAssertEqual(patch.target.members.map(\.tile), [a, b])
    XCTAssertEqual(patch.copiedBytes, 0)
    let glass = try TerrainPagePatch.build(group: group(a), changes: [source(a, mesh(material: 2)), source(b, mesh(material: 2))])
    XCTAssertEqual(execute(glass).parts.count, 2)
  }

  func testReplacementUploadsOnlyEditedMemberAndRebasesGrowingNeighbors() throws {
    let first = try TerrainPagePatch.build(group: group(a), changes: [source(a, mesh()), source(b, mesh(2))])
    let original = execute(first)
    let replacement = mesh(8, material: 0, height: 4)
    let next = try TerrainPagePatch.build(group: group(a), previous: first.target, changes: [source(a, replacement)])
    let result = execute(next, old: original)
    XCTAssertEqual(next.uploadedBytes, replacement.byteCount)
    XCTAssertEqual(next.rebasedIndexCount, 6)
    XCTAssertEqual(next.target.version.identity, first.target.version.identity)
    XCTAssertEqual(next.target.version.revision, 2)
    let rebuilt = try TerrainPagePatch.build(group: group(a), changes: [source(a, replacement), source(b, mesh(2))])
    assertEqual(result, execute(rebuilt))
  }

  func testVisibilityRoundTripPreservesHiddenDataWithoutUploadingOrDrawingIt() throws {
    let first = try TerrainPagePatch.build(group: group(a), changes: [source(a, mesh()), source(b, mesh(2))])
    let original = execute(first)
    let hide = try TerrainPagePatch.build(group: group(a), previous: first.target, changes: [.visibility(a, false)])
    let hidden = execute(hide, old: original)
    XCTAssertEqual(hide.uploadedBytes, 0)
    XCTAssertEqual(hidden.parts.reduce(0) { $0 + $1.count }, 6)
    XCTAssertEqual(hidden.indices.count, 9)
    let show = try TerrainPagePatch.build(group: group(a), previous: hide.target, changes: [.visibility(a, true)])
    assertEqual(execute(show, old: hidden), original)
    let hideAll = try TerrainPagePatch.build(group: group(a), previous: show.target, changes: [.visibility(a, false), .visibility(b, false)])
    XCTAssertTrue(execute(hideAll, old: original).parts.isEmpty)
  }

  func testRemovalEmptyAndReinsertHaveNoStaleGeometry() throws {
    let first = try TerrainPagePatch.build(group: group(a), changes: [source(a, mesh(3)), source(b, mesh())])
    let old = execute(first)
    let remove = try TerrainPagePatch.build(group: group(a), previous: first.target, changes: [.remove(a)])
    let onlyB = execute(remove, old: old)
    XCTAssertEqual(remove.rebasedIndexCount, 3)
    XCTAssertEqual(onlyB.indices, [0, 1, 2])
    let empty = try TerrainPagePatch.build(group: group(a), previous: remove.target, changes: [.remove(b)])
    XCTAssertEqual(execute(empty, old: onlyB).byteCount, 0)
    let insert = try TerrainPagePatch.build(group: group(a), previous: empty.target, changes: [source(b, mesh())])
    assertEqual(execute(insert), onlyB)
  }

  func testRepeatedEditsHaveBoundedCapacityAndMatchFreshRebuilds() throws {
    var patch = try TerrainPagePatch.build(group: group(a), changes: [source(a, mesh()), source(b, mesh(7))])
    var current = execute(patch)
    for i in 0..<200 {
      let changed = mesh((i * 17) % 80, material: i % 7, height: Float(i % 12))
      patch = try TerrainPagePatch.build(group: group(a), previous: patch.target, changes: [source(a, changed)])
      current = execute(patch, old: current)
      XCTAssertLessThanOrEqual(patch.target.capacity.bytes, max(patch.target.byteCount * 5 / 4, 2_944))
      let fresh = try TerrainPagePatch.build(group: group(a), changes: [source(a, changed), source(b, mesh(7))])
      assertEqual(current, execute(fresh))
    }
  }

  func testPublicationRejectsStaleFailureResetAndDuplicateCompletions() throws {
    var publication = TerrainPagePublication()
    let first = try TerrainPagePatch.build(group: group(a), changes: [source(a, mesh())])
    let ticket = try XCTUnwrap(publication.begin(first))
    XCTAssertNil(publication.begin(first))
    XCTAssertFalse(publication.finish(ticket, succeeded: false))
    XCTAssertNil(publication.current)
    let retry = try XCTUnwrap(publication.begin(first))
    XCTAssertTrue(publication.finish(retry, succeeded: true))
    XCTAssertFalse(publication.finish(retry, succeeded: true))
    XCTAssertNil(publication.begin(first)) // Old source, despite same page.
    let next = try TerrainPagePatch.build(group: group(a), previous: first.target, changes: [source(a, mesh(2))])
    let stale = try XCTUnwrap(publication.begin(next))
    publication.reset()
    let newWorld = try XCTUnwrap(publication.begin(first))
    XCTAssertFalse(publication.finish(stale, succeeded: true))
    XCTAssertTrue(publication.finish(newWorld, succeeded: true))
    XCTAssertEqual(publication.current, first.target.version)
  }

  func testGroupBoundsPaletteHazeAndWorldCannotBeMixed() throws {
    let original = group(a)
    for mismatch in [
      TerrainPageGroup(world: UUID(), tile: a, regionChunks: 2, haze: 3, materialGeneration: 6, castsShadows: true),
      TerrainPageGroup(world: original.world, tile: a, regionChunks: 2, haze: 4, materialGeneration: 6, castsShadows: true),
      TerrainPageGroup(world: original.world, tile: a, regionChunks: 2, haze: 3, materialGeneration: 7, castsShadows: true),
      TerrainPageGroup(world: original.world, tile: a, regionChunks: 2, haze: 3, materialGeneration: 6, castsShadows: false)
    ] {
      XCTAssertThrowsError(try TerrainPagePatch.build(group: original,
        changes: [.upsert(.init(group: mismatch, tile: a, mesh: mesh()))]))
    }
    let outside = TerrainTile(x: 0, z: 0, fullDetail: true)
    XCTAssertThrowsError(try TerrainPagePatch.build(group: original, changes: [source(outside, mesh())]))
    let lowDetail = TerrainTile(x: -2, z: -2, size: 2)
    XCTAssertThrowsError(try TerrainPagePatch.build(group: original,
      changes: [.upsert(.init(group: original, tile: lowDetail, mesh: mesh()))]))
  }

  func testRejectsWindMalformedBoundsIndicesDuplicatesAndOversizeWithoutMutatingPrevious() throws {
    var wind = mesh().vertices; wind[0].normal.w = 1
    let invalid: [PackedTerrainMesh] = [
      .init(vertices: wind, indices: [0, 1, 2], parts: mesh().parts),
      .init(vertices: mesh().vertices, indices: [0, 1, 99], parts: mesh().parts),
      .init(vertices: mesh().vertices, indices: [0, 1, 2], parts: [
        .init(offset: 0, count: 3, material: 6, minimum: .zero, maximum: .zero)]),
      .init(vertices: mesh().vertices, indices: [0, 1, 2], parts: [])
    ]
    let first = try TerrainPagePatch.build(group: group(a), changes: [source(a, mesh())])
    for bad in invalid {
      XCTAssertThrowsError(try TerrainPagePatch.build(group: group(a), previous: first.target, changes: [source(a, bad)]))
    }
    XCTAssertThrowsError(try TerrainPagePatch.build(group: group(a), changes: [source(a, mesh()), source(a, mesh())]))
    XCTAssertThrowsError(try TerrainPagePatch.build(group: group(a), changes: [source(a, mesh())], maximumBytes: 10))
    XCTAssertThrowsError(try TerrainPagePatch.build(group: group(a), changes: [source(a, mesh()), source(b, mesh())], maximumMembers: 1))
    XCTAssertThrowsError(try TerrainPagePatch.build(group: group(a), previous: first.target, changes: [.remove(b)]))
    XCTAssertEqual(first.target.version.revision, 1)
    XCTAssertEqual(first.target.members.count, 1)
  }

  func testMixedMaterialsVisibilityAndBatchEditsKeepCompactExactRanges() throws {
    func mixed(_ glass: Bool) -> PackedTerrainMesh {
      let one = mesh(), two = mesh(height: 4)
      return .init(vertices: one.vertices + two.vertices, indices: [0, 1, 2, 3, 4, 5], parts: [
        .init(offset: 0, count: 3, material: 6, minimum: one.parts[0].minimum, maximum: one.parts[0].maximum),
        .init(offset: 3, count: 3, material: glass ? 2 : 0, minimum: two.parts[0].minimum, maximum: two.parts[0].maximum)])
    }
    let first = try TerrainPagePatch.build(group: group(a), changes: [source(a, mixed(true)), source(b, mixed(false))])
    let original = execute(first)
    XCTAssertEqual(original.parts.map(\.material), [0, 2, 6])
    let next = try TerrainPagePatch.build(group: group(a), previous: first.target,
      changes: [source(a, mixed(false)), .visibility(b, false)])
    let result = execute(next, old: original)
    let fresh = try TerrainPagePatch.build(group: group(a), changes: [source(a, mixed(false)), source(b, mixed(false), visible: false)])
    assertEqual(result, execute(fresh))
    XCTAssertEqual(result.parts.reduce(0) { $0 + $1.count }, 6)
    XCTAssertEqual(result.indices.count, 12)
    let restore = try TerrainPagePatch.build(group: group(a), previous: next.target, changes: [.visibility(b, true)])
    let restored = execute(restore, old: result)
    XCTAssertEqual(restored.parts.map(\.material), [0, 6])
    XCTAssertEqual(restored.parts.map(\.count), [6, 6])
  }

  func testOverlappingLODLeavesAndUnrelatedPreviousWorldAreRejected() throws {
    let small = TerrainTile(x: 0, z: 0, size: 1), parent = TerrainTile(x: 0, z: 0, size: 2)
    let g = TerrainPageGroup(world: UUID(), tile: parent, regionChunks: 2, haze: 0, materialGeneration: 0, castsShadows: false)
    let changes: [TerrainPageChange] = [small, parent].map { .upsert(.init(group: g, tile: $0, mesh: mesh())) }
    XCTAssertThrowsError(try TerrainPagePatch.build(group: g, changes: changes)) { error in
      XCTAssertEqual(error as? TerrainPageError, .overlappingMembers)
    }
    let first = try TerrainPagePatch.build(group: group(a), changes: [source(a, mesh())])
    XCTAssertThrowsError(try TerrainPagePatch.build(group: g, previous: first.target, changes: [])) { error in
      XCTAssertEqual(error as? TerrainPageError, .incompatibleGroup)
    }
  }
}
