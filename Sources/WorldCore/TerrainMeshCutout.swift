/// Removes a vertical, rectangular ownership prism from retained terrain.
/// Original triangles, interpolated attributes and the packer's quad contract
/// survive clipping. Caller admission bounds the source and output geometry.
enum TerrainMeshCutout {
  struct Rectangle {
    let minimum, maximum: SIMD2<Float>
    func contains(_ p: SIMD3<Float>) -> Bool {
      p.x >= minimum.x && p.x <= maximum.x && p.z >= minimum.y && p.z <= maximum.y
    }
  }
  private struct Vertex {
    let position, normal: SIMD3<Float>
    let uv: SIMD2<Float>
    let wind: Float
    func interpolated(to other: Self, at t: Float) -> Self {
      .init(position: position+(other.position-position)*t, normal: normal+(other.normal-normal)*t,
        uv: uv+(other.uv-uv)*t, wind: wind+(other.wind-wind)*t)
    }
  }
  private static func clip(_ input: [Vertex], axis: Int, boundary: Float, sign: Float, inside: Bool) -> [Vertex] {
    guard var previous = input.last else { return [] }
    func distance(_ vertex: Vertex) -> Float { (vertex.position[axis]-boundary)*sign }
    func keep(_ distance: Float) -> Bool { inside ? distance >= 0 : distance < 0 }
    var old = distance(previous), output: [Vertex] = []
    for vertex in input {
      let current = distance(vertex)
      if keep(old) != keep(current) { output.append(previous.interpolated(to: vertex,at: old/(old-current))) }
      if keep(current) { output.append(vertex) }
      previous = vertex; old = current
    }
    return output
  }
  static func remove(_ region: Rectangle, from source: VoxelMesh) -> VoxelMesh? {
    let count = source.positions.count
    guard source.stadiumSeats.isEmpty, count % 4 == 0,
      source.normals.count == count, source.textureCoordinates.count == count,
      source.indices.count == count/4*6, source.materials.count == count/2,
      source.windWeights.isEmpty || source.windWeights.count == count,
      source.repeatingAtlasTiles.isEmpty || source.repeatingAtlasTiles.count == count/4 else { return nil }
    let repeated = !source.repeatingAtlasTiles.isEmpty, windy = !source.windWeights.isEmpty
    var result = VoxelMesh()
    func append(_ vertices: [Vertex], material: UInt32, tile: UInt16) {
      let start = UInt32(result.positions.count)
      result.positions += vertices.map(\.position); result.normals += vertices.map(\.normal)
      result.textureCoordinates += vertices.map(\.uv)
      result.indices += [start,start+1,start+2,start,start+2,start+3]
      result.materials += [material,material]
      if repeated { result.repeatingAtlasTiles.append(tile) }
      if windy { result.windWeights += vertices.map(\.wind) }
    }
    for start in stride(from: 0,to: source.positions.count,by: 4) {
      if Task.isCancelled { return nil }
      let quad = (start..<(start+4)).map { Vertex(position: source.positions[$0],normal: source.normals[$0],
        uv: source.textureCoordinates[$0],wind: windy ? source.windWeights[$0] : 0) }
      let material = source.materials[start/2], tile = repeated ? source.repeatingAtlasTiles[start/4] : 0
      if quad.allSatisfy({ region.contains($0.position) }) { continue }
      var low = quad[0].position, high = low
      for vertex in quad { low = componentMin(low,vertex.position); high = componentMax(high,vertex.position) }
      if high.x < region.minimum.x || low.x > region.maximum.x || high.z < region.minimum.y || low.z > region.maximum.y {
        append(quad,material: material,tile: tile); continue
      }
      // Cut each original triangle independently. Re-triangulating a nonplanar
      // sampled quad first would change the displayed ground and its lease.
      for triangle in [[quad[0],quad[1],quad[2]],[quad[0],quad[2],quad[3]]] {
        var remainder = triangle
        for (axis,boundary,sign): (Int,Float,Float) in [
          (0,region.minimum.x,1),(0,region.maximum.x,-1),(2,region.minimum.y,1),(2,region.maximum.y,-1)] {
          let polygon = clip(remainder,axis: axis,boundary: boundary,sign: sign,inside: false)
          if polygon.count >= 3 {
            for i in 1..<(polygon.count-1) {
              let a = polygon[0], b = polygon[i], c = polygon[i+1]
              let u = b.position-a.position, v = c.position-a.position
              let cross = SIMD3(u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x)
              if cross.x*cross.x+cross.y*cross.y+cross.z*cross.z > 1e-12 {
                append([a,b,c,c],material: material,tile: tile)
              }
            }
          }
          remainder = clip(remainder,axis: axis,boundary: boundary,sign: sign,inside: true)
          if remainder.count < 3 { break }
        }
      }
    }
    result.firePositions = source.firePositions.filter { !region.contains($0) }
    result.lampPositions = source.lampPositions.filter { !region.contains($0) }
    return result
  }
}
