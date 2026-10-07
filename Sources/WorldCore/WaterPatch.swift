import Foundation

/// One continuous surface per chunk, sharing identical world-space boundary samples.
public struct WaterPatch: Sendable {
  public var coordinate: ChunkCoordinate
  public var depths: [Float]
  public var bodies: [WaterBody]
  public var shallowIndices: [UInt32]
  public var deepIndices: [UInt32]
  public var sampleStride: Int = 1
  public var vertexSide: Int { 16 / sampleStride + 1 }
  public var isEmpty: Bool { shallowIndices.isEmpty && deepIndices.isEmpty }
  public static let side = 17

  public static func build(
    _ chunk: ChunkData, terrain: TerrainGenerator? = nil, sampleStride step: Int = 1
  ) -> Self {
    precondition(step > 0 && step <= 16 && 16 % step == 0)
    let side = 16 / step + 1
    var floors = [Int?](repeating: nil, count: side * side)
    var bodies = [WaterBody](repeating: .ocean, count: side * side)
    var sampler = WaterBodySampling()
    var present = [Bool](repeating:false,count:side*side)
    let uniform = terrain.map { WaterBodySampling.uniformBody(style:$0.style) } ?? .ocean
    let lookup: (Int,Int) -> WaterBody? = { x,z in
      if let terrain { return terrain.waterBody(atX:x,z:z) }
      return .ocean
    }
    // Dense grid metadata uses direct indexed storage. Hash-table probes are
    // reserved for the sparse dry rim; hot all-water tiles avoid that overhead.
    for z in 0..<side { for x in 0..<side {
      if let body=lookup(chunk.coordinate.x*16+x*step,chunk.coordinate.z*16+z*step) {
        present[z*side+x]=true;bodies[z*side+x]=body
      }
    } }
    func floor(_ i: Int, body: WaterBody) -> Int {
      if let known = floors[i] { return known }
      let x = i % side * step, z = i / side * step
      var result = ChunkData.minimumY
      for y in stride(from:min(ChunkData.height-1,Int(body.level)+1),through:ChunkData.minimumY,by:-1) {
        if chunk[x,y,z].isSolid { result = y+1; break }
      }
      floors[i] = result
      return result
    }
    var depths = [Float](repeating: 0, count: side*side)
    var used = [Bool](repeating: false, count: side*side)
    var shallow: [UInt32] = []
    var deep: [UInt32] = []
    // Wet NW columns determine exactly the same quads as before. Do not scan
    // dry columns or resolve their wave inputs unless a wet quad uses them.
    for z in 0..<(side - 1) {
      if Task.isCancelled { break }
      for x in 0..<(side - 1) {
        let i = z*side+x
        guard present[i] else { continue }
        let body=bodies[i]
        let bottom = floor(i,body:body)
        guard bottom <= Int(body.level)+1 else { continue }
        depths[i] = max(0,body.level-Float(bottom))
        let a = UInt32(z * side + x)
        let b = a + 1
        let c = a + UInt32(side)
        let d = c + 1
        let indices = [a, c, b, b, c, d]
        if depths[Int(a)] < 5 { shallow += indices } else { deep += indices }
        for index in [a,b,c,d] { used[Int(index)] = true }
      }
    }
    for i in used.indices where used[i] {
      let x = chunk.coordinate.x*16+i%side*step, z = chunk.coordinate.z*16+i/side*step
      guard let body = present[i] ? bodies[i] : (uniform ?? sampler.nearest(atX:x,z:z,lookup:lookup)) else {
        // Every referenced vertex has a known wet column inside the fixed
        // radius. Cancellation is discarded by the preparation transaction.
        return .init(coordinate:chunk.coordinate,depths:depths,bodies:bodies,
          shallowIndices:[],deepIndices:[],sampleStride:step)
      }
      bodies[i] = body
      depths[i] = max(0,body.level-Float(floor(i,body:body)))
    }
    return .init(
      coordinate: chunk.coordinate, depths: depths, bodies: bodies, shallowIndices: shallow,
      deepIndices: deep, sampleStride: step)
  }
}
