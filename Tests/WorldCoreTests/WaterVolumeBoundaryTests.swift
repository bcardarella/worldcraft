import XCTest
@testable import WorldCore

final class WaterVolumeBoundaryTests: XCTestCase {
  private typealias B = WaterVolumeBoundary
  private typealias P = B.Point
  private enum Failure: Error { case invalid }
  private func mask(_ x: Range<Int> = 0..<16, _ z: Range<Int> = 0..<16) -> VoxelColumnMask {
    var value=VoxelColumnMask();value.include(x:x,z:z);return value
  }
  private func ready(_ value:B.Outcome,file:StaticString = #filePath,line:UInt = #line) throws -> B.Result {
    guard case let .ready(result)=value else {XCTFail("Expected geometry: \(value)",file:file,line:line);throw Failure.invalid}
    return result
  }
  private func build(_ chunk:ChunkData,columns:VoxelColumnMask = .full,body:WaterBody?=nil,
    depth:Float=8) throws -> B.Result {
    try ready(B.build(chunk,columns:columns,body:{_ in body},sample:{_ in
      body.map {B.Sample(depth:depth,body:$0,wet:false)}
    }))
  }
  private func triangles(_ result:B.Result,_ environment:WorldEnvironment = .init()) -> [[SIMD3<Float>]] {
    let vertices=result.positions(environment:environment)
    return result.faces.flatMap { face in
      let indices=result.indices(for:face)
      return stride(from:0,to:indices.count,by:3).map {i in (0..<3).map {vertices[indices[i+$0]]}}
    }
  }
  private struct Edge:Hashable { let a,b:SIMD3<Float> }
  /// A closed oriented triangle soup cancels every directed boundary edge.
  /// This operates on final positions, independent of voxel face extraction.
  private func openEdges(_ triangles:[[SIMD3<Float>]]) -> Int {
    var edges:[Edge:Int]=[:]
    for t in triangles {for i in 0..<3 {
      let a=t[i],b=t[(i+1)%3];if a==b {continue}
      edges[.init(a:a,b:b),default:0] += 1
      edges[.init(a:b,b:a),default:0] -= 1
    }}
    return edges.values.filter {$0 != 0}.count
  }
  private func signedVolume(_ triangles:[[SIMD3<Float>]]) -> Double {
    triangles.reduce(0) {sum,t in
      let a=t[0],b=t[1],c=t[2]
      return sum+(Double(a.x)*(Double(b.y)*Double(c.z)-Double(b.z)*Double(c.y))
        + Double(a.y)*(Double(b.z)*Double(c.x)-Double(b.x)*Double(c.z))
        + Double(a.z)*(Double(b.x)*Double(c.y)-Double(b.y)*Double(c.x)))/6
    }
  }
  func testStaticEditedVolumesCloseCavitiesAndHaveCorrectUnionVolume() throws {
    var chunk=ChunkData(coordinate:.init(-3,7)), count=0
    // Disconnected pools, a hollow underwater cavity and uneven floors/tops.
    for z in 2..<11 {for x in 1..<14 {for y in -7..<12 {
      let shell=(2..<8).contains(x) && (3..<9).contains(z) && (-3..<7).contains(y)
      let cavity=(3..<7).contains(x) && (4..<8).contains(z) && (-2..<6).contains(y)
      let other=x>=10 && y>=x-10 && y<z
      if (shell && !cavity) || other {chunk[x,y,z] = .water;count += 1}
    }}}
    // Real stone contacts must not be mistaken for proof of rendered burial.
    chunk[1,0,4] = .stone
    let result=try build(chunk), tris=triangles(result)
    XCTAssertTrue(result.waves.isEmpty);XCTAssertFalse(result.unresolvedSurfaceColumns.isEmpty)
    XCTAssertTrue(result.liquidDependencies.isEmpty);XCTAssertTrue(result.openSnapshotCells.isEmpty)
    XCTAssertEqual(openEdges(tris),0)
    XCTAssertEqual(signedVolume(tris),Double(count),accuracy:1e-9)
    // Confirm that the geometric validator detects a hole and a flipped face.
    XCTAssertGreaterThan(openEdges(Array(tris.dropFirst())),0)
    var reversed=tris;reversed[0].swapAt(1,2)
    XCTAssertGreaterThan(openEdges(reversed),0)
  }
  func testObliqueUnderwaterRaysMatchIndependentVoxelVolumeIntersections() throws {
    var chunk=ChunkData(coordinate:.init(0,0)),cells:[SIMD3<Double>]=[]
    for z in 1..<12 {for x in 1..<12 {for y in 1..<10 {
      let shell=(3..<8).contains(x) && (3..<8).contains(z) && (1..<6).contains(y)
      let cavity=(4..<7).contains(x) && (4..<7).contains(z) && (2..<5).contains(y)
      let pool=x>=10 && z>=8 && y>=8
      if (shell && !cavity) || pool {chunk[x,y,z] = .water;cells.append([Double(x),Double(y),Double(z)])}
    }}}
    let mesh=triangles(try build(chunk)).map {$0.map {SIMD3<Double>($0)}}
    func dot(_ a:SIMD3<Double>,_ b:SIMD3<Double>)->Double {a.x*b.x+a.y*b.y+a.z*b.z}
    func cross(_ a:SIMD3<Double>,_ b:SIMD3<Double>)->SIMD3<Double> {[a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x]}
    func voxelHit(_ origin:SIMD3<Double>,_ direction:SIMD3<Double>)->Double? {
      var intervals:[(Double,Double)]=[]
      for cell in cells {
        var low = -Double.infinity,high=Double.infinity
        for axis in 0..<3 {
          let a=(cell[axis]-origin[axis])/direction[axis],b=(cell[axis]+1-origin[axis])/direction[axis]
          low=max(low,min(a,b));high=min(high,max(a,b))
        }
        if high>=max(0,low) {intervals.append((low,high))}
      }
      intervals.sort {$0.0<$1.0}
      guard var first=intervals.first else {return nil}
      for next in intervals.dropFirst() {
        if next.0>first.1+1e-9 {break}
        first.1=max(first.1,next.1)
      }
      return first.0>=0 ? first.0:first.1
    }
    func meshHit(_ origin:SIMD3<Double>,_ direction:SIMD3<Double>)->Double? {
      var closest:Double?
      for t in mesh {
        let e1=t[1]-t[0],e2=t[2]-t[0],p=cross(direction,e2),det=dot(e1,p)
        if abs(det)<1e-10 {continue}
        let s=origin-t[0],u=dot(s,p)/det
        if u < -1e-9 || u>1+1e-9 {continue}
        let q=cross(s,e1),v=dot(direction,q)/det
        if v < -1e-9 || u+v>1+1e-9 {continue}
        let hit=dot(e2,q)/det
        if hit>=0 {closest=min(closest ?? hit,hit)}
      }
      return closest
    }
    let origins:[SIMD3<Double>]=[[0.37,0.29,0.41],[6.23,3.15,6.11],[3.21,1.41,3.31],
      [10.1,8.2,8.3],[14.4,12.3,14.2],[6.1,-4.1,6.2]]
    let directions:[SIMD3<Double>]=[[1,0.31,0.17],[0.15,1,-0.2],[0.1,-0.27,1],
      [-0.7,-0.8,-0.91],[-1,0.23,0.57],[0.22,-1,0.39],[0.91,0.97,-1]]
    for origin in origins {for raw in directions {
      let direction=raw/sqrt(dot(raw,raw)),a=voxelHit(origin,direction),b=meshHit(origin,direction)
      XCTAssertEqual(a==nil,b==nil)
      if let a,let b {XCTAssertEqual(a,b,accuracy:1e-8)}
    }}
  }
  func testAnimatedSidesAndBottomRemainClosedWhenWaveCrossesTheFloor() throws {
    let bodies:[WaterBody] = [.ocean,.init(id:3,kind:.lake,level:23.4),
      .init(id:4,kind:.river,level:23.15,current:[0.5,0,0.2]),.lava]
    for body in bodies {
      var chunk=ChunkData(coordinate:.init(-1,-1))
      let material:Block=body.kind == .lava ? .lava:.water
      for z in 3..<6 {for x in 4..<7 {chunk[x,23,z]=material}}
      let result=try build(chunk,body:body,depth:7)
      XCTAssertTrue(result.unresolvedSurfaceColumns.isEmpty);XCTAssertTrue(result.surfaceTransitions.isEmpty)
      for time:Double in [0,67,191,419,703,9999.9,10000.1] {
        var environment=WorldEnvironment(elapsed:time)
        for _ in 0..<24 {environment.disturbWater(atX:-11.4,z:-12.8,body:body,energy:0.35)}
        environment.advance(0.47)
        let tris=triangles(result,environment)
        XCTAssertEqual(openEdges(tris),0)
        // Integrate thickness over each independent SW–NE top triangle.
        // The bottom shares the same diagonal and is min(floor, wave).
        var expected=0.0
        for z in 3..<6 {for x in 4..<7 {
          let heights=[(x,z),(x,z+1),(x+1,z),(x+1,z+1)].map {u,v in
            max(0,Double(environment.water(atX:Float(u-16),z:Float(v-16),depth:7,body:body).height)-23)
          }
          expected += (heights[0]+2*heights[1]+2*heights[2]+heights[3])/6
        }}
        XCTAssertEqual(signedVolume(tris),expected,accuracy:0.00001)
        XCTAssertGreaterThanOrEqual(signedVolume(tris),-0.00001)
      }
    }
  }
  func testAnimatedTopMatchesRefinementWithOneOwnerAndCanonicalSamples() throws {
    let coordinate=ChunkCoordinate(-1,2), ox=coordinate.x*16,oz=coordinate.z*16
    let body=WaterBody(id:7,kind:.river,level:23.375,current:[0.6,0,0.1])
    var chunk=ChunkData(coordinate:coordinate)
    for z in 1..<4 {for x in 2..<5 {for y in 20..<24 {chunk[x,y,z] = .water}}}
    func wet(_ p:P)->Bool {(ox+2..<ox+5).contains(p.x) && (oz+1..<oz+4).contains(p.z)}
    func sample(_ p:P)->B.Sample {.init(depth:Float(abs(p.x+p.z)%7),body:body,wet:wet(p))}
    let result=try ready(B.build(chunk,columns:.full,body:{_ in body},sample:sample))
    XCTAssertEqual(Set(result.waves.map(\.point)).count,result.waves.count)
    let points=(1..<4).flatMap {z in (2..<5).map {P(ox+$0,oz+z)}}
    let refined=WaterSurfaceRefinement.build(refining:points,source:{p in
      .init(key:.init(x:p.x,z:p.z,size:1),corners:nil,shallow:true)
    },occupancy:{wet($0)},sample:sample)
    guard case let .ready(surface)=refined else {return XCTFail("Expected unit water: \(refined)")}
    var environment=WorldEnvironment(elapsed:931.5)
    environment.disturbWater(atX:Float(ox+3),z:Float(oz+2),body:body);environment.advance(0.3)
    let positions=result.positions(environment:environment)
    func key(_ triangle:[SIMD3<Float>])->Set<SIMD3<Float>> {Set(triangle)}
    let actual=result.faces.filter {$0.role == .animatedSurface}.flatMap {f in
      let ids=result.indices(for:f)
      return stride(from:0,to:6,by:3).map {i in key((0..<3).map {
        positions[ids[i+$0]]+SIMD3<Float>(Float(ox),0,Float(oz))
      })}
    }
    let expected=surface.geometry.flatMap {cell,g in
      let positions=g.samples.map {s in SIMD3<Float>(s.position.x+Float(cell.x),
        environment.water(atX:s.position.x+Float(cell.x),z:s.position.y+Float(cell.z),depth:s.depth,body:s.body).height,
        s.position.y+Float(cell.z))}
      let indices=g.shallowIndices+g.deepIndices
      return stride(from:0,to:indices.count,by:3).map {i in key((0..<3).map {positions[Int(indices[i+$0])]})}
    }
    XCTAssertEqual(Set(actual),Set(expected));XCTAssertEqual(actual.count,18)
    XCTAssertEqual(actual.count,expected.count)
  }
  func testUnequalRiverLevelsJoinAcrossChunkBoundaryWithoutMovingTheBottom() throws {
    func body(_ p:P)->WaterBody {.init(id:91,kind:.river,
      level:23.3+Float(p.x)*0.9+Float(p.z-2)*0.21,current:[0.8,0,0])}
    var results:[B.Result]=[]
    for cx in [-1,0] {
      var chunk=ChunkData(coordinate:.init(cx,0))
      for z in -1...16 {for x in -1...16 {
        let p=P(cx*16+x,z)
        if (-3..<3).contains(p.x) && (2..<6).contains(p.z) {
          for y in 18..<Int(ceil(body(p).level)) {chunk[x,y,z] = .water}
        }
      }}
      results.append(try ready(B.build(chunk,columns:.full,body:{body($0)},
        sample:{.init(depth:5,body:body($0),wet:false)})))
    }
    for time in [0.0,311.0,9999.9] {
      var environment=WorldEnvironment(elapsed:time)
      for _ in 0..<24 {environment.disturbWater(atX:-0.4,z:3.3,body:body(P(0,3)),energy:0.35)}
      environment.advance(0.12)
      let all=results.flatMap {result in
        let offset=SIMD3<Float>(Float(result.coordinate.x*16),0,0)
        return triangles(result,environment).map {$0.map {$0+offset}}
      }
      XCTAssertEqual(openEdges(all),0,"Unequal river levels must close at the shared corner")
      var volume=0.0
      for z in 2..<6 {for x in -3..<3 {
        let h=[P(x,z),P(x,z+1),P(x+1,z),P(x+1,z+1)].map {p in
          Double(environment.water(atX:Float(p.x),z:Float(p.z),depth:5,body:body(p)).height)-18
        }
        volume += (h[0]+2*h[1]+2*h[2]+h[3])/6
      }}
      XCTAssertEqual(signedVolume(all),volume,accuracy:0.00001)
      for result in results {
        let positions=result.positions(environment:environment)
        for f in result.faces where f.direction==3 {
          for index in result.indices(for:f) {XCTAssertEqual(positions[index].y,18)}
        }
      }
    }
  }
  func testPartialOwnershipAndHaloReportExactLiquidDependencies() throws {
    var chunk=ChunkData(coordinate:.init(-2,3))
    for x in -1...16 {for y in 22..<24 {chunk[x,y,5] = .water}}
    let columns=mask(0..<8,5..<6),result=try build(chunk,columns:columns,body:.ocean)
    XCTAssertEqual(result.liquidDependencies,Set([-1,8].flatMap {x in (22..<24).map {BlockPosition(-32+x,$0,53)}}))
    XCTAssertFalse(result.faces.contains {$0.direction<2})
    XCTAssertTrue(result.surfaceTransitions.isEmpty)
    XCTAssertGreaterThan(openEdges(triangles(result)),0) // Explicitly incomplete ownership.
    let all=try build(chunk,body:.ocean)
    XCTAssertEqual(all.liquidDependencies,Set([-1,16].flatMap {x in (22..<24).map {BlockPosition(-32+x,$0,53)}}))
  }
  func testCoveredOrStackedWaterIsPreservedAndAnimatedStaticContactIsFlagged() throws {
    var chunk=ChunkData(coordinate:.init(0,0))
    for x in 1...2 {for y in 20..<24 {chunk[x,y,2] = .water}}
    chunk[2,24,2] = .stone // A covered column must not acquire waves.
    chunk[4,29,4] = .water;chunk[4,34,4] = .water
    let result=try build(chunk,body:.ocean)
    XCTAssertEqual(result.surfaceTransitions.count,8)
    XCTAssertEqual(result.unresolvedSurfaceColumns,[P(4,4)])
    let roof=try XCTUnwrap(result.faces.first {$0.cell == .init(2,23,2) && $0.direction==2})
    XCTAssertEqual(roof.role,.boundary)
    for i in 0..<4 {XCTAssertNil(result.vertices[roof.firstVertex+i].wave)}
    XCTAssertTrue(result.faces.contains {$0.cell == .init(4,29,4) && $0.direction==3})
    XCTAssertTrue(result.faces.contains {$0.cell == .init(4,34,4) && $0.direction==3})
  }
  func testFiniteSnapshotDoesNotInventTopOrBottomCaps() throws {
    var chunk=ChunkData(coordinate:.init(0,0))
    chunk[2,ChunkData.minimumY,2] = .water;chunk[2,ChunkData.height-1,2] = .water
    let result=try build(chunk)
    XCTAssertEqual(result.openSnapshotCells,[.init(2,-64,2),.init(2,127,2)])
    XCTAssertFalse(result.faces.contains {$0.cell.y == -64 && $0.direction==3})
    XCTAssertFalse(result.faces.contains {$0.cell.y == 127 && $0.direction==2})
    XCTAssertGreaterThan(openEdges(triangles(result)),0)
  }
  func testUnknownWaveInvalidInputAndMixedFluidsRejectTheWholeTransaction() {
    var chunk=ChunkData(coordinate:.init(0,0));chunk[2,23,2] = .water
    if case .missingSample=B.build(chunk,columns:.full,body:{_ in .ocean},sample:{_ in nil}) {} else {XCTFail("Missing waves")}
    for value in [B.Sample(depth:.nan,body:.ocean,wet:true),.init(depth:2,body:.lava,wet:true),
      .init(depth:2,body:.init(id:2,kind:.river,level:.infinity),wet:true)] {
      if case .invalidSample=B.build(chunk,columns:.full,body:{_ in .ocean},sample:{_ in value}) {} else {XCTFail("Invalid waves")}
    }
    if case .invalidInput=B.build(chunk,columns:.full,body:{_ in .init(id:1,kind:.lake,level:129)},sample:{_ in nil}) {} else {XCTFail("Invalid body")}
    chunk[3,23,2] = .lava
    if case .mixedLiquidContact=B.build(chunk,columns:.full,body:{_ in nil},sample:{_ in nil}) {} else {XCTFail("Mixed liquids")}
    let invalid=ChunkData(coordinate:.init(Int.max,Int.min))
    if case .invalidInput=B.build(invalid,columns:.full,body:{_ in nil},sample:{_ in nil}) {} else {XCTFail("Coordinate overflow")}
  }
  func testBudgetsFailTransactionallyWithoutDiscardingDependencies() throws {
    var chunk=ChunkData(coordinate:.init(0,0));chunk[2,23,2] = .water;chunk[3,23,2] = .water
    for limits in [B.Limits(faces:0),.init(samples:0),.init(dependencies:0)] {
      let outcome=B.build(chunk,columns:mask(2..<3,2..<3),limits:limits,
        body:{_ in .ocean},sample:{_ in .init(depth:1,body:.ocean,wet:true)})
      if case .limitExceeded=outcome {} else {XCTFail("Budget must reject: \(outcome)")}
    }
    let empty=try ready(B.build(chunk,columns:.init(),limits:.init(faces:0,samples:0,dependencies:0),
      body:{_ in XCTFail("No body query for empty selection");return nil},sample:{_ in nil}))
    XCTAssertTrue(empty.faces.isEmpty);XCTAssertTrue(empty.waves.isEmpty)
  }
  func testCancellationBeforeAndDuringSamplingNeverReturnsPartialGeometry() async {
    for during in [false,true] {
      let outcome=await Task.detached {
        if !during {withUnsafeCurrentTask {$0?.cancel()}}
        var chunk=ChunkData(coordinate:.init(0,0));chunk[1,23,1] = .water
        return B.build(chunk,columns:.full,body:{_ in .ocean},sample:{_ in
          withUnsafeCurrentTask {$0?.cancel()};return .init(depth:1,body:.ocean,wet:true)
        })
      }.value
      if case .cancelled=outcome {} else {XCTFail("Cancellation: \(outcome)")}
    }
  }
}
