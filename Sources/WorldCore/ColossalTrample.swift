import Foundation

public struct CrushedBlock: Sendable, Equatable {
  public let position: BlockPosition
  public let material: Block
  public init(position:BlockPosition,material:Block) { self.position=position; self.material=material }
}

/// Incremental swept footprints. Only movement queues damage; standing still
/// cannot drill to bedrock. Overlapping strides scan only the newly entered area.
/// Cursors are value state, so rejected simulation proposals can roll them back.
public struct ColossalTrample: Sendable {
  private struct Sweep: Sendable {
    let from,to:SIMD3<Float>
    let radius:Float
    let low,high:BlockPosition
    let previous:SIMD3<Float>?
    var cursor:BlockPosition
    init(from:SIMD3<Float>,to:SIMD3<Float>,radius:Float,previous:SIMD3<Float>?) {
      self.from=from; self.to=to; self.radius=radius; self.previous=previous
      low = .init(Int(floor(min(from.x,to.x)-radius)),max(ChunkData.minimumY+1,Int(floor(min(from.y,to.y)))-1),Int(floor(min(from.z,to.z)-radius)))
      high = .init(Int(ceil(max(from.x,to.x)+radius)),ChunkData.height-1,Int(ceil(max(from.z,to.z)+radius)))
      cursor=low
    }
    func contains(_ point:SIMD3<Float>) -> Bool {
      let dx=to.x-from.x,dz=to.z-from.z
      let length=dx*dx+dz*dz
      let t=length>0.001 ? min(1,max(0,((point.x-from.x)*dx+(point.z-from.z)*dz)/length)):0
      let x=point.x-from.x-dx*t,z=point.z-from.z-dz*t
      guard x*x+z*z<=radius*radius else { return false }
      if let previous,Int(floor(previous.y)) == Int(floor(to.y)) {
        let px=point.x-previous.x,pz=point.z-previous.z
        if px*px+pz*pz<=radius*radius { return false }
      }
      return true
    }
    mutating func advance() {
      cursor.y += 1
      if cursor.y>high.y { cursor.y=low.y; cursor.x += 1 }
      if cursor.x>high.x { cursor.x=low.x; cursor.z += 1 }
    }
    mutating func skipColumn() { cursor.y=high.y; advance() }
    var finished:Bool { cursor.z>high.z || low.y>high.y }
  }
  private var pending:[Sweep] = []
  private var deferred:[ChunkCoordinate:[SIMD2<Int>:Int]] = [:]
  private var last:SIMD3<Float>?
  private var started=false
  public var hasPending:Bool { !pending.isEmpty || !deferred.isEmpty }
  public init() {}
  public mutating func walked(from:SIMD3<Float>,to:SIMD3<Float>,radius:Float) {
    guard radius.isFinite,radius>0,radius<100,
      (0..<3).allSatisfy({ from[$0].isFinite && to[$0].isFinite && abs(from[$0])<100_000_000 && abs(to[$0])<100_000_000 }) else { return }
    if last == nil { last=from }
    let anchor=last ?? from,dx=to.x-anchor.x,dz=to.z-anchor.z
    guard dx*dx+dz*dz>=1 else { return }
    guard dx*dx+dz*dz<=256*256 else { last=to; started=false; return } // Teleports are not strides.
    // Compact a backlog into exact column cursors, preserving turns rather than
    // cutting a destructive straight line across the inside of a curved path.
    if pending.count>=24 {
      var oldest=pending.removeFirst()
      while !oldest.finished {
        let p=oldest.cursor
        if oldest.contains(p.center) { deferColumn(p) }
        oldest.skipColumn()
      }
    }
    pending.append(.init(from:anchor,to:to,radius:radius,previous:started ? anchor:nil))
    last=to; started=true
  }
  private mutating func deferColumn(_ p:BlockPosition) {
    let column=SIMD2(p.x,p.z)
    deferred[p.chunk,default:[:]][column]=min(deferred[p.chunk]?[column] ?? p.y,p.y)
  }
  public mutating func next(probeLimit:Int=8_192,changeLimit:Int=512,
    loaded:Set<ChunkCoordinate>,block:(BlockPosition)->Block) -> [CrushedBlock] {
    guard probeLimit>0,changeLimit>0 else { return [] }
    var result:[CrushedBlock]=[],probes=0
    // Keep crossed but not-yet-streamed columns until their voxel data arrives.
    // Movement never waits for a mesh, and deferred damage does not vanish when
    // the giant outruns terrain streaming. Duplicate columns share one cursor.
    for chunk in deferred.keys.filter({loaded.contains($0)}).sorted(by: { $0.x == $1.x ? $0.z<$1.z:$0.x<$1.x }) {
      guard probes<probeLimit,result.count<changeLimit else { break }
      var columns=deferred.removeValue(forKey:chunk) ?? [:]
      for column in columns.keys.sorted(by: { $0.x == $1.x ? $0.y<$1.y:$0.x<$1.x }) {
        guard probes<probeLimit,result.count<changeLimit else { break }
        var y=columns[column]!
        while y<ChunkData.height && probes<probeLimit && result.count<changeLimit {
          let point=BlockPosition(column.x,y,column.y),material=block(point)
          probes += 1
          if material.isSolid { result.append(.init(position:point,material:material)) }
          y += 1
        }
        columns[column] = y<ChunkData.height ? y:nil
      }
      if !columns.isEmpty { deferred[chunk]=columns }
    }
    while !pending.isEmpty && probes<probeLimit && result.count<changeLimit {
      var sweep=pending.removeFirst()
      while !sweep.finished && probes<probeLimit && result.count<changeLimit {
        let p=sweep.cursor
        probes += 1
        if !sweep.contains(p.center) { sweep.skipColumn(); continue }
        if !loaded.contains(p.chunk) {
          deferColumn(p)
          sweep.skipColumn(); continue
        }
        let material=block(p)
        if material.isSolid { result.append(.init(position:p,material:material)) }
        sweep.advance()
      }
      if !sweep.finished { pending.insert(sweep,at:0) }
    }
    return result
  }
}
