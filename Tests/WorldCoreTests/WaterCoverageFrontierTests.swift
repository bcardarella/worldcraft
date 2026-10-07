import XCTest
@testable import WorldCore

final class WaterCoverageFrontierTests: XCTestCase {
  private typealias F = WaterCoverageFrontier
  private typealias R = WaterSurfaceRefinement
  private func cell(_ p:F.Point, size:Int = 4, wet:Bool) -> F.Cell {
    let key=F.CellKey(x:floorDivide(p.x,by:size)*size,z:floorDivide(p.z,by:size)*size,size:size)
    let sample=R.Sample(depth:3,body:.ocean,wet:true)
    return .init(key:key,corners:wet ? Array(repeating:sample,count:4):nil,shallow:true)
  }
  private enum Failure:Error {case notReady}
  private func ready(_ result:F.Outcome,file:StaticString = #filePath,line:UInt = #line) throws -> F.Result {
    guard case let .ready(value)=result else {XCTFail("\(result)",file:file,line:line);throw Failure.notReady}
    return value
  }
  /// Independent unit-edge oracle. At every selected/retained interface, a
  /// one-sided edge must match actual occupancy on both sides. Fully retained
  /// regions remain the original approximation and are outside this contract.
  private func verify(_ result:F.Result,source:(F.Point)->F.Cell,wet:(F.Point)->Bool,
    file:StaticString = #filePath,line:UInt = #line) {
    for key in result.refining {
      for z in key.z..<(key.z+key.size) {for x in key.x..<(key.x+key.size) {
        let p=F.Point(x,z)
        for (dx,dz) in [(-1,0),(1,0),(0,-1),(0,1)] {
          let q=F.Point(x+dx,z+dz),outside=source(q)
          if result.refining.contains(outside.key) {continue}
          let retained=outside.corners != nil
          if wet(p) != retained {XCTAssertEqual(retained,wet(q),"False shoreline at \(p) → \(q)",file:file,line:line)}
        }
      }}
    }
  }
  func testMissingConnectedWaterExpandsToItsNaturalBoundary() throws {
    let wet:(F.Point)->Bool={ (0..<8).contains($0.x) && (0..<8).contains($0.z) }
    let source:(F.Point)->F.Cell={self.cell($0,wet:false)}
    let result=try ready(F.select(refining:[.init(1,1)],source:source,occupancy:wet))
    let expected:Set<F.CellKey>=[.init(x:0,z:0,size:4),.init(x:4,z:0,size:4),
      .init(x:0,z:4,size:4),.init(x:4,z:4,size:4)]
    XCTAssertEqual(result.refining,expected);XCTAssertEqual(result.expansionTriggers,3)
    verify(result,source:source,wet:wet)
    let geometry=R.build(refining:result.refining.map {.init($0.x,$0.z)},source:source,occupancy:wet,
      sample:{_ in .init(depth:3,body:.ocean,wet:false)})
    guard case let .ready(mesh)=geometry else {return XCTFail("\(geometry)")}
    XCTAssertEqual(mesh.geometry.values.reduce(0){$0+$1.shallowIndices.count/6},64)
  }
  func testFalsePositiveWaterExpandsAcrossAnActualDryPocket() throws {
    let wet:(F.Point)->Bool={ !(0..<8).contains($0.x) || !(0..<8).contains($0.z) }
    let source:(F.Point)->F.Cell={self.cell($0,wet:true)}
    let result=try ready(F.select(refining:[.init(1,1)],source:source,occupancy:wet))
    XCTAssertEqual(result.refining.count,4);XCTAssertEqual(result.expansionTriggers,3)
    verify(result,source:source,wet:wet)
    let geometry=R.build(refining:result.refining.map {.init($0.x,$0.z)},source:source,occupancy:wet,
      sample:{_ in XCTFail("The whole replacement is dry");return nil})
    guard case let .ready(mesh)=geometry else {return XCTFail("\(geometry)")}
    XCTAssertEqual(mesh.geometry.count,4);XCTAssertTrue(mesh.geometry.values.allSatisfy(\.isEmpty))
  }
  func testMatchingRetainedWaterDoesNotSurveyOrRefineTheOcean() throws {
    let key=F.CellKey(x:0,z:0,size:4)
    var queries=Set<F.Point>()
    let result=try ready(F.select(refining:[.init(1,1)],source:{self.cell($0,wet:true)},occupancy:{p in
      XCTAssertTrue(key.contains(p));queries.insert(p);return true
    }))
    XCTAssertEqual(result.refining,[key]);XCTAssertEqual(result.sampledColumns,16)
    XCTAssertEqual(result.expansionTriggers,0);XCTAssertEqual(queries.count,16)
  }
  func testUnequalNegativeGridsAndInputOrderingAreDeterministic() throws {
    let wet:(F.Point)->Bool={(-6..<10).contains($0.x) && (-3..<6).contains($0.z)}
    let source:(F.Point)->F.Cell={self.cell($0,size:$0.x<0 ? 4:8,wet:false)}
    let columns:[F.Point]=[.init(-1,1),.init(1,1),.init(-1,1)]
    let a=try ready(F.select(refining:columns,source:source,occupancy:wet))
    let b=try ready(F.select(refining:columns.reversed(),source:source,occupancy:wet))
    XCTAssertEqual(a.refining,b.refining);XCTAssertEqual(a.sampledColumns,b.sampledColumns)
    XCTAssertEqual(a.boundaryChecks,b.boundaryChecks)
    XCTAssertTrue(a.refining.contains {$0.x<0});XCTAssertTrue(a.refining.contains {$0.size==8})
    verify(a,source:source,wet:wet)
  }
  func testUnknownAndInvalidInputNeverProduceACompletedSelection() {
    let missing=F.select(refining:[.init(1,1)],source:{_ in nil},occupancy:{_ in false})
    if case .missingSource=missing {} else {XCTFail("\(missing)")}
    let unknown=F.select(refining:[.init(1,1)],source:{self.cell($0,wet:false)},occupancy:{p in
      (0..<4).contains(p.x) && (0..<4).contains(p.z) ? true:nil
    })
    if case .missingOccupancy=unknown {} else {XCTFail("\(unknown)")}
    let invalid=F.select(refining:[.init(1,1)],source:{_ in
      .init(key:.init(x:0,z:0,size:3),corners:nil,shallow:false)
    },occupancy:{_ in false})
    if case .invalidSource=invalid {} else {XCTFail("\(invalid)")}
    let overlap=F.select(refining:[.init(1,1),.init(5,1)],source:{p in
      .init(key:.init(x:0,z:0,size:p.x<4 ? 4:8),corners:nil,shallow:false)
    },occupancy:{_ in false})
    if case .invalidSource=overlap {} else {XCTFail("\(overlap)")}
    var count=0
    let changing=F.select(refining:[.init(1,1)],source:{p in
      count+=1;return self.cell(p,wet:count%2==0)
    },occupancy:{_ in false})
    if case .invalidSource=changing {} else {XCTFail("\(changing)")}
  }
  func testFiniteBudgetsStopUnboundedExpansionAndExactBudgetsSucceed() throws {
    for limits in [F.Limits(cells:8),.init(columns:24)] {
      let result=F.select(refining:[.init(1,1)],limits:limits,source:{self.cell($0,wet:false)},occupancy:{_ in true})
      if case .limitExceeded=result {} else {XCTFail("\(result)")}
    }
    let wet:(F.Point)->Bool={(0..<8).contains($0.x) && (0..<8).contains($0.z)}
    let a=try ready(F.select(refining:[.init(1,1)],source:{self.cell($0,wet:false)},occupancy:wet))
    let b=try ready(F.select(refining:[.init(1,1)],limits:.init(cells:a.sourceCells,columns:a.sampledColumns),
      source:{self.cell($0,wet:false)},occupancy:wet))
    XCTAssertEqual(a.refining,b.refining)
    let empty=try ready(F.select(refining:[],limits:.init(cells:0,columns:0),
      source:{_ in XCTFail();return nil},occupancy:{_ in XCTFail();return nil}))
    XCTAssertTrue(empty.refining.isEmpty)
  }
  func testCancellationDuringEitherCallbackRejectsSelection() async {
    for inSource in [false,true] {
      let cancelled=await Task.detached {
        let result=F.select(refining:[.init(1,1)],source:{_ in
          if inSource {withUnsafeCurrentTask {$0?.cancel()}}
          return .init(key:.init(x:0,z:0,size:4),corners:nil,shallow:false)
        },occupancy:{_ in withUnsafeCurrentTask {$0?.cancel()};return false})
        if case .cancelled=result {return true};return false
      }.value
      XCTAssertTrue(cancelled)
    }
  }
  func testRequiredTransitionVerticesHaveKnownBodyOriginsAcrossSupportedWaterGrids() throws {
    // The demanded vertices are either corners of original wet source quads
    // or new wet unit quads. Even a sparse body lookup at just those NW owners
    // must resolve every vertex with the production 19-origin rule. It must
    // never need an arbitrary dry vertex or an invented ocean fallback.
    for size in [1,2,4,8,16,32] {
      let origin=R.Point(-2*size,-size)
      func wetUnit(_ p:R.Point)->Bool {
        (origin.x..<(origin.x+size)).contains(p.x)
          && (origin.z..<(origin.z+size)).contains(p.z)
          && (p.x-origin.x+p.z-origin.z)%2==0
      }
      let source:(R.Point)->R.Cell?={self.cell($0,size:size,wet:true)}
      var sampler=WaterBodySampling(),requests=0
      let result=R.build(refining:[origin],source:source,occupancy:wetUnit,sample:{p in
        requests+=1
        guard let body=sampler.nearest(atX:p.x,z:p.z,lookup:{x,z in
          wetUnit(.init(x,z)) || (x%size==0 && z%size==0) ? .ocean:nil
        }) else {XCTFail("Unowned drawn vertex \(p) at grid size \(size)");return nil}
        return .init(depth:3,body:body,wet:false)
      })
      guard case let .ready(geometry)=result else {XCTFail("\(result)");continue}
      XCTAssertGreaterThan(requests,0)
      var drawn=Set<R.Point>()
      for (key,mesh) in geometry.geometry {for sample in mesh.samples {
        drawn.insert(.init(key.x+Int(sample.position.x),key.z+Int(sample.position.y)))
      }}
      XCTAssertEqual(geometry.sampledPoints,drawn.count)
      XCTAssertEqual(requests,drawn.count)
    }
  }
  func testInspectingWaveOnlyNeighboursFindsTheirOtherFootprintErrors() throws {
    for actualWidth in [4,12] {
      let wet:(F.Point)->Bool={ (0..<actualWidth).contains($0.x) && (0..<4).contains($0.z) }
      let source:(F.Point)->F.Cell={p in self.cell(p,wet:(0..<8).contains(p.x) && (0..<4).contains(p.z))}
      let initial=try ready(F.select(refining:[.init(1,1)],source:source,occupancy:wet))
      XCTAssertEqual(initial.refining,[.init(x:0,z:0,size:4)])
      let topology=R.build(refining:[.init(1,1)],source:source,occupancy:wet,
        sample:{_ in .init(depth:3,body:.ocean,wet:true)})
      guard case let .ready(mesh)=topology else {return XCTFail("\(topology)")}
      XCTAssertNotNil(mesh.geometry[.init(x:4,z:0,size:4)],"The wet neighbour must receive edge splits")
      let next=try ready(F.select(refining:[.init(1,1)],inspecting:Set(mesh.geometry.keys),source:source,occupancy:wet))
      let added=F.CellKey(x:actualWidth==4 ? 4:8,z:0,size:4)
      XCTAssertEqual(next.refining,initial.refining.union([added]))
      verify(next,source:source,wet:wet)
      let rebuilt=R.build(refining:next.refining.map {.init($0.x,$0.z)},source:source,occupancy:wet,
        sample:{_ in .init(depth:3,body:.ocean,wet:true)})
      guard case let .ready(final)=rebuilt else {return XCTFail("\(rebuilt)")}
      let stable=try ready(F.select(refining:next.refining.map {.init($0.x,$0.z)},
        inspecting:Set(final.geometry.keys),source:source,occupancy:wet))
      XCTAssertEqual(stable.refining,next.refining)
    }
  }
  func testInspectedBoundariesAlsoRespectUnknownInputAndBudgets() {
    let inspected:Set<F.CellKey>=[.init(x:0,z:0,size:4)]
    let source:(F.Point)->F.Cell?={p in self.cell(p,wet:(0..<4).contains(p.x) && (0..<4).contains(p.z))}
    let unknown=F.select(refining:[],inspecting:inspected,source:source,occupancy:{_ in nil})
    if case .missingOccupancy=unknown {} else {XCTFail("\(unknown)")}
    let limited=F.select(refining:[],inspecting:inspected,limits:.init(columns:0),source:source,occupancy:{_ in false})
    if case .limitExceeded=limited {} else {XCTFail("\(limited)")}
    let invalid=F.select(refining:[],inspecting:[.init(x:1,z:0,size:4)],source:source,occupancy:{_ in false})
    if case .invalidSource=invalid {} else {XCTFail("\(invalid)")}
  }
}
