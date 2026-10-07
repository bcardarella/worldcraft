import XCTest
@testable import WorldCore

final class WaterGeometryRequestsTests: XCTestCase {
  func testAChangingNeighborCannotRepeatedlyUploadAlreadyPublishedVersions() throws {
    let a=TerrainTile(x:0,z:0,fullDetail:true),b=TerrainTile(x:1,z:0,fullDetail:true),key=WaterBatchKey(a)
    var requests=WaterGeometryRequests()
    requests.install(quad(),tile:a);requests.install(quad(),tile:b)
    let first=try XCTUnwrap(requests.beginPreparation(for:key))
    requests.install(.init(),tile:b)
    XCTAssertEqual(requests.publishableTiles(in:first),[a])
    XCTAssertFalse(requests.acknowledge(first,published:[a]))
    for i in 0..<20 {
      let input=try XCTUnwrap(requests.beginPreparation(for:key))
      requests.install(i%2==0 ? quad():.init(),tile:b)
      XCTAssertTrue(requests.publishableTiles(in:input).isEmpty)
      XCTAssertFalse(requests.acknowledge(input,published:[]))
    }
    XCTAssertEqual(requests.metrics.acceptedTiles,1);XCTAssertEqual(requests.metrics.redundantCompletions,20)
    requests.install(.init(),tile:a)
    let useful=try XCTUnwrap(requests.beginPreparation(for:key))
    requests.install(quad(),tile:b)
    XCTAssertEqual(requests.publishableTiles(in:useful),[a],"A new version of that stable tile is real progress")
    XCTAssertFalse(requests.acknowledge(useful,published:[a]))
    let complete=try XCTUnwrap(requests.beginPreparation(for:key))
    XCTAssertEqual(requests.publishableTiles(in:complete),[a,b])
    XCTAssertTrue(requests.acknowledge(complete,published:[a,b]))
    XCTAssertTrue(requests.publishableTiles(in:complete).isEmpty,"A completed snapshot cannot be published twice")
  }
  func testSupersededBatchPublishesUnchangedMembersWithoutAcknowledgingNewInput() throws {
    var requests=WaterGeometryRequests()
    let a=TerrainTile(x:0,z:0,fullDetail:true),b=TerrainTile(x:1,z:0,fullDetail:true),c=TerrainTile(x:2,z:0,fullDetail:true)
    let key=WaterBatchKey(a)
    requests.install(quad(),tile:a,at:0);requests.install(quad(),tile:b,at:0)
    let old=try XCTUnwrap(requests.beginPreparation(for:key,at:1))
    requests.install(.init(),tile:b,at:1.1);requests.install(quad(),tile:c,at:1.2)
    let revision=try XCTUnwrap(requests.dirty[key])
    XCTAssertEqual(requests.publishableTiles(in:old),[a])
    XCTAssertFalse(requests.acknowledge(old,published:[a,b,c]))
    XCTAssertEqual(requests.dirty[key],revision)
    XCTAssertEqual(requests.metrics.salvagedCompletions,1)
    XCTAssertEqual(requests.metrics.acceptedTiles,1);XCTAssertEqual(requests.metrics.discardedTiles,1)
    let next=try XCTUnwrap(requests.beginPreparation(for:key,at:2))
    XCTAssertEqual(next.geometry[b],WaterGeometry())
    XCTAssertEqual(requests.publishableTiles(in:next),[a,b,c])
    XCTAssertTrue(requests.acknowledge(next,published:[a,b,c]));XCTAssertTrue(requests.dirty.isEmpty)
    XCTAssertEqual(requests.metrics(at:3).oldestPendingMilliseconds,0)
  }

  func testPartialPublicationMasksEveryStaleDrawPartAndRetainsExactCurrentVertices() throws {
    var requests=WaterGeometryRequests()
    let a=TerrainTile(x:-4,z:-8,fullDetail:true),b=TerrainTile(x:-3,z:-8,fullDetail:true)
    let key=WaterBatchKey(a)
    requests.install(quad(),tile:a);requests.install(quad(),tile:b)
    let old=try XCTUnwrap(requests.beginPreparation(for:key))
    let mesh=WaterMeshBatch(key:key,geometry:old.geometry)
    requests.install(.init(),tile:b)
    let visible=requests.publishableTiles(in:old)
    let parts=mesh.parts(visible:visible,bands:[:])
    let emitted=parts.flatMap {Array(mesh.indices[$0.indexStart..<($0.indexStart+$0.indexCount)])}
    let expected=mesh.slices.filter {$0.tile==a}.flatMap {Array(mesh.indices[$0.indexStart..<($0.indexStart+$0.indexCount)])}
    XCTAssertEqual(emitted,expected);XCTAssertEqual(emitted.count,6)
    let control=WaterMeshBatch(key:key,geometry:[a:quad()])
    for time in [0.0,7.0,123.0] {
      let environment=WorldEnvironment(elapsed:time),all=mesh.vertices(environment:environment),only=control.vertices(environment:environment)
      let indices=control.indices.map(Int.init)
      for (oldIndex,newIndex) in zip(emitted.map(Int.init),indices) {
        XCTAssertEqual(all[oldIndex].px,only[newIndex].px);XCTAssertEqual(all[oldIndex].py,only[newIndex].py)
        XCTAssertEqual(all[oldIndex].pz,only[newIndex].pz);XCTAssertEqual(all[oldIndex].normal,only[newIndex].normal)
        XCTAssertEqual(all[oldIndex].uv,only[newIndex].uv);XCTAssertEqual(all[oldIndex].optics,only[newIndex].optics)
      }
    }
  }

  func testChangedIdentityRemovalReentryAndPlanetResetNeverReviveOldTile() throws {
    var requests=WaterGeometryRequests()
    let a=tile,b=TerrainTile(x:-3,z:-8,fullDetail:true),key=WaterBatchKey(a)
    requests.install(quad(),tile:a);requests.install(.init(),tile:b)
    let old=try XCTUnwrap(requests.beginPreparation(for:key))
    requests.remove(a);requests.install(quad(),tile:a)
    XCTAssertEqual(requests.publishableTiles(in:old),[b],"Equal geometry after re-entry has a new ownership identity")
    requests.remove(b);XCTAssertTrue(requests.publishableTiles(in:old).isEmpty)
    requests = .init();requests.install(quad(),tile:a);requests.install(.init(),tile:b)
    XCTAssertTrue(requests.publishableTiles(in:old).isEmpty)
    XCTAssertFalse(requests.acknowledge(old,published:[a,b]));XCTAssertEqual(requests.dirty.count,1)
    requests.remove(a);requests.remove(b)
    XCTAssertNil(requests.beginPreparation(for:key));XCTAssertNil(requests.nextBatch(visible:[],covered:[],eye:.zero))
    XCTAssertEqual(requests.metrics(at:100).oldestPendingMilliseconds,0)
  }

  func testDryAndWetReplacementGroupKeepsParentUntilEveryCurrentChildArrives() throws {
    let parent=TerrainTile(x:0,z:0,size:8)
    let a=TerrainTile(x:0,z:0,size:4),b=TerrainTile(x:4,z:0,size:4),c=TerrainTile(x:0,z:4,size:4),d=TerrainTile(x:4,z:4,size:4)
    let children:Set<TerrainTile>=[a,b,c,d],key=WaterBatchKey(a)
    var requests=WaterGeometryRequests(),coverage=WaterPresentationCoverage(),available:Set<TerrainTile>=[parent]
    coverage.update(desired:[parent],available:available)
    for tile in children {requests.install(tile==d ? .init():quad(),tile:tile)}
    let old=try XCTUnwrap(requests.beginPreparation(for:key))
    requests.install(.init(),tile:c)
    let accepted=requests.publishableTiles(in:old)
    XCTAssertEqual(accepted,[a,b,d]);available.formUnion(accepted)
    XCTAssertFalse(requests.acknowledge(old,published:accepted))
    coverage.update(desired:children,available:available)
    XCTAssertEqual(coverage.visible,[parent],"Partial preparation must not show overlapping LODs or open holes")
    let fresh=try XCTUnwrap(requests.beginPreparation(for:key))
    available.formUnion(requests.publishableTiles(in:fresh))
    XCTAssertTrue(requests.acknowledge(fresh,published:children))
    coverage.update(desired:children,available:available)
    XCTAssertEqual(coverage.visible,children,"Both dry children must count as prepared coverage")
    coverage.update(desired:[parent],available:available)
    XCTAssertEqual(coverage.visible,[parent])
  }

  func testMissingDistantCoveragePrecedesVisibleRefinementAndHiddenPreparation() throws {
    let near=TerrainTile(x:4,z:0,fullDetail:true),hidden=TerrainTile(x:0,z:0,fullDetail:true),far=TerrainTile(x:128,z:0,size:32)
    let parent=TerrainTile(x:0,z:0,size:32)
    var requests=WaterGeometryRequests()
    for t in [near,hidden,far] {requests.install(quad(),tile:t,at:0)}
    XCTAssertEqual(requests.nextBatch(visible:[near,far],covered:[parent],eye:.zero,at:0.5),WaterBatchKey(far))
    let partial=TerrainTile(x:128,z:0,size:16)
    XCTAssertEqual(requests.nextBatch(visible:[near,far],covered:[parent,partial],eye:.zero,at:0.5),WaterBatchKey(far),
      "One available child does not cover its entire wanted parent")
    let quadrants:Set<TerrainTile>=[partial,.init(x:144,z:0,size:16),.init(x:128,z:16,size:16),.init(x:144,z:16,size:16)]
    XCTAssertEqual(requests.nextBatch(visible:[near,far],covered:quadrants.union([parent]),eye:.zero,at:0.5),WaterBatchKey(near))
    XCTAssertEqual(requests.metrics.coverageSelections,2);XCTAssertEqual(requests.metrics.visibleSelections,1)
  }

  func testAgeSurvivesRepeatedEditsAndAHotBatchCannotStarveOtherRegions() throws {
    let hot=TerrainTile(x:0,z:0,fullDetail:true)
    let far=[TerrainTile(x:32,z:0,size:16),.init(x:64,z:0,size:16),.init(x:96,z:0,size:16)]
    var requests=WaterGeometryRequests(),served=Set<WaterBatchKey>()
    for t in [hot]+far {requests.install(quad(),tile:t,at:0)}
    for i in 1...32 {
      let time=Double(i)*0.25
      requests.install(i%2==0 ? quad():.init(),tile:hot,at:time)
      let key=try XCTUnwrap(requests.nextBatch(visible:[hot],covered:[],eye:.zero,at:time))
      let input=try XCTUnwrap(requests.beginPreparation(for:key,at:time))
      if key==WaterBatchKey(hot) {
        requests.install(i%2==0 ? .init():quad(),tile:hot,at:time+0.01)
        XCTAssertFalse(requests.acknowledge(input,published:[]))
      } else {
        served.insert(key);XCTAssertTrue(requests.acknowledge(input,published:Set(input.geometry.keys)))
      }
      if served.count==3 {break}
    }
    XCTAssertEqual(served,Set(far.map(WaterBatchKey.init)))
    XCTAssertGreaterThanOrEqual(requests.metrics.agedSelections,3)
    XCTAssertGreaterThan(requests.metrics(at:8).oldestPendingMilliseconds,7000,
      "An edit changes content but must not conceal the pending age")
  }

  func testStrictDiagnosticModeKeepsWholeBatchAndNearestOnlyPolicy() throws {
    let hot=TerrainTile(x:0,z:0,fullDetail:true),other=TerrainTile(x:1,z:0,fullDetail:true),far=TerrainTile(x:128,z:0,size:32)
    var strict=WaterGeometryRequests(acceptsPartialCompletions:false,prioritizesCoverage:false)
    strict.install(quad(),tile:hot,at:0);strict.install(quad(),tile:other,at:0);strict.install(quad(),tile:far,at:0)
    let input=try XCTUnwrap(strict.beginPreparation(for:WaterBatchKey(hot),at:1))
    strict.install(.init(),tile:other,at:2)
    XCTAssertTrue(strict.publishableTiles(in:input).isEmpty)
    XCTAssertFalse(strict.acknowledge(input,published:[hot]))
    XCTAssertEqual(strict.nextBatch(visible:[far],covered:[],eye:.zero,at:10),WaterBatchKey(hot))
    XCTAssertFalse(strict.metrics.acceptsPartialCompletions);XCTAssertFalse(strict.metrics.prioritizesCoverage)
  }

  func testIdenticalReinstallPreservesSnapshotAndFailedPublicationDoesNotClearWork() throws {
    var requests=WaterGeometryRequests()
    requests.install(quad(),tile:tile,at:0)
    let key=WaterBatchKey(tile),input=try XCTUnwrap(requests.beginPreparation(for:WaterBatchKey(tile),at:1))
    for _ in 0..<20 {XCTAssertFalse(requests.install(quad(),tile:tile,at:2))}
    XCTAssertEqual(requests.publishableTiles(in:input),[tile])
    // Resource creation failed: no successful acknowledgment is made.
    XCTAssertEqual(requests.dirty[key],input.revision)
    XCTAssertEqual(requests.metrics(at:3).oldestPendingMilliseconds,3000)
    let retry=try XCTUnwrap(requests.beginPreparation(for:key,at:4))
    XCTAssertEqual(retry.geometry,input.geometry)
    XCTAssertTrue(requests.acknowledge(retry,published:[tile]));XCTAssertTrue(requests.dirty.isEmpty)
  }
  private let tile = TerrainTile(x: -4, z: -8, fullDetail: true)
  private func quad(_ body: WaterBody = .ocean) -> WaterGeometry {
    var result = WaterGeometry()
    result.samples = [[0, 0], [0, 16], [16, 0], [16, 16]].map {
      .init(position: $0, depth: 4, body: body)
    }
    result.shallowIndices = [0, 1, 2, 2, 1, 3]
    return result
  }

  func testRepeatedPlantPublicationsPreservePendingRevisionAndLiveAnimation() throws {
    var requests = WaterGeometryRequests()
    let geometry = quad(), key = WaterBatchKey(tile)
    XCTAssertTrue(requests.install(geometry, tile: tile))
    let revision = try XCTUnwrap(requests.dirty[key])
    let batch = WaterMeshBatch(key: key, geometry: requests.snapshot(for: key))
    for _ in 0..<60 { XCTAssertFalse(requests.install(quad(), tile: tile)) }
    XCTAssertEqual(requests.dirty[key], revision, "An in-flight batch must remain publishable")
    XCTAssertTrue(requests.acknowledge(key, revision: revision))
    XCTAssertFalse(requests.install(quad(), tile: tile))
    XCTAssertTrue(requests.dirty.isEmpty, "A published batch needs no replacement for identical inputs")
    XCTAssertEqual(requests.triangleCount, 2); XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.metrics.geometryUpdates, 1); XCTAssertEqual(requests.metrics.identicalUpdates, 61)

    var environment = WorldEnvironment(elapsed: 13)
    let before = batch.vertices(environment: environment)
    environment.disturbWater(atX: tile.origin.x, z: tile.origin.z, body: .ocean, energy: 0.24)
    environment.advance(0.25)
    let after = batch.vertices(environment: environment)
    XCTAssertNotEqual(before.map(\.py), after.map(\.py))
    XCTAssertNotEqual(before.map(\.uv), after.map(\.uv))
    for (source, vertex) in zip(batch.sources, after) {
      let expected = environment.water(atX: key.origin.x + source.geometry.x,
        z: key.origin.z + source.geometry.y, depth: source.geometry.z, body: .ocean)
      XCTAssertEqual(vertex.py, expected.height, accuracy: 0.00001)
    }
    // The original whole-batch acknowledgment API also records published
    // versions, so a later partial completion cannot duplicate those uploads.
    let neighbor=TerrainTile(x:tile.x+1,z:tile.z,fullDetail:true)
    requests.install(quad(),tile:neighbor)
    let input=try XCTUnwrap(requests.beginPreparation(for:key))
    requests.install(.init(),tile:neighbor)
    XCTAssertTrue(requests.publishableTiles(in:input).isEmpty)
  }

  func testEveryStaticInputInvalidatesAndObsoleteCompletionCannotAcknowledgeEdit() throws {
    let original = quad(), key = WaterBatchKey(tile)
    var variants: [WaterGeometry] = []
    for field in 0..<7 {
      var changed = original, sample = original.samples[0], body = sample.body
      switch field {
      case 0: sample = .init(position: sample.position + [0.5, 0], depth: sample.depth, body: body)
      case 1: sample = .init(position: sample.position, depth: sample.depth + 1, body: body)
      case 2: body.id = 42
      case 3: body.kind = .river
      case 4: body.level += 1
      case 5: body.current = [1, 0, 2]
      default: body.current = [0, 1, 0]
      }
      if field >= 2 { sample = .init(position: sample.position, depth: sample.depth, body: body) }
      changed.samples[0] = sample; variants.append(changed)
    }
    var deep = original; deep.deepIndices = deep.shallowIndices; deep.shallowIndices = []; variants.append(deep)
    var topology = original; topology.shallowIndices = [0, 1, 3]; variants.append(topology)
    variants.append(.init())
    for changed in variants {
      var requests = WaterGeometryRequests()
      requests.install(original, tile: tile)
      let oldRevision = try XCTUnwrap(requests.dirty[key]), snapshot = requests.snapshot(for: key)
      XCTAssertTrue(requests.install(changed, tile: tile))
      let newRevision = try XCTUnwrap(requests.dirty[key])
      XCTAssertNotEqual(oldRevision, newRevision)
      XCTAssertFalse(requests.acknowledge(key, revision: oldRevision))
      XCTAssertEqual(requests.dirty[key], newRevision)
      XCTAssertEqual(snapshot[tile], original, "The worker owns an immutable old snapshot")
      XCTAssertEqual(requests.snapshot(for: key)[tile], changed)
      XCTAssertTrue(requests.acknowledge(key, revision: newRevision))
      XCTAssertEqual(requests.count, changed.isEmpty ? 0 : 1)
      XCTAssertEqual(requests.triangleCount, (changed.shallowIndices.count + changed.deepIndices.count) / 3)
    }
  }

  func testRemovalReentryAndDryCoverageRetainBatchOwnership() throws {
    let neighbor = TerrainTile(x: -3, z: -8, fullDetail: true), key = WaterBatchKey(tile)
    var requests = WaterGeometryRequests()
    requests.install(quad(), tile: tile)
    requests.install(.init(), tile: neighbor)
    let first = try XCTUnwrap(requests.dirty[key])
    XCTAssertEqual(Set(requests.snapshot(for: key).keys), [tile, neighbor], "Dry tiles are real coverage")
    requests.remove(tile)
    let dryRevision = try XCTUnwrap(requests.dirty[key])
    XCTAssertFalse(requests.acknowledge(key, revision: first))
    let dry = WaterMeshBatch(key: key, geometry: requests.snapshot(for: key))
    XCTAssertEqual(dry.tiles, [neighbor]); XCTAssertTrue(dry.indices.isEmpty)
    XCTAssertEqual(requests.count, 0); XCTAssertEqual(requests.triangleCount, 0)
    requests.remove(tile) // Removing twice must not cancel the pending dry replacement.
    XCTAssertEqual(requests.dirty[key], dryRevision)
    requests.remove(neighbor)
    XCTAssertTrue(requests.dirty.isEmpty); XCTAssertTrue(requests.snapshot(for: key).isEmpty)
    requests.install(.init(), tile: neighbor)
    XCTAssertNotEqual(requests.dirty[key], dryRevision, "Re-entry needs a new owner even when dry")
    XCTAssertFalse(requests.acknowledge(key, revision: dryRevision))
    let reentry = try XCTUnwrap(requests.dirty[key])
    requests = .init() // Planet reset must invalidate outstanding jobs.
    requests.install(.init(), tile: neighbor)
    XCTAssertFalse(requests.acknowledge(key, revision: reentry))
    XCTAssertEqual(requests.metrics.requestedTiles, 1); XCTAssertEqual(requests.metrics.identicalUpdates, 0)
  }

  func testComparisonModeKeepsEquivalentGeometryAndCounts() throws {
    var reused = WaterGeometryRequests(), rebuilt = WaterGeometryRequests(coalescesIdentical: false)
    let key = WaterBatchKey(tile)
    for i in 0..<30 {
      let value = i % 7 == 0 ? WaterGeometry() : quad()
      reused.install(value, tile: tile); rebuilt.install(value, tile: tile)
      XCTAssertEqual(reused.snapshot(for: key), rebuilt.snapshot(for: key))
      XCTAssertEqual(reused.count, rebuilt.count); XCTAssertEqual(reused.triangleCount, rebuilt.triangleCount)
    }
    XCTAssertGreaterThan(reused.metrics.identicalUpdates, 0)
    XCTAssertEqual(rebuilt.metrics.geometryUpdates, 30); XCTAssertEqual(rebuilt.metrics.identicalUpdates, 0)
    XCTAssertFalse(rebuilt.metrics.coalescesIdentical)
  }
}
