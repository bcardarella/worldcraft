import XCTest
@testable import WorldCore

final class WaterSurfaceRefinementTests: XCTestCase {
  private typealias R = WaterSurfaceRefinement
  private func input(_ p: R.Point, kind: WaterBodyKind = .ocean, changed: Bool = false) -> R.Sample {
    let delta: Float = changed && (-4...0).contains(p.x) && (0...4).contains(p.z) ? 3 : 0
    return .init(depth:Float((abs(p.x)+abs(p.z))%7)+2+delta,
      body:.init(id:9,kind:kind,level:20+Float(p.x+p.z)*0.03,current:[0.7,0,0.2]),wet:true)
  }
  private func cell(_ p: R.Point, unequal: Bool = false, kind: WaterBodyKind = .ocean) -> R.Cell {
    let size=unequal && p.x>=0 ? 8:4
    let key=R.CellKey(x:floorDivide(p.x,by:size)*size,z:floorDivide(p.z,by:size)*size,size:size)
    return .init(key:key,corners:key.corners.map {input($0,kind:kind)},shallow:false)
  }
  private func ready(_ outcome: R.Outcome, file: StaticString = #filePath, line: UInt = #line) throws -> R.Result {
    guard case let .ready(result)=outcome else {XCTFail("Unexpected outcome: \(outcome)",file:file,line:line);throw Failure.notReady}
    return result
  }
  private enum Failure: Error {case notReady}
  private struct Edge: Hashable {
    let a,b:R.Point
    init(_ a:R.Point,_ b:R.Point) {
      if (a.z,a.x)<(b.z,b.x) {self.a=a;self.b=b} else {self.a=b;self.b=a}
    }
  }
  private func original(_ cell:R.Cell)->WaterGeometry {
    guard let corners=cell.corners else {return .init()}
    var result=WaterGeometry()
    result.samples=zip(cell.key.corners,corners).map {p,v in
      .init(position:[Float(p.x-cell.key.x),Float(p.z-cell.key.z)],depth:v.depth,body:v.body)
    }
    if cell.shallow {result.shallowIndices=[0,1,2,2,1,3]} else {result.deepIndices=[0,1,2,2,1,3]}
    return result
  }
  private func point(_ vertex:WaterGeometry.Sample,_ key:R.CellKey)->R.Point {
    .init(key.x+Int(vertex.position.x),key.z+Int(vertex.position.y))
  }
  private func boundary(_ mesh:WaterGeometry,_ key:R.CellKey)->[Edge] {
    var counts:[Edge:Int]=[:]
    let indices=mesh.shallowIndices+mesh.deepIndices
    for i in stride(from:0,to:indices.count,by:3) {
      for j in 0..<3 {
        let a=point(mesh.samples[Int(indices[i+j])],key),b=point(mesh.samples[Int(indices[i+(j+1)%3])],key)
        counts[.init(a,b),default:0]+=1
      }
    }
    XCTAssertTrue(counts.values.allSatisfy {$0==1 || $0==2})
    return counts.filter {$0.value==1}.map(\.key)
  }
  private func area(_ mesh:WaterGeometry)->Float {
    let indices=mesh.shallowIndices+mesh.deepIndices
    var total:Float=0
    for i in stride(from:0,to:indices.count,by:3) {
      let a=mesh.samples[Int(indices[i])].position,b=mesh.samples[Int(indices[i+1])].position,c=mesh.samples[Int(indices[i+2])].position
      let cross=(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
      XCTAssertLessThan(cross,0,"Nonpositive-area or reversed water triangle")
      total-=cross*0.5
    }
    return total
  }
  private func verifyInterfaces(_ result:R.Result, source:(R.Point)->R.Cell?, environments:[WorldEnvironment]) {
    // Include untouched adjacent original cells, so checking only the output
    // cannot hide a crack where a replacement meets retained water.
    var all=result.geometry
    for key in result.geometry.keys {
      for i in 0..<key.size {for p in [R.Point(key.x-1,key.z+i),.init(key.x+key.size,key.z+i),
        .init(key.x+i,key.z-1),.init(key.x+i,key.z+key.size)] {
        if let neighbor=source(p),all[neighbor.key]==nil {all[neighbor.key]=original(neighbor)}
      }}
    }
    let ordered=all.keys.sorted {($0.z,$0.x)<($1.z,$1.x)}
    var checks=0
    for i in ordered.indices {for j in ordered.indices where j>i {
      let a=ordered[i],b=ordered[j]
      guard result.geometry[a] != nil || result.geometry[b] != nil else {continue}
      let axis:Int,constant:Int,low:Int,high:Int
      if a.x+a.size==b.x || b.x+b.size==a.x {
        axis=0;constant=max(a.x,b.x);low=max(a.z,b.z);high=min(a.z+a.size,b.z+b.size)
      } else if a.z+a.size==b.z || b.z+b.size==a.z {
        axis=1;constant=max(a.z,b.z);low=max(a.x,b.x);high=min(a.x+a.size,b.x+b.size)
      } else {continue}
      guard low<high else {continue}
      func segments(_ mesh:WaterGeometry,_ key:R.CellKey)->Set<Edge> {
        Set(boundary(mesh,key).filter {e in
          if axis==0 {return e.a.x==constant && e.b.x==constant && max(e.a.z,e.b.z)>low && min(e.a.z,e.b.z)<high}
          return e.a.z==constant && e.b.z==constant && max(e.a.x,e.b.x)>low && min(e.a.x,e.b.x)<high
        })
      }
      let left=segments(all[a]!,a),right=segments(all[b]!,b)
      XCTAssertEqual(left,right,"T-junction between \(a) and \(b)")
      func samples(_ mesh:WaterGeometry,_ key:R.CellKey)->[R.Point:WaterGeometry.Sample] {
        Dictionary(uniqueKeysWithValues:mesh.samples.map {(point($0,key),$0)})
      }
      let aa=samples(all[a]!,a),bb=samples(all[b]!,b)
      for edge in left {for p in [edge.a,edge.b] {
        guard let x=aa[p],let y=bb[p] else {XCTFail("Missing shared vertex");continue}
        XCTAssertEqual(x.depth,y.depth);XCTAssertEqual(x.body,y.body)
        for env in environments {
          let first=env.water(atX:Float(p.x),z:Float(p.z),depth:x.depth,body:x.body)
          let second=env.water(atX:Float(p.x),z:Float(p.z),depth:y.depth,body:y.body)
          XCTAssertEqual(first.height,second.height);XCTAssertEqual(first.normal,second.normal)
          XCTAssertEqual(first.foam,second.foam)
        }
        checks+=1
      }}
    }}
    XCTAssertGreaterThan(checks,0)
  }
  func testConformingEdgesPreserveWaveInputsAcrossUnequalLODsAndChangedDepths() throws {
    for kind in [WaterBodyKind.ocean,.lake,.river,.lava] {
      let source:(R.Point)->R.Cell?={self.cell($0,unequal:true,kind:kind)}
      let result=try ready(R.build(refining:[.init(-1,1)],source:source,sample:{self.input($0,kind:kind,changed:true)}))
      XCTAssertEqual(result.refined,[.init(x:-4,z:0,size:4)])
      XCTAssertGreaterThan(result.geometry.count,1)
      for (key,mesh) in result.geometry {XCTAssertEqual(area(mesh),Float(key.size*key.size))}
      var disturbed=WorldEnvironment(elapsed:61)
      disturbed.disturbWater(atX:0,z:1,body:input(.init(0,1),kind:kind).body,energy:0.3)
      disturbed.advance(1.3)
      verifyInterfaces(result,source:source,environments:[.init(elapsed:0),.init(elapsed:123.7),.init(elapsed:9999),disturbed])
      XCTAssertEqual(result.vertexCount,result.geometry.values.reduce(0) {$0+$1.samples.count})
      XCTAssertEqual(result.indexCount,result.geometry.values.reduce(0) {$0+$1.shallowIndices.count+$1.deepIndices.count})
    }
  }
  func testCollinearEdgeVerticesAreUsedWithoutDegeneratesOrChangingOriginalDiagonal() throws {
    let result=try ready(R.build(refining:[.init(0,0)],source:{self.cell($0)},sample:{self.input($0)}))
    for (key,mesh) in result.geometry where !result.refined.contains(key) {
      XCTAssertEqual(area(mesh),16)
      let indices=mesh.shallowIndices+mesh.deepIndices
      for i in stride(from:0,to:indices.count,by:3) {
        let sides=(0..<3).map {j in let p=mesh.samples[Int(indices[i+j])].position;return p.x+p.y-4}
        XCTAssertTrue(sides.allSatisfy {$0>=0} || sides.allSatisfy {$0<=0},"Crossed original diagonal")
      }
      let referenced=Set(indices.map(Int.init))
      XCTAssertEqual(referenced.count,mesh.samples.count)
    }
    verifyInterfaces(result,source:{self.cell($0)},environments:[.init(elapsed:79)])
  }
  func testJoiningBodyIdentitiesAndCurrentsRemainAuthoritativeAtSharedVertices() throws {
    func value(_ p:R.Point, changed:Bool)->R.Sample {
      let river=p.x < -2
      return .init(depth:changed && (-4...0).contains(p.x) && (0...4).contains(p.z) ? 7:3,
        body:.init(id:river ? 100:200,kind:river ? .river:.lake,
          level:20+Float(p.x)*0.03,current:river ? [0.7,0,0.2]:.zero),wet:true)
    }
    let source:(R.Point)->R.Cell?={p in
      let key=self.cell(p).key
      return .init(key:key,corners:key.corners.map {value($0,changed:false)},shallow:true)
    }
    let result=try ready(R.build(refining:[.init(-3,1)],source:source,sample:{value($0,changed:true)}))
    for (key,mesh) in result.geometry {for vertex in mesh.samples {
      let authoritative=value(point(vertex,key),changed:true)
      XCTAssertEqual(vertex.body,authoritative.body)
      XCTAssertEqual(vertex.depth,authoritative.depth)
    }}
    let ids=Set(result.geometry.values.flatMap { $0.samples.map(\.body.id) })
    XCTAssertEqual(ids,[100,200])
    verifyInterfaces(result,source:source,environments:[.init(elapsed:0),.init(elapsed:713)])
  }
  func testDryCoarseCellGainsOnlyAuthoritativeWetUnitColumnsAndDryReplacementIsExplicit() throws {
    let source:(R.Point)->R.Cell?={p in .init(key:self.cell(p).key,corners:nil,shallow:false)}
    let wet:(R.Point)->R.Sample?={p in .init(depth:2,body:.ocean,wet:(1...2).contains(p.x) && (1...2).contains(p.z))}
    let result=try ready(R.build(refining:[.init(1,1)],source:source,sample:wet))
    XCTAssertEqual(result.geometry.count,1)
    let mesh=try XCTUnwrap(result.geometry[.init(x:0,z:0,size:4)])
    XCTAssertEqual(area(mesh),4);XCTAssertEqual(mesh.shallowIndices.count,24);XCTAssertTrue(mesh.deepIndices.isEmpty)
    XCTAssertEqual(mesh.samples.count,9)
    for p in mesh.samples {XCTAssertTrue((1...3).contains(p.position.x));XCTAssertTrue((1...3).contains(p.position.y))}
    let dry=try ready(R.build(refining:[.init(1,1)],source:{self.cell($0)},sample:{p in
      let v=self.input(p);return .init(depth:v.depth,body:v.body,wet:false)
    }))
    XCTAssertTrue(try XCTUnwrap(dry.geometry[.init(x:0,z:0,size:4)]).isEmpty)
    XCTAssertFalse(dry.geometry.isEmpty,"Dropping an empty replacement would keep obsolete water")
  }
  func testOrderingDuplicatesNegativeOriginsAndCallerInputsRemainDeterministic() throws {
    let points:[R.Point]=[.init(-9,-9),.init(-4,-4),.init(-1,-1),.init(-9,-9)]
    let first=try ready(R.build(refining:points,source:{self.cell($0)},sample:{self.input($0)}))
    let second=try ready(R.build(refining:points.reversed(),source:{self.cell($0)},sample:{self.input($0)}))
    XCTAssertEqual(first.geometry,second.geometry);XCTAssertEqual(first.refined,second.refined)
    XCTAssertEqual(first.sampledPoints,second.sampledPoints);XCTAssertEqual(first.sourceCells,second.sourceCells)
    let empty=try ready(R.build(refining:[],limits:.init(cells:0,samples:0,vertices:0,indices:0),
      source:{_ in XCTFail();return nil},sample:{_ in XCTFail();return nil}))
    XCTAssertTrue(empty.geometry.isEmpty);XCTAssertEqual(empty.vertexCount,0)
  }
  func testMissingInvalidAndOverlappingSourcesNeverReturnPartialGeometry() {
    if case .missingSource=R.build(refining:[.init(1,1)],source:{_ in nil},sample:{self.input($0)}) {} else {XCTFail()}
    if case .missingSample=R.build(refining:[.init(1,1)],source:{self.cell($0)},sample:{_ in nil}) {} else {XCTFail()}
    if case .invalidSample=R.build(refining:[.init(1,1)],source:{self.cell($0)},sample:{_ in .init(depth:.nan,body:.ocean,wet:true)}) {} else {XCTFail()}
    if case .invalidSource=R.build(refining:[.init(1,1)],source:{_ in .init(key:.init(x:0,z:0,size:3),corners:nil,shallow:false)},sample:{self.input($0)}) {} else {XCTFail()}
    var reads=0
    let changing:(R.Point)->R.Cell?={p in
      reads+=1;let c=self.cell(p)
      return .init(key:c.key,corners:c.corners?.map {.init(depth:$0.depth+Float(reads),body:$0.body,wet:true)},shallow:false)
    }
    if case .invalidSource=R.build(refining:[.init(1,1),.init(2,2)],source:changing,sample:{self.input($0)}) {} else {XCTFail()}
    // A queried neighbour with an overlapping, larger cell is not a partition.
    let overlapping:(R.Point)->R.Cell?={p in
      if p.x==1 && p.z==1 {return self.cell(p)}
      let k=R.CellKey(x:floorDivide(p.x,by:8)*8,z:floorDivide(p.z,by:8)*8,size:8)
      return .init(key:k,corners:k.corners.map {self.input($0)},shallow:false)
    }
    if case .invalidSource=R.build(refining:[.init(1,1)],source:overlapping,sample:{self.input($0)}) {} else {XCTFail()}
  }
  func testAdmissionLimitsAreTransactionalAndNoPartialCellCanBePublished() throws {
    for limit in [R.Limits(cells:1),.init(samples:2),.init(vertices:2),.init(indices:2)] {
      if case .limitExceeded=R.build(refining:[.init(1,1)],limits:limit,source:{self.cell($0)},sample:{self.input($0)}) {} else {XCTFail()}
    }
    let result=try ready(R.build(refining:[.init(1,1)],source:{self.cell($0)},sample:{self.input($0)}))
    let exact=try ready(R.build(refining:[.init(1,1)],limits:.init(cells:result.sourceCells,samples:result.sampledPoints,
      vertices:result.vertexCount,indices:result.indexCount),source:{self.cell($0)},sample:{self.input($0)}))
    XCTAssertEqual(result.geometry,exact.geometry)
  }
  func testUnboundedWaveInputChangesStopAtTheSourceCellLimit() {
    // An infinitely long changed-depth strip causes incident replacements to
    // propagate indefinitely. It must fail, not publish only the first strip.
    let source:(R.Point)->R.Cell?={p in
      let key=self.cell(p).key,v=R.Sample(depth:3,body:.init(id:7,kind:.river,level:20,current:[0.7,0,0.2]),wet:true)
      return .init(key:key,corners:[v,v,v,v],shallow:true)
    }
    let result=R.build(refining:[.init(-3,1)],limits:.init(cells:64),source:source,sample:{p in
      .init(depth:(-4...0).contains(p.x) ? 7:3,body:.init(id:7,kind:.river,level:20,current:[0.7,0,0.2]),wet:true)
    })
    if case .limitExceeded=result {} else {XCTFail("Unbounded change returned \(result)")}
  }
  func testCancellationDuringSourceOrSampleLookupReturnsNoPartialResult() async {
    for duringSample in [false,true] {
      let cancelled=await Task.detached {
        let key=R.CellKey(x:0,z:0,size:4),v=R.Sample(depth:2,body:.ocean,wet:true)
        let result=R.build(refining:[.init(1,1)],source:{_ in
          if !duringSample {withUnsafeCurrentTask {$0?.cancel()}}
          return .init(key:key,corners:[v,v,v,v],shallow:true)
        },sample:{_ in withUnsafeCurrentTask {$0?.cancel()};return v})
        if case .cancelled=result {return true};return false
      }.value
      XCTAssertTrue(cancelled)
    }
  }

  func testDryColumnsDoNotRequireWaveSamplesIncludingAnEmptyReplacement() throws {
    var queries: [R.Point] = []
    let result = try ready(R.build(refining: [.init(1,1)], limits: .init(samples: 0),
      source: { self.cell($0) }, occupancy: { p in queries.append(p); return false },
      sample: { _ in XCTFail("No water will be drawn"); return nil }))
    XCTAssertEqual(result.geometry.count, 1)
    XCTAssertTrue(try XCTUnwrap(result.geometry[.init(x:0,z:0,size:4)]).isEmpty)
    XCTAssertEqual(result.surveyedColumns, 16)
    XCTAssertEqual(Set(queries), Set((0..<4).flatMap { z in (0..<4).map { R.Point($0,z) } }))
    XCTAssertEqual(result.sampledPoints, 0)
    XCTAssertEqual(result.vertexCount, 0)
    XCTAssertEqual(result.indexCount, 0)
  }

  func testIsolatedWetColumnSamplesOnlyItsFourDrawnVertices() throws {
    let needed: Set<R.Point> = [.init(1,1), .init(1,2), .init(2,1), .init(2,2)]
    var requests: [R.Point] = []
    let result = try ready(R.build(refining: [.init(1,1)], limits: .init(samples: 4),
      source: { .init(key:self.cell($0).key,corners:nil,shallow:false) },
      occupancy: { $0 == .init(1,1) }, sample: { p in
        requests.append(p)
        guard needed.contains(p) else { XCTFail("Unused dry vertex requested"); return nil }
        // The separate occupancy callback owns wetness, including at a dry
        // corner of a wet quad. This member must not affect the footprint.
        return .init(depth:2,body:.ocean,wet:false)
      }))
    XCTAssertEqual(Set(requests), needed)
    XCTAssertEqual(requests.count, 4)
    XCTAssertEqual(result.sampledPoints, 4)
    XCTAssertEqual(result.surveyedColumns, 16)
    XCTAssertEqual(area(try XCTUnwrap(result.geometry[.init(x:0,z:0,size:4)])), 1)
  }

  func testSparseBoundaryOnlyConstrainsVerticesUsedByRefinedOrRetainedWater() throws {
    let source: (R.Point) -> R.Cell? = { p in
      let cell = self.cell(p,unequal:true)
      // Water is retained east of the refined cell. Other surrounding source
      // cells are known dry, including their finer corners on its outer edge.
      return .init(key:cell.key,corners:p.x>=0 ? cell.corners:nil,shallow:false)
    }
    var requested = Set<R.Point>()
    let result = try ready(R.build(refining: [.init(-1,1)], source: source,
      occupancy: { $0 == .init(-1,1) }, sample: { p in
        requested.insert(p); return self.input(p)
      }))
    var drawn = Set<R.Point>()
    for (key,mesh) in result.geometry {
      let indices = Set(mesh.shallowIndices+mesh.deepIndices)
      for i in indices { drawn.insert(point(mesh.samples[Int(i)],key)) }
    }
    XCTAssertEqual(requested, drawn, "Every expensive sample must be used")
    XCTAssertFalse(requested.contains(.init(-4,0)), "Dry refined corner has no geometry")
    let refined = try XCTUnwrap(result.geometry[.init(x:-4,z:0,size:4)])
    let retained = try XCTUnwrap(result.geometry[.init(x:0,z:0,size:8)])
    XCTAssertEqual(area(refined), 1)
    XCTAssertEqual(area(retained), 64)
    let joined = Edge(.init(0,1),.init(0,2))
    XCTAssertTrue(boundary(refined,.init(x:-4,z:0,size:4)).contains(joined))
    XCTAssertTrue(boundary(retained,.init(x:0,z:0,size:8)).contains(joined))
    for p in [R.Point(0,1),.init(0,2)] {
      let a = try XCTUnwrap(refined.samples.first {point($0,.init(x:-4,z:0,size:4)) == p})
      let b = try XCTUnwrap(retained.samples.first {point($0,.init(x:0,z:0,size:8)) == p})
      XCTAssertEqual(a.body,b.body); XCTAssertEqual(a.depth,b.depth)
    }
  }

  func testUnknownOccupancyAndMissingUsedWaveDataRejectTheWholeTransaction() {
    let source: (R.Point) -> R.Cell? = { self.cell($0) }
    let unknown = R.build(refining:[.init(1,1)],source:source,
      occupancy:{ $0 == .init(2,2) ? nil:false },sample:{ _ in XCTFail();return nil })
    if case .missingOccupancy(.init(2,2)) = unknown {} else { XCTFail("\(unknown)") }
    let missing = R.build(refining:[.init(1,1)],source:source,occupancy:{$0 == .init(1,1)},sample:{ p in
      p == .init(2,2) ? nil:self.input(p)
    })
    if case .missingSample(.init(2,2)) = missing {} else { XCTFail("\(missing)") }
  }

  func testColumnAndVertexBudgetsAreIndependentAndCancellationStopsSurvey() async throws {
    let source: (R.Point) -> R.Cell? = { self.cell($0) }
    let stopped = R.build(refining:[.init(1,1)],limits:.init(columns:15,samples:0),
      source:source,occupancy:{_ in false},sample:{_ in XCTFail();return nil})
    if case .limitExceeded = stopped {} else { XCTFail("\(stopped)") }
    let exact = try ready(R.build(refining:[.init(1,1)],limits:.init(columns:16,samples:0),
      source:source,occupancy:{_ in false},sample:{_ in XCTFail();return nil}))
    XCTAssertEqual(exact.surveyedColumns,16)
    let cancelled = await Task.detached {
      let key=R.CellKey(x:0,z:0,size:4)
      let outcome=R.build(refining:[.init(1,1)],source:{_ in .init(key:key,corners:nil,shallow:false)},
        occupancy:{_ in withUnsafeCurrentTask {$0?.cancel()};return false},sample:{_ in nil})
      if case .cancelled = outcome {return true};return false
    }.value
    XCTAssertTrue(cancelled)
  }

  func testDryRefinementStillRejectsOverlappingSourceCells() {
    for reversed in [false,true] {
      var requested: [R.Point] = [.init(1,1),.init(5,1)]
      if reversed { requested.reverse() }
      let result = R.build(refining:requested,source:{ p in
        let size = p.x < 4 ? 4:8
        return .init(key:.init(x:0,z:0,size:size),corners:nil,shallow:false)
      },occupancy:{_ in false},sample:{_ in XCTFail();return nil})
      if case .invalidSource = result {} else { XCTFail("\(result)") }
    }
  }
}
