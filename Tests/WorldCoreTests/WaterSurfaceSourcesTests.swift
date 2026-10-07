import Foundation
import XCTest
@testable import WorldCore

final class WaterSurfaceSourcesTests: XCTestCase, @unchecked Sendable {
  private typealias R = WaterSurfaceRefinement
  private func isOnMainThread() -> Bool { Thread.isMainThread }
  private func quad(_ tile: TerrainTile, depth: Float = 3, body: WaterBody = .ocean,
    x: Int = 0, z: Int = 0, step: Int? = nil, shallow: Bool = true) -> WaterGeometry {
    let width = Float(step ?? WaterSurfaceSources.Reader.stride(for: tile)), origin = SIMD2<Float>(Float(x), Float(z))
    var result = WaterGeometry()
    result.samples = [origin, origin+[0,width], origin+[width,0], origin+[width,width]].map {
      .init(position: $0, depth: depth, body: body)
    }
    if shallow { result.shallowIndices = [0,1,2,2,1,3] } else { result.deepIndices = [0,1,2,2,1,3] }
    return result
  }
  private func publish(_ requests: inout WaterGeometryRequests, to sources: inout WaterSurfaceSources) throws {
    for key in Array(requests.dirty.keys) {
      let input = try XCTUnwrap(requests.beginPreparation(for: key))
      let accepted = requests.publishableTiles(in: input)
      sources.install(input, published: accepted)
      XCTAssertTrue(requests.acknowledge(input, published: accepted))
    }
  }
  private func fixture(_ tiles: [TerrainTile: WaterGeometry], limit: WaterSurfaceSources? = nil) throws
    -> (WaterGeometryRequests, WaterSurfaceSources) {
    var requests = WaterGeometryRequests(), sources = limit ?? .init()
    for (tile, geometry) in tiles { requests.install(geometry, tile: tile) }
    try publish(&requests, to: &sources)
    return (requests, sources)
  }

  func testQueuedAndFailedReplacementsDoNotOverwritePublishedSources() throws {
    let tile = TerrainTile(x: 0,z: 0,fullDetail: true)
    let original = quad(tile), replacement = quad(tile,depth: 17,body: .init(id: 88,kind: .river,level: 21,current: [0.3,0,-0.8]))
    var (requests,sources) = try fixture([tile:original])
    let snapshot = try XCTUnwrap(sources.snapshot(visible: [tile]))
    let lease = snapshot.dependencies(for: [tile.coordinate])
    requests.install(replacement,tile: tile)
    let input = try XCTUnwrap(requests.beginPreparation(for: .init(tile)))
    // A failed native allocation does not install or acknowledge its input.
    XCTAssertTrue(sources.isCurrent(lease,visible: [tile]))
    XCTAssertEqual(sources.snapshot(visible: [tile])?.sources[tile]?.geometry,original)
    XCTAssertFalse(requests.dirty.isEmpty)
    sources.install(input,published: requests.publishableTiles(in: input))
    XCTAssertTrue(requests.acknowledge(input,published: [tile]))
    XCTAssertFalse(sources.isCurrent(lease,visible: [tile]))
    XCTAssertEqual(snapshot.sources[tile]?.geometry,original,"Captured arrays remain immutable")
    XCTAssertEqual(sources.snapshot(visible: [tile])?.sources[tile]?.geometry,replacement)
  }

  func testPartialPublicationAndRepackingKeepUnchangedTileIdentity() throws {
    let a = TerrainTile(x: 0,z: 0,fullDetail: true), b = TerrainTile(x: 1,z: 0,fullDetail: true)
    var requests = WaterGeometryRequests(), sources = WaterSurfaceSources()
    requests.install(quad(a),tile: a); requests.install(quad(b),tile: b)
    let old = try XCTUnwrap(requests.beginPreparation(for: .init(a)))
    requests.install(.init(),tile: b)
    let accepted = requests.publishableTiles(in: old)
    XCTAssertEqual(accepted,[a]); sources.install(old,published: accepted)
    XCTAssertFalse(requests.acknowledge(old,published: accepted))
    XCTAssertNil(sources.snapshot(visible: [a,b]),"Unpublished dry replacement is still unknown")
    let lease = try XCTUnwrap(sources.snapshot(visible: [a])).dependencies(for: [a.coordinate])
    try publish(&requests,to: &sources)
    let snapshot = try XCTUnwrap(sources.snapshot(visible: [a,b]))
    XCTAssertTrue(sources.isCurrent(lease,visible: [a,b]))
    XCTAssertEqual(snapshot.sources[a]?.version,old.version(for: a))
    XCTAssertTrue(snapshot.sources[b]!.geometry.isEmpty)
    XCTAssertEqual(sources.metrics.reused,1)
    var reader = WaterSurfaceSources.Reader(snapshot)
    XCTAssertNil(reader.cell(at: .init(16,0))?.corners,"Known dry is represented explicitly")
    XCTAssertNil(reader.failure)
  }

  func testRemovedParentRemainsReadableUntilCompleteWaterCoverageExchange() throws {
    let parent = TerrainTile(x: 0,z: 0,size: 2)
    let children = Set([TerrainTile(x: 0,z: 0,fullDetail: true),.init(x: 1,z: 0,fullDetail: true),
      .init(x: 0,z: 1,fullDetail: true),.init(x: 1,z: 1,fullDetail: true)])
    var (requests,sources) = try fixture([parent:quad(parent)])
    var coverage = WaterPresentationCoverage(), available: Set<TerrainTile> = [parent]
    coverage.update(desired: [parent],available: available)
    let snapshot = try XCTUnwrap(sources.snapshot(visible: coverage.visible))
    requests.remove(parent)
    for (i,child) in children.sorted(by: { ($0.z,$0.x)<($1.z,$1.x) }).enumerated() {
      requests.install(quad(child),tile: child); try publish(&requests,to: &sources)
      available.insert(child); coverage.update(desired: children,available: available)
      if i < 3 {
        XCTAssertEqual(coverage.visible,[parent]); XCTAssertTrue(sources.isCurrent(snapshot,visible: coverage.visible))
      }
    }
    XCTAssertEqual(coverage.visible,children)
    XCTAssertFalse(sources.isCurrent(snapshot.dependencies(for: [parent.coordinate]),visible: coverage.visible))
    sources.remove(parent)
    XCTAssertNotNil(sources.snapshot(visible: children)); XCTAssertEqual(sources.metrics.entries,4)
  }

  func testLeasesTrackRelevantChangesNegativeReadsAndReset() throws {
    let a = TerrainTile(x: -2,z: -2), b = TerrainTile(x: 4,z: 4), missing = ChunkCoordinate(10,10)
    var (requests,sources) = try fixture([a:quad(a)])
    let snapshot = try XCTUnwrap(sources.snapshot(visible: [a]))
    let lease = snapshot.dependencies(for: [a.coordinate,missing])
    XCTAssertEqual(lease.sourceCount,1); XCTAssertEqual(lease.missingCount,1)
    requests.install(quad(b),tile: b); try publish(&requests,to: &sources)
    XCTAssertTrue(sources.isCurrent(lease,visible: [a,b]))
    let filled = TerrainTile(x: 8,z: 8,size: 4)
    requests.install(.init(),tile: filled); try publish(&requests,to: &sources)
    XCTAssertFalse(sources.isCurrent(lease,visible: [a,b,filled]))
    let live = try XCTUnwrap(sources.snapshot(visible: [a,b,filled])).dependencies(for: [a.coordinate])
    requests.remove(a); sources.remove(a); requests.install(quad(a),tile: a); try publish(&requests,to: &sources)
    XCTAssertFalse(sources.isCurrent(live,visible: [a,b,filled]))
    let empty = try XCTUnwrap(sources.snapshot(visible: [])).dependencies(for: [])
    sources.reset(); XCTAssertFalse(sources.isCurrent(empty,visible: [])); XCTAssertEqual(sources.metrics.bytes,0)
  }

  func testLeaseMergeRejectsMixedVersionsMissingOwnershipAndLODOverlap() throws {
    let tile = TerrainTile(x: 0,z: 0,size: 2), child = TerrainTile(x: 0,z: 0,fullDetail: true)
    var (requests,sources) = try fixture([tile:quad(tile)])
    let old = try XCTUnwrap(sources.snapshot(visible: [tile])).dependencies(for: [tile.coordinate])
    let missing = try XCTUnwrap(sources.snapshot(visible: [])).dependencies(for: [tile.coordinate])
    XCTAssertNil(old.merging(missing))
    requests.install(quad(tile,depth: 8),tile: tile); try publish(&requests,to: &sources)
    let next = try XCTUnwrap(sources.snapshot(visible: [tile])).dependencies(for: [tile.coordinate])
    XCTAssertNil(old.merging(next)); XCTAssertNotNil(next.merging(next))
    requests.install(quad(child),tile: child); try publish(&requests,to: &sources)
    XCTAssertNil(sources.snapshot(visible: [tile,child]))
    let fine = try XCTUnwrap(sources.snapshot(visible: [child])).dependencies(for: [child.coordinate])
    XCTAssertNil(next.merging(fine))
    let (_,other) = try fixture([child:quad(child)])
    XCTAssertNil(fine.merging(try XCTUnwrap(other.snapshot(visible: [child])).dependencies(for: [])))
  }

  func testRegistryLimitsCannotLeaveStaleMetadataAfterRefusal() throws {
    let tile = TerrainTile(x: 0,z: 0), other = TerrainTile(x: 8,z: 0)
    let geometry = quad(tile)
    let bytes = geometry.samples.count*MemoryLayout<WaterGeometry.Sample>.stride + 6*MemoryLayout<UInt32>.stride
    var (requests,sources) = try fixture([tile:geometry],limit: .init(entryLimit: 1,byteLimit: bytes))
    XCTAssertEqual(sources.metrics.bytes,bytes)
    requests.install(.init(),tile: other); try publish(&requests,to: &sources)
    XCTAssertNil(sources.snapshot(visible: [tile,other])); XCTAssertEqual(sources.metrics.refused,1)
    var larger = geometry; larger.shallowIndices += geometry.shallowIndices
    requests.install(larger,tile: tile); try publish(&requests,to: &sources)
    XCTAssertNil(sources.snapshot(visible: [tile])); XCTAssertEqual(sources.metrics.bytes,0)
    XCTAssertEqual(sources.metrics.entries,0); XCTAssertEqual(sources.metrics.refused,2)
    requests.install(.init(),tile: tile); try publish(&requests,to: &sources)
    XCTAssertNotNil(sources.snapshot(visible: [tile])); XCTAssertEqual(sources.metrics.entries,1)
  }

  func testReaderPreservesActualSamplesTopologyAndDepthBandAcrossPlanetStylesAndLODs() throws {
    var wetCells = 0
    for style in PlanetStyle.allCases {
      let terrain = TerrainGenerator(seed: 1667327165707871140,style: style)
      let tiles = [TerrainTile(x: -1,z: -1,fullDetail: true)] + [1,2,4,8,16,32].map {TerrainTile(x: -$0,z: -$0,size: $0)}
      for tile in tiles {
        let water = tile.fullDetail ? WaterGeometry(WaterPatch.build(terrain.generate(tile.coordinate),terrain: terrain))
          : TerrainSurface.build(tile,terrain: terrain,measureError: false).water
        let (_,sources) = try fixture([tile:water]), snapshot = try XCTUnwrap(sources.snapshot(visible: [tile]))
        var reader = WaterSurfaceSources.Reader(snapshot)
        let cells = try XCTUnwrap(reader.originalCells(for: tile))
        XCTAssertEqual(cells.count,(water.shallowIndices.count+water.deepIndices.count)/6)
        for shallow in [true,false] {
          let indices = shallow ? water.shallowIndices:water.deepIndices
          for i in stride(from: 0,to: indices.count,by: 6) {
            let vertices = [indices[i],indices[i+1],indices[i+2],indices[i+5]].map {water.samples[Int($0)]}
            let origin = vertices[0].position
            let cell = try XCTUnwrap(reader.cell(at: .init(tile.x*16+Int(origin.x),tile.z*16+Int(origin.y))))
            XCTAssertEqual(cell.shallow,shallow)
            XCTAssertEqual(cell.corners,vertices.map {R.Sample(depth: $0.depth,body: $0.body,wet: true)})
            wetCells += 1
          }
        }
        XCTAssertNil(reader.failure); XCTAssertEqual(reader.lease.sourceCount,1)
      }
    }
    XCTAssertGreaterThan(wetCells,1000)
  }

  func testReaderRejectsMalformedAndUnsupportedTopologyInsteadOfInventingDryCoverage() throws {
    let tile = TerrainTile(x: 0,z: 0,fullDetail: true), good = quad(tile)
    var bad: [WaterGeometry] = []
    var value = good; value.shallowIndices[0] = 99; bad.append(value)
    value = good; value.shallowIndices.removeLast(); bad.append(value)
    value = good; value.shallowIndices[3] = 0; bad.append(value)
    value = good; value.deepIndices = value.shallowIndices; bad.append(value)
    bad.append(quad(tile,step: 2)); bad.append(quad(tile,depth: -.infinity))
    bad.append(quad(tile,body: .init(id: 0,kind: .river,level: 20,current: [.nan,0,0])))
    value = good; value.samples[0] = .init(position: [.nan,0],depth: 3,body: .ocean); bad.append(value)
    for geometry in bad {
      let (_,sources) = try fixture([tile:geometry])
      var reader = WaterSurfaceSources.Reader(try XCTUnwrap(sources.snapshot(visible: [tile])))
      XCTAssertNil(reader.cell(at: .init(8,8))); XCTAssertEqual(reader.failure,.invalidTopology)
      XCTAssertEqual(reader.decodedCells,0); XCTAssertEqual(reader.byteCount,0)
    }
  }

  func testReaderBoundsCancellationAndUnknownWaterAreExplicit() async throws {
    let tile = TerrainTile(x: 0,z: 0,fullDetail: true), (_,sources) = try fixture([tile:quad(tile)])
    let snapshot = try XCTUnwrap(sources.snapshot(visible: [tile]))
    for limits in [WaterSurfaceSources.Reader.Limits(tiles: 0),.init(cells: 0),.init(readChunks: 0),.init(bytes: 0)] {
      var reader = WaterSurfaceSources.Reader(snapshot,limits: limits)
      XCTAssertNil(reader.cell(at: .init(0,0))); XCTAssertEqual(reader.failure,.limitExceeded)
      XCTAssertEqual(reader.decodedCells,0); XCTAssertEqual(reader.byteCount,0)
    }
    var missing = WaterSurfaceSources.Reader(snapshot)
    XCTAssertNil(missing.cell(at: .init(-1,0))); XCTAssertEqual(missing.failure,.missingSource)
    XCTAssertEqual(missing.lease.missingCount,1)
    let task = Task.detached {
      withUnsafeCurrentTask { $0?.cancel() }
      var reader = WaterSurfaceSources.Reader(snapshot)
      _ = reader.cell(at: .init(0,0)); return reader.failure
    }
    let failure = await task.value; XCTAssertEqual(failure,.cancelled)
  }

  func testActualWaterOwnerCanDifferFromTerrainLODAndSnapshotIsStableOffMainActor() async throws {
    let terrainParent = TerrainTile(x: -2,z: -2,size: 2), waterChild = TerrainTile(x: -1,z: -1,fullDetail: true)
    var (requests,sources) = try fixture([waterChild:quad(waterChild,depth: 9)])
    let snapshot = try XCTUnwrap(sources.snapshot(visible: [waterChild]))
    requests.install(.init(),tile: waterChild); try publish(&requests,to: &sources)
    let decoded = await Task.detached {
      var reader = WaterSurfaceSources.Reader(snapshot)
      let value = reader.cell(at: .init(-16,-16))
      return (value,reader.lease,self.isOnMainThread())
    }.value
    XCTAssertTrue(terrainParent.contains(waterChild.coordinate))
    XCTAssertEqual(decoded.0?.key.size,1,"Use actual water ownership, not the coarser terrain sampling stride")
    XCTAssertEqual(decoded.0?.corners?.first?.depth,9)
    XCTAssertFalse(decoded.2); XCTAssertFalse(sources.isCurrent(decoded.1,visible: [waterChild]))
    var current = WaterSurfaceSources.Reader(try XCTUnwrap(sources.snapshot(visible: [waterChild])))
    XCTAssertNil(current.cell(at: .init(-16,-16))?.corners); XCTAssertNil(current.failure)
  }
}
