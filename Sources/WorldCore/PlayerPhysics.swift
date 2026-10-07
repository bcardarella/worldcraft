import Foundation

public struct RayHit: Equatable, Sendable {
  public let block: BlockPosition
  public let adjacent: BlockPosition
  public let distance: Float
}

public enum VoxelRaycast {
  public static func cast(
    origin: SIMD3<Float>, direction: SIMD3<Float>, reach: Float = 6,
    block: (BlockPosition) -> Block
  ) -> RayHit? {
    let magnitude =
      (direction.x * direction.x + direction.y * direction.y + direction.z * direction.z)
      .squareRoot()
    guard magnitude > 0.00001 else { return nil }
    let ray = direction / magnitude
    var cell = BlockPosition(origin)
    var previous = cell
    let steps = SIMD3<Int>(ray.x >= 0 ? 1 : -1, ray.y >= 0 ? 1 : -1, ray.z >= 0 ? 1 : -1)
    var tMax = SIMD3<Float>(repeating: .infinity)
    var tDelta = SIMD3<Float>(repeating: .infinity)
    for axis in 0..<3 where abs(ray[axis]) > 0.00001 {
      let base = Float([cell.x, cell.y, cell.z][axis])
      tMax[axis] = (base + (steps[axis] > 0 ? 1 : 0) - origin[axis]) / ray[axis]
      tDelta[axis] = abs(1 / ray[axis])
    }
    var distance: Float = 0
    while distance <= reach {
      let material=block(cell)
      if material.isSolid {
        if !material.isStair { return .init(block:cell,adjacent:previous,distance:distance) }
        let cellOrigin=SIMD3<Float>(Float(cell.x),Float(cell.y),Float(cell.z))
        var hit: Float?
        for box in material.collisionBoxes {
          let low=cellOrigin+box.center-box.size/2, high=cellOrigin+box.center+box.size/2
          var entry=distance, exit=min(reach,min(tMax.x,tMax.y,tMax.z))
          for axis in 0..<3 {
            if abs(ray[axis])<0.00001 {
              if origin[axis]<low[axis] || origin[axis]>high[axis] { exit = -.infinity }
            } else {
              let a=(low[axis]-origin[axis])/ray[axis], b=(high[axis]-origin[axis])/ray[axis]
              entry=max(entry,min(a,b)); exit=min(exit,max(a,b))
            }
          }
          if entry<=exit { hit=min(hit ?? entry,entry) }
        }
        if let hit { return .init(block:cell,adjacent:previous,distance:hit) }
      }
      let axis = tMax.x < tMax.y ? (tMax.x < tMax.z ? 0 : 2) : (tMax.y < tMax.z ? 1 : 2)
      distance = tMax[axis]
      tMax[axis] += tDelta[axis]
      previous = cell
      switch axis {
      case 0: cell.x += steps.x
      case 1: cell.y += steps.y
      default: cell.z += steps.z
      }
    }
    return nil
  }
}

public struct PlayerPhysics: Sendable {
  public static let height: Float = WorldScale.blocks(1.75)
  public static let eyeHeight: Float = WorldScale.blocks(1.62)
  public static let radius: Float = WorldScale.blocks(0.28)
  public var position: SIMD3<Float>
  public var verticalVelocity: Float = 0
  public private(set) var velocity = SIMD3<Float>.zero
  public var grounded = false
  public var flying = false
  public init(position: SIMD3<Float>) { self.position = position }

  public func overlaps(_ p: BlockPosition) -> Bool {
    position.x + Self.radius > Float(p.x) && position.x - Self.radius < Float(p.x + 1)
      && position.z + Self.radius > Float(p.z) && position.z - Self.radius < Float(p.z + 1)
      && position.y + Self.height > Float(p.y) && position.y < Float(p.y + 1)
  }

  public func collides(at feet: SIMD3<Float>, block: (BlockPosition) -> Block) -> Bool {
    let minimum = BlockPosition(feet + [-Self.radius, 0.001, -Self.radius])
    let maximum = BlockPosition(feet + [Self.radius, Self.height - 0.001, Self.radius])
    for x in minimum.x...maximum.x {
      for y in minimum.y...maximum.y {
        for z in minimum.z...maximum.z {
          let material = block(.init(x,y,z))
          guard material.isSolid else { continue }
          if !material.isStair { return true }
          let local = feet-SIMD3<Float>(Float(x),Float(y),Float(z))
          if material.collisionBoxes.contains(where: { $0.overlaps(feet:local) }) { return true }
        }
      }
    }
    return false
  }

  public mutating func update(
    deltaTime: Float, movement: SIMD3<Float>, jump: Bool, sprint: Bool, waterLevel: Float? = nil,
    waterCurrent: SIMD3<Float> = .zero,
    block: (BlockPosition) -> Block, occupied: (SIMD3<Float>) -> Bool = { _ in false }
  ) {
    let duration = min(max(deltaTime, 0), 0.05)
    let start = position
    defer { velocity = duration > 0 ? (position - start) / duration : .zero }
    let count = max(1, Int(ceil(duration / (1 / 90))))
    let dt = duration / Float(count)
    if flying {
      verticalVelocity = 0
      grounded = false
      let requested = CreativeFlight.velocity(movement: movement, sprint: sprint)
      for _ in 0..<count {
        for axis in [0, 2, 1] {
          var candidate = position
          candidate[axis] += requested[axis] * dt
          if !collides(at: candidate, block: block) && !occupied(candidate) {
            position = candidate
          } else if axis == 1 && requested.y < 0 {
            flying = false
            grounded = true
          }
        }
      }
      return
    }
    if jump && grounded && !flying {
      verticalVelocity = WorldScale.blocks(7)
      grounded = false
    }
    let immersed = waterLevel.map { position.y + WorldScale.blocks(0.9) < $0 } ?? false
    let speed: Float = WorldScale.blocks(sprint ? 6 : 3.3) * (immersed ? 0.55 : 1)
    if jump && immersed { verticalVelocity = WorldScale.blocks(3.5) }
    for _ in 0..<count {
      for axis in [0, 2] {
        var candidate = position
        candidate[axis] += (movement[axis] * speed + (immersed ? waterCurrent[axis] : 0)) * dt
        if !collides(at: candidate, block: block) && !occupied(candidate) { position = candidate }
        else if grounded && !immersed && abs(movement[axis]) > 0.001 {
          // Walk up a half-step, or a single block at a road/door threshold.
          // Both the full body and the landing support must be clear.
          for rise: Float in [0.5,1] {
            let raised = SIMD3<Float>(candidate.x,floor(position.y*2+0.02)/2+rise+0.002,candidate.z)
            if !collides(at:raised,block:block) && !occupied(raised)
              && collides(at:raised-[0,0.03,0],block:block) {
              position=raised; verticalVelocity=0; break
            }
          }
        }
      }
      if immersed, let waterLevel {
        let buoyancy = min(WorldScale.blocks(3), max(WorldScale.blocks(-4), (waterLevel - position.y - Self.height * 0.65) * 7))
        verticalVelocity += (buoyancy - verticalVelocity * 2.8 + movement.y * WorldScale.blocks(10)) * dt
      } else {
        verticalVelocity = max(verticalVelocity - WorldScale.blocks(22) * dt, WorldScale.blocks(-30))
      }
      var candidate = position
      candidate.y += verticalVelocity * dt
      if collides(at: candidate, block: block) || occupied(candidate) {
        if verticalVelocity < 0 { grounded = true }
        verticalVelocity = 0
      } else {
        position = candidate
        grounded = false
      }
    }
  }
}
