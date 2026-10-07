/// Exterior faces of actual voxel liquid volumes in one immutable chunk. The
/// animated top uses the same canonical wave samples as WaterSurfaceRefinement.
/// This is an opt-in preparation primitive, not a renderer/publication policy.
public enum WaterVolumeBoundary {
  public typealias Point = WaterSurfaceRefinement.Point
  public typealias Sample = WaterSurfaceRefinement.Sample

  public struct WaveInput: Sendable {
    public let point: Point
    public let sample: Sample
  }
  public struct Vertex: Sendable {
    /// Chunk-local X/Z, world Y. No world-coordinate Float subtraction.
    public let position: SIMD3<Float>
    public let wave: Int?
    /// Top vertices and joined river steps follow the surface exactly. Lower
    /// vertices are capped at it, so a falling wave collapses wall bands.
    public let followsSurface: Bool
  }
  public enum Role: Sendable { case animatedSurface, boundary }
  public struct Face: Sendable {
    public let cell: BlockPosition
    public let direction: Int
    public let material: Block
    public let role: Role
    public let firstVertex: Int
  }
  public struct Limits: Sendable {
    public let faces, samples, dependencies: Int
    public init(faces: Int = 65_536, samples: Int = 1_024, dependencies: Int = 65_536) {
      precondition(faces >= 0 && samples >= 0 && dependencies >= 0)
      self.faces=faces; self.samples=samples; self.dependencies=dependencies
    }
  }
  public struct Result: Sendable {
    public let coordinate: ChunkCoordinate
    public let vertices: [Vertex]
    public let faces: [Face]
    public let waves: [WaveInput]
    /// Liquid neighbours outside the selected columns need compatible volume
    /// ownership. Their absence from this mesh is not a certified closed seam.
    public let liquidDependencies: Set<BlockPosition>
    /// Touching liquid runs where only one has a known animated free surface.
    /// Their deformation needs coordination; never silently call them closed.
    public let surfaceTransitions: Set<BlockPosition>
    /// Exposed nonprocedural tops (placed, removed or stacked fluids) need a
    /// surface policy. They are retained as actual static voxel boundaries.
    public let unresolvedSurfaceColumns: Set<Point>
    /// Snapshot top/bottom is unknown. The air fallback must not create a cap.
    public let openSnapshotCells: Set<BlockPosition>

    /// Host evaluation for geometry validation. Not intended for a frame's
    /// MainActor work; a native backend must implement these same semantics.
    public func positions(environment: WorldEnvironment) -> [SIMD3<Float>] {
      let heights=waves.map {
        environment.water(atX:Float($0.point.x),z:Float($0.point.z),
          depth:$0.sample.depth,body:$0.sample.body).height
      }
      return vertices.map { v in
        guard let wave=v.wave else { return v.position }
        var p=v.position
        p.y=v.followsSurface ? heights[wave]:min(p.y,heights[wave])
        return p
      }
    }
    /// Match the animated surface's SW–NE diagonal on bottom faces too. When
    /// a wave drops below the floor, corresponding top/bottom triangles can
    /// collapse onto each other without crossing different triangulations.
    public func indices(for face: Face) -> [Int] {
      let pattern = face.direction == 3 ? [0,1,3,1,2,3]:[0,1,2,0,2,3]
      return pattern.map {face.firstVertex+$0}
    }
  }
  public enum Outcome: Sendable {
    case ready(Result)
    case invalidInput
    case missingSample(Point)
    case invalidSample(Point)
    case mixedLiquidContact(BlockPosition)
    case limitExceeded
    case cancelled
  }

  /// Opaque contacts are retained deliberately: omitting a liquid face requires
  /// proof that the *rendered* terrain buries it, not just a solid voxel read.
  /// Nil `body` means known absence of a procedural body. Exposed liquid still
  /// survives and is reported as unresolved, rather than borrowing ocean data.
  /// Faces marked animatedSurface are an alternative to the unit top mesh;
  /// callers must select exactly one owner and never render both copies.
  public static func build(_ chunk: ChunkData, columns: VoxelColumnMask,
    limits: Limits = .init(), body: (Point) -> WaterBody?, sample: (Point) -> Sample?) -> Outcome {
    if Task.isCancelled { return .cancelled }
    let coordinate=chunk.coordinate
    guard coordinate.x > Int.min/16+2, coordinate.x < Int.max/16-2,
      coordinate.z > Int.min/16+2, coordinate.z < Int.max/16-2 else { return .invalidInput }
    let originX=coordinate.x*16,originZ=coordinate.z*16
    var profiles:[Point:WaterColumnProfile]=[:],failure:Outcome?
    var vertices:[Vertex]=[],faces:[Face]=[],waves:[WaveInput]=[],mapping:[Point:Int]=[:]
    var dependencies=Set<BlockPosition>(),transitions=Set<BlockPosition>(),unresolved=Set<Point>(),open=Set<BlockPosition>()
    var dependencyCount=0
    func profile(_ x:Int,_ z:Int)->WaterColumnProfile? {
      let key=Point(x,z)
      if let held=profiles[key] {return held}
      let selected=body(.init(originX+x,originZ+z))
      guard !Task.isCancelled else {failure = .cancelled;return nil}
      switch WaterColumnProfile.inspect(chunk,x:x,z:z,body:selected) {
      case let .ready(value): profiles[key]=value;return value
      case .invalidInput:failure = .invalidInput;return nil
      case .cancelled:failure = .cancelled;return nil
      }
    }
    func wave(_ x:Int,_ z:Int,material:Block)->Int? {
      let p=Point(originX+x,originZ+z)
      if let held=mapping[p] {
        guard (waves[held].sample.body.kind == .lava) == (material == .lava) else {
          failure = .invalidSample(p);return nil
        }
        return held
      }
      guard waves.count<limits.samples else {failure = .limitExceeded;return nil}
      let supplied=sample(p)
      guard !Task.isCancelled else {failure = .cancelled;return nil}
      guard let value=supplied else {failure = .missingSample(p);return nil}
      guard value.valid, (value.body.kind == .lava) == (material == .lava) else {
        failure = .invalidSample(p);return nil
      }
      let i=waves.count;waves.append(.init(point:p,sample:value));mapping[p]=i;return i
    }
    func admit(_ p:BlockPosition,into set:inout Set<BlockPosition>)->Bool {
      if set.contains(p) {return true}
      guard dependencyCount<limits.dependencies else {failure = .limitExceeded;return false}
      set.insert(p);dependencyCount += 1;return true
    }
    struct JoinKey:Hashable {let point:Point,lower:Int,upper:Int,material:Block}
    var joins:[JoinKey:Int]=[:]
    // Neighbouring river columns can round their procedural level to different
    // voxel tops. All vertices on their connecting wall bands must collapse to
    // the shared wave, including the lower top's corner on the taller column.
    // Otherwise two copies of that same edge use different deformation rules.
    // Consult all four immutable incident columns, including the halo, so the
    // choice does not depend on which chunk owns a face or is prepared first.
    func joinedSurface(_ x:Int,_ z:Int,span:WaterColumnProfile.Span)->Int? {
      let key=JoinKey(point:.init(x,z),lower:span.lower,upper:span.upper,material:span.material)
      if let held=joins[key] {return held}
      var incident:[WaterColumnProfile.Span]=[]
      for dz in -1...0 {for dx in -1...0 {
        guard let value=profile(x+dx,z+dz) else {return nil}
        if let i=value.proceduralSurface,value.spans[i].material==span.material {incident.append(value.spans[i])}
      }}
      var lower=span.lower,upper=span.upper,join=span.upper
      // At most four incident procedural runs. Transitive overlap matters at
      // corners where more than two river levels meet. Disjoint pools do not
      // borrow each other's deformation threshold.
      for _ in 0..<4 {
        var changed=false
        for other in incident where other.lower<upper && lower<other.upper {
          let lo=min(lower,other.lower),hi=max(upper,other.upper)
          join=min(join,other.upper)
          changed = changed || lo != lower || hi != upper;lower=lo;upper=hi
        }
        if !changed {break}
      }
      joins[key]=join;return join
    }
    for z in 0..<16 {for x in 0..<16 where columns.contains(x:x,z:z) {
      if Task.isCancelled {return .cancelled}
      guard let column=profile(x,z) else {return failure!}
      if !column.additionalSurfaces.isEmpty {unresolved.insert(.init(originX+x,originZ+z))}
      for (spanIndex,span) in column.spans.enumerated() {
        let animated=column.proceduralSurface==spanIndex
        for y in span.lower..<span.upper {
          if Task.isCancelled {return .cancelled}
          let cell=BlockPosition(originX+x,y,originZ+z)
          for direction in 0..<6 {
            let d=VoxelMesher.offsets[direction],nx=x+d.x,ny=y+d.y,nz=z+d.z
            if ny<ChunkData.minimumY || ny>=ChunkData.height {
              guard admit(cell,into:&open) else {return failure!};continue
            }
            let neighbor=chunk[nx,ny,nz]
            if neighbor.isLiquid && neighbor != span.material {return .mixedLiquidContact(cell)}
            if neighbor==span.material {
              if direction<2 || direction>3 {
                let outside=BlockPosition(originX+nx,ny,originZ+nz)
                if !(0..<16).contains(nx) || !(0..<16).contains(nz) || !columns.contains(x:nx,z:nz) {
                  guard admit(outside,into:&dependencies) else {return failure!}
                }
                guard let other=profile(nx,nz) else {return failure!}
                let otherAnimated=other.proceduralSurface.map {other.spans[$0].lower<=ny && ny<other.spans[$0].upper} ?? false
                if animated != otherAnimated {guard admit(cell,into:&transitions) else {return failure!}}
              }
              continue
            }
            guard faces.count<limits.faces else {return .limitExceeded}
            let start=vertices.count
            for offset in VoxelMesher.corners[direction] {
              let p=offset+SIMD3<Float>(Float(x),Float(y),Float(z))
              var index:Int?
              var follows=false
              if animated {
                guard let resolved=wave(Int(p.x),Int(p.z),material:span.material) else {return failure!}
                index=resolved
                guard let join=joinedSurface(Int(p.x),Int(p.z),span:span) else {return failure!}
                follows=Int(p.y)>=join
              }
              vertices.append(.init(position:p,wave:index,followsSurface:follows))
            }
            faces.append(.init(cell:cell,direction:direction,material:span.material,
              role:animated && direction==2 ? .animatedSurface:.boundary,firstVertex:start))
          }
        }
      }
    }}
    if Task.isCancelled {return .cancelled}
    return .ready(.init(coordinate:coordinate,vertices:vertices,faces:faces,waves:waves,
      liquidDependencies:dependencies,surfaceTransitions:transitions,
      unresolvedSurfaceColumns:unresolved,openSnapshotCells:open))
  }
}
