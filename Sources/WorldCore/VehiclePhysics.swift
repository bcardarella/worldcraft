import Foundation

/// A small, grounded arcade car. Units are half-metre world blocks. Substeps,
/// a rotated collision volume and solid support prevent tunneling or driving
/// into unloaded terrain; head pose never enters steering or acceleration.
public struct VehiclePhysics: Sendable {
  public static let halfWidth: Float = 1.1
  public static let halfLength: Float = 2.2
  public static let height: Float = 2.8
  public let kind: VehicleKind
  public var position: SIMD3<Float>
  public var heading: Float
  public private(set) var speed: Float = 0
  public private(set) var steering: Float = 0
  private var planarVelocity = SIMD2<Float>.zero
  private var verticalSpeed: Float = 0
  public private(set) var yawRate: Float = 0
  public private(set) var impactSpeed: Float = 0
  public private(set) var slipSpeed: Float = 0
  public private(set) var grounded = true
  public private(set) var parkingBrake = false
  private var handbrakeWasPressed = false
  public init(position: SIMD3<Float>, heading: Float = 0, kind: VehicleKind = .touring, parkingBrake: Bool = false) {
    self.position = position; self.heading = heading; self.kind = kind; self.parkingBrake = parkingBrake
  }
  public var wheelAngle:Float {
    let v=WorldScale.metres(abs(speed))
    return steering*kind.steeringAngle/(1+0.025*v*v)
  }
  /// Invert the player stick curve for local AI pure-pursuit steering.
  public func steeringInput(wheelAngle:Float) -> Float {
    let v=WorldScale.metres(abs(speed)),lock=kind.steeringAngle/(1+0.025*v*v)
    let goal=min(1,max(0,abs(wheelAngle)/lock))
    var low:Float=0,high:Float=1
    for _ in 0..<10 {let m=(low+high)/2;if m*(0.45+0.55*m*m)<goal {low=m}else{high=m}}
    return (low+high)/2*(wheelAngle<0 ? -1:1)
  }
  public var velocity: SIMD3<Float> { [planarVelocity.x, verticalSpeed, planarVelocity.y] }
  public var eye: SIMD3<Float> { position + rotated([-kind.halfWidth*0.41, kind.seatHeight, 0.25]) }
  public func rotated(_ offset: SIMD3<Float>) -> SIMD3<Float> {
    [cos(heading) * offset.x + sin(heading) * offset.z, offset.y, -sin(heading) * offset.x + cos(heading) * offset.z]
  }
  public func overlapsPlayer(at feet: SIMD3<Float>) -> Bool {
    guard feet.y < position.y + kind.height && feet.y + PlayerPhysics.height > position.y + 0.05 else { return false }
    let delta = feet - position
    let x = cos(heading) * delta.x - sin(heading) * delta.z
    let z = sin(heading) * delta.x + cos(heading) * delta.z
    let dx = max(0, abs(x) - kind.halfWidth), dz = max(0, abs(z) - kind.halfLength)
    return dx * dx + dz * dz < PlayerPhysics.radius * PlayerPhysics.radius
  }
  public mutating func stop() { speed = 0; verticalSpeed = 0; planarVelocity = .zero; yawRate = 0; handbrakeWasPressed = false }

  /// Four separating axes keep differently sized cars from intersecting.
  public static func overlaps(position: SIMD3<Float>, heading: Float, kind: VehicleKind,
    otherPosition: SIMD3<Float>, otherHeading: Float, otherKind: VehicleKind) -> Bool {
    guard position.y < otherPosition.y+otherKind.height && otherPosition.y < position.y+kind.height else { return false }
    let right=SIMD2<Float>(cos(heading),-sin(heading)), forward=SIMD2<Float>(sin(heading),cos(heading))
    let otherRight=SIMD2<Float>(cos(otherHeading),-sin(otherHeading)), otherForward=SIMD2<Float>(sin(otherHeading),cos(otherHeading))
    let delta=SIMD2<Float>(otherPosition.x-position.x,otherPosition.z-position.z)
    func dot(_ a:SIMD2<Float>,_ b:SIMD2<Float>) -> Float { a.x*b.x+a.y*b.y }
    for axis in [right,forward,otherRight,otherForward] {
      let a=abs(dot(axis,right))*kind.halfWidth+abs(dot(axis,forward))*kind.halfLength
      let b=abs(dot(axis,otherRight))*otherKind.halfWidth+abs(dot(axis,otherForward))*otherKind.halfLength
      if abs(dot(delta,axis)) >= a+b+0.06 { return false }
    }
    return true
  }

  public static func isClear(at point: SIMD3<Float>, heading: Float, kind: VehicleKind = .touring, block: (BlockPosition) -> Block) -> Bool {
    let halfWidth = kind.halfWidth, halfLength = kind.halfLength, height = kind.height
    let c = cos(heading), s = sin(heading)
    let ex = abs(c) * halfWidth + abs(s) * halfLength
    let ez = abs(s) * halfWidth + abs(c) * halfLength
    let low = BlockPosition(point + [-ex, 0.08, -ez])
    let high = BlockPosition(point + [ex, height - 0.05, ez])
    let pad = 0.5 * (abs(c) + abs(s))
    for x in low.x...high.x { for z in low.z...high.z {
      let dx = Float(x) + 0.5 - point.x, dz = Float(z) + 0.5 - point.z
      guard abs(c * dx - s * dz) < halfWidth + pad - 0.01,
        abs(s * dx + c * dz) < halfLength + pad - 0.01 else { continue }
      for y in low.y...high.y {
        let material = block(.init(x, y, z))
        if material.isSolid || material.isLiquid { return false }
      }
    } }
    return true
  }

  private func support(at point: SIMD3<Float>, heading: Float, block: (BlockPosition) -> Block) -> Float? {
    let base = Int(floor(position.y+0.05))
    var heights: [Int] = []
    // Axles plus bumper corners: the front overhang contacts a voxel riser
    // before the wheels do, especially when approaching a hill diagonally.
    let side = kind.halfWidth - 0.2, axle = kind.wheelbase / 2, bumper = kind.halfLength - 0.15
    for x: Float in [-side, side] { for z: Float in [-bumper, -axle, axle, bumper] {
      let wx = Int(floor(point.x+cos(heading)*x+sin(heading)*z))
      let wz = Int(floor(point.z-sin(heading)*x+cos(heading)*z))
      for level in [base+1, base, base-1] {
        if block(.init(wx,level-1,wz)).isSolid && !block(.init(wx,level,wz)).isSolid {
          heights.append(level); break
        }
      }
    } }
    guard heights.count >= 2, let high = heights.max() else { return nil }
    return Float(high)
  }

  public mutating func update(deltaTime: Float, throttle: Float, turn: Float, brake: Float,
    block: (BlockPosition) -> Block, occupied: (SIMD3<Float>, Float) -> Bool = { _, _ in false }) {
    impactSpeed = 0
    guard deltaTime.isFinite, throttle.isFinite, turn.isFinite, brake.isFinite else { return }
    let duration = min(0.05,max(0,deltaTime))
    guard duration > 0 else { return }
    let steps = max(1,Int(ceil(duration*120))), dt = duration/Float(steps)
    let gas = min(1,max(-1,throttle)), turn = min(1,max(-1,turn)), brake = min(1,max(0,brake))
    let pressed = brake > 0.5
    if pressed && !handbrakeWasPressed && grounded && planarVelocity.x*planarVelocity.x + planarVelocity.y*planarVelocity.y < 0.49 {
      parkingBrake.toggle()
    }
    handbrakeWasPressed = pressed
    for _ in 0..<steps {
      // Preserve full parking lock, with precise small stick corrections.
      let command=turn*(0.45+0.55*turn*turn)
      let rate:Float = abs(command)<abs(steering) || command*steering<0 ? 5.5:3.6
      steering += max(-rate*dt,min(rate*dt,command-steering))
      let forward = SIMD2<Float>(-sin(heading),-cos(heading))
      let side = SIMD2<Float>(cos(heading),-sin(heading))
      speed = planarVelocity.x*forward.x+planarVelocity.y*forward.y
      var lateral = planarVelocity.x*side.x+planarVelocity.y*side.y
      slipSpeed = abs(lateral)
      let surface = block(.init(position+[0,-0.15,0]))
      let surfaceGrip: Float = surface == .snow ? 0.4 : surface == .sand ? 0.63 : 1
      let grip = kind.grip * surfaceGrip * (1 - brake * 0.94)
      if grounded {
        if parkingBrake { speed = 0; lateral = 0 }
        else {
          speed += gas*(speed*gas < -0.05 ? kind.brakeDeceleration : kind.acceleration)*(1 - brake*0.75)*dt
          let drag: Float = 1.2+abs(speed)*0.08+brake*kind.brakeDeceleration
          speed = max(0,abs(speed)-drag*dt)*(speed < 0 ? -1 : 1)
          // Locked rear wheels retain lateral momentum. Releasing the lever
          // progressively restores grip instead of snapping the car straight.
          lateral *= exp(-grip*dt)
        }
      }
      speed = min(kind.topSpeed,max(-10,speed))
      planarVelocity = forward*speed+side*lateral
      // Speed-sensitive wheel lock and a bounded lateral-acceleration envelope.
      let metresPerSecond=WorldScale.metres(abs(speed))
      let lock=kind.steeringAngle/(1+0.025*metresPerSecond*metresPerSecond)
      let desired = -speed/kind.wheelbase*tan(steering*lock)*(1+brake*0.35)
      let lateralLimit:Float = (kind.sporting ? 22:18)*surfaceGrip
      let maximumYaw=min(1.2,lateralLimit/max(4,abs(speed)))*(1+brake*0.45)
      let targetYaw=grounded ? max(-maximumYaw,min(maximumYaw,desired)):0
      yawRate += (targetYaw-yawRate)*(1-exp(-dt*(brake>0.1 ? 6:9)))
      let yaw=heading+yawRate*dt
      if Self.isClear(at:position,heading:yaw,kind:kind,block:block) && !occupied(position,yaw) { heading=yaw }
      else { yawRate *= exp(-dt*15) }
      func clear(_ p: SIMD3<Float>) -> Bool {
        Self.isClear(at:p,heading:heading,kind:kind,block:block) && !occupied(p,heading)
      }
      var next = position+[planarVelocity.x*dt,0,planarVelocity.y*dt]
      let level = support(at:next,heading:heading,block:block)
      if let level, grounded, level-position.y <= 1.05, level-position.y >= -1.05,
        clear([next.x,level,next.z]) {
        // One-block ascents and descents retain speed, including reverse and
        // diagonal approaches. No launch impulse at each staircase riser.
        next.y = level; verticalSpeed = 0
      } else if !clear(next) && grounded {
        let raised = SIMD3<Float>(next.x,floor(position.y+0.05)+1,next.z)
        if level != nil && raised.y-position.y <= 1.05 && clear(raised) {
          next = raised; verticalSpeed = 0
        }
      }
      if clear(next) { position = next }
      else {
        // Resolve each horizontal contact independently: keep the tangent
        // velocity along walls and reflect only the incoming normal velocity.
        let order = abs(planarVelocity.x) > abs(planarVelocity.y) ? [0,2] : [2,0]
        for axis in order {
          let v = axis == 0 ? planarVelocity.x : planarVelocity.y
          var candidate = position; candidate[axis] += v*dt
          if clear(candidate) { position = candidate; continue }
          var low: Float = 0, high: Float = 1
          for _ in 0..<7 {
            let fraction = (low+high)*0.5
            var probe = position; probe[axis] += v*dt*fraction
            if clear(probe) { low = fraction } else { high = fraction }
          }
          position[axis] += v*dt*max(0,low-0.01)
          impactSpeed = max(impactSpeed,abs(v))
          let rebound: Float = abs(v) > 1.5 ? -0.24*v : 0
          if axis == 0 { planarVelocity.x = rebound; planarVelocity.y *= exp(-0.3*dt) }
          else { planarVelocity.y = rebound; planarVelocity.x *= exp(-0.3*dt) }
        }
        // Off-centre contact turns the body toward its surviving momentum.
        // Without this torque, tyre grip continually drags a glancing car back
        // into the wall and dissipates its tangent velocity every substep.
        let travel=sqrt(planarVelocity.x*planarVelocity.x+planarVelocity.y*planarVelocity.y)
        if travel>2 && speed>0 {
          let desired=atan2(-planarVelocity.x,-planarVelocity.y)
          let angle=atan2(sin(desired-heading),cos(desired-heading))
          let aligned=heading+angle*min(1,dt*4)
          if Self.isClear(at:position,heading:aligned,kind:kind,block:block) && !occupied(position,aligned) { heading=aligned }
        }
      }
      if let floor = support(at:position,heading:heading,block:block), abs(position.y-floor) < 1.05,
        clear([position.x,floor,position.z]) {
        position.y = floor; verticalSpeed = 0; grounded = true
      } else {
        grounded = false
        verticalSpeed = max(-32,verticalSpeed-25*dt)
        let falling = position+[0,verticalSpeed*dt,0]
        if clear(falling) { position = falling }
        else {
          var low: Float = 0, high: Float = 1
          for _ in 0..<8 {
            let f = (low+high)*0.5
            if clear(position+[0,verticalSpeed*dt*f,0]) { low = f } else { high = f }
          }
          position.y += verticalSpeed*dt*low
          impactSpeed = max(impactSpeed,abs(verticalSpeed)*0.5)
          verticalSpeed = 0; grounded = true
        }
      }
      let direction = SIMD2<Float>(-sin(heading),-cos(heading))
      speed = planarVelocity.x*direction.x+planarVelocity.y*direction.y
    }
    heading.formTruncatingRemainder(dividingBy:.pi*2)
  }

  public func exitPosition(block: (BlockPosition) -> Block,
    occupied: (SIMD3<Float>) -> Bool = { _ in false }) -> SIMD3<Float>? {
    guard abs(speed) < 1 else { return nil }
    let sideDistance = kind.halfWidth + PlayerPhysics.radius + 0.7
    let endDistance = kind.halfLength + PlayerPhysics.radius + 0.7
    var offsets: [SIMD3<Float>] = [-sideDistance, sideDistance].flatMap { side in
      [Float(0), 2.8, -2.8].map { [side, 0, $0] }
    } + [[0, 0, endDistance], [0, 0, -endDistance]]
    // Prefer the doors, then search a bounded six-metre neighborhood. Uneven
    // terrain can block every door while perfectly good footing exists nearby.
    for radius: Float in [4, 6, 8, 10, 12] {
      for i in 0..<16 {
        let angle = Float(i) * .pi / 8
        offsets.append([cos(angle)*radius, 0, sin(angle)*radius])
      }
    }
    for local in offsets {
      let offset = rotated(local)
      for dy in [0, 1, -1, 2, -2, 3, -3, 4, -4, -5, -6, -7, -8] {
        // Align feet to actual voxel surfaces, not the car's fractional height
        // during a fall or collision. The old offset-only search could reject
        // every exit even next to an ordinary flat road.
        let candidate = SIMD3<Float>(position.x + offset.x, floor(position.y + 0.05) + Float(dy) + 0.02,
          position.z + offset.z)
        guard !overlapsPlayer(at: candidate), !occupied(candidate) else { continue }
        if Self.safeFooting(at: candidate, block: block) { return candidate }
      }
    }
    return nil
  }

  public static func safeFooting(at candidate: SIMD3<Float>, block: (BlockPosition) -> Block) -> Bool {
    let margin = PlayerPhysics.radius * 0.8
    for dx in [-margin, margin] { for dz in [-margin, margin] {
      guard block(BlockPosition(candidate + [dx, -0.1, dz])).isSolid else { return false }
    } }
    return clearBody(at: candidate, block: block)
  }

  private static func clearBody(at candidate: SIMD3<Float>, block: (BlockPosition) -> Block) -> Bool {
    guard !PlayerPhysics(position: candidate).collides(at: candidate, block: block) else { return false }
    let low = BlockPosition(candidate + [-PlayerPhysics.radius, 0.01, -PlayerPhysics.radius])
    let high = BlockPosition(candidate + [PlayerPhysics.radius, PlayerPhysics.height, PlayerPhysics.radius])
    for x in low.x...high.x { for z in low.z...high.z { for y in low.y...high.y {
      if block(.init(x, y, z)).isLiquid { return false }
    } } }
    return true
  }

  /// A last resort when banks surround a stopped car: climb onto its roof only
  /// with a clear, dry body volume. Never place a passenger in rock or a ceiling.
  public func roofExit(block: (BlockPosition) -> Block,
    occupied: (SIMD3<Float>) -> Bool = { _ in false }) -> SIMD3<Float>? {
    guard abs(speed) < 1 else { return nil }
    let feet = position + [0, kind.height + 0.02, 0]
    return !occupied(feet) && Self.clearBody(at: feet, block: block) ? feet : nil
  }
}

/// Park cars per planet; passengers resume safely beside them after a reload.
public struct VehicleRecord: Codable, Sendable {
  public let id: UInt64
  public let siteID: UInt64
  public let position: [Float]
  public let heading: Float
  public let variant: Int
  public let solar: Bool
  public let kind: VehicleKind?
  public let parkingBrake: Bool?
  public let modelVersion: Int?
  public let traffic: CityTrafficDriver?
  public var crushed:Bool? = nil
  public init(id: UInt64, siteID: UInt64, position: [Float], heading: Float, variant: Int, solar: Bool, kind: VehicleKind? = nil,
    parkingBrake: Bool? = nil, modelVersion: Int? = 1, traffic: CityTrafficDriver? = .parked) {
    self.id = id; self.siteID = siteID; self.position = position
    self.heading = heading; self.variant = variant; self.solar = solar; self.kind = kind
    self.parkingBrake = parkingBrake; self.modelVersion = modelVersion
    self.traffic = traffic
  }
  public var isValid: Bool {
    position.count == 3 && position.allSatisfy { $0.isFinite && abs($0) < 100_000_000 }
      && heading.isFinite && (0..<3).contains(variant) && (traffic?.isValid ?? true)
  }
}
