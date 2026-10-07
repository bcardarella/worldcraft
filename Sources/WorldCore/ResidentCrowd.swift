import Foundation

/// Bounded local steering on the simulation actor. Social/AI choices supply a
/// destination; passing, personal space and collision safety remain immediate.
public enum ResidentCrowd {
  public struct Neighbor: Sendable {
    public let id: UInt64
    public let position, velocity: SIMD3<Float>
    public init(id: UInt64, position: SIMD3<Float>, velocity: SIMD3<Float> = .zero) {
      self.id = id; self.position = position; self.velocity = velocity
    }
  }
  public static let separation: Float = ResidentNavigation.radius * 2 + 0.08
  private static func length(_ p: SIMD3<Float>) -> Float { (p.x*p.x + p.y*p.y + p.z*p.z).squareRoot() }

  public static func approachOffset(index: Int, radius: Float = 2.8) -> SIMD3<Float> {
    let angle = Float(index % 12) * .pi / 6
    let ring = radius + Float((index / 12) % 3) * 1.25
    return [cos(angle)*ring, 0, sin(angle)*ring]
  }

  public static func step(id: UInt64, position: SIMD3<Float>, target: SIMD3<Float>, speed: Float,
    seconds: Float, neighbors: [Neighbor], navigable: (SIMD3<Float>) -> SIMD3<Float>?) -> SIMD3<Float>? {
    let dt = min(0.2, max(0, seconds))
    guard dt > 0 else { return nil }
    let nearby = neighbors.filter { $0.id != id && length($0.position-position) < 6 }
    var direction = target-position
    let remaining = length(direction)
    var escape = SIMD3<Float>.zero
    for other in nearby where abs(other.position.y-position.y) < ResidentNavigation.height {
      var delta = position-other.position; delta.y = 0
      let distance = length(delta)
      if distance < separation {
        if distance < 0.001 {
          // Antisymmetric even when old saves place two actors at exactly one point.
          let sign: Float = id < other.id ? 1 : -1
          delta = [sign, 0, 0]
        } else { delta /= distance }
        escape += delta * (separation-distance)
      }
    }
    if length(escape) > 0.01 { direction += escape * 3 }
    let magnitude = length(direction)
    guard magnitude > 0.001 else { return nil }
    direction /= magnitude
    let stride = min(speed * dt, max(remaining, length(escape)))
    guard stride > 0 else { return nil }
    // Everyone keeps right relative to their own travel direction. Opposing
    // walkers therefore pick opposite sides instead of mirroring each other.
    let angles: [Float] = [0, .pi/6, -.pi/6, .pi/3, -.pi/3, .pi/2, -.pi/2, .pi*0.75, -.pi*0.75, .pi]
    var best: SIMD3<Float>?, bestScore = Float.infinity
    for (index, angle) in angles.enumerated() {
      let c = cos(angle), s = sin(angle)
      let travel = SIMD3<Float>(c*direction.x-s*direction.z, direction.y, s*direction.x+c*direction.z)
      let raw = position + travel * stride
      guard let candidate = navigable(raw) else { continue }
      var penalty: Float = 0, safe = true
      var oldOverlap: Float = 0, newOverlap: Float = 0
      for other in nearby where abs(other.position.y-candidate.y) < ResidentNavigation.height {
        let start = SIMD2<Float>(position.x-other.position.x, position.z-other.position.z)
        let end = SIMD2<Float>(candidate.x-other.position.x, candidate.z-other.position.z)
        let d0 = (start.x*start.x + start.y*start.y).squareRoot()
        let d1 = (end.x*end.x + end.y*end.y).squareRoot()
        // Never deepen an existing overlap, including an old saved clump.
        if d0 < separation {
          oldOverlap += (separation-d0)*(separation-d0)
          newOverlap += max(0,separation-d1)*max(0,separation-d1)
        } else {
          let delta = end-start, squared = delta.x*delta.x + delta.y*delta.y
          let t = squared > 0 ? min(1, max(0, -(start.x*delta.x + start.y*delta.y)/squared)) : 0
          let closest = start+delta*t
          if closest.x*closest.x + closest.y*closest.y < separation*separation { safe = false; break }
        }
        // Anticipate moving neighbors, but always validate the actual swept step.
        let future = candidate + travel*0.55*speed - (other.position + other.velocity*0.55)
        let distance = (future.x*future.x + future.z*future.z).squareRoot()
        penalty += max(0, 1.8-distance)*0.7 + max(0, 1.5-d1)*0.4
      }
      guard safe, oldOverlap == 0 || newOverlap < oldOverlap-0.00001 else { continue }
      let progress = length(target-candidate)
      let score = progress + penalty + newOverlap*8 + abs(angle)*0.06 + (index > 0 && index % 2 == 0 ? 0.025 : 0)
      if score < bestScore { bestScore = score; best = candidate }
    }
    return best
  }
}

/// Exclusive, first-arrival passage reservations. Geometry and ownership are
/// value state on SimulationActor; a late network decision cannot grant access.
public struct ResidentPassage: Sendable {
  public let id: UInt64
  public let low, high: SIMD3<Float>
  public let axis: Int
  public init(id:UInt64,low:SIMD3<Float>,high:SIMD3<Float>,axis:Int) {
    self.id=id;self.low=low;self.high=high;self.axis=axis
  }
  public func contains(_ p:SIMD3<Float>, margin:Float=0) -> Bool {
    p.x>=low.x-margin && p.x<=high.x+margin && p.z>=low.z-margin && p.z<=high.z+margin
      && p.y>=low.y-0.5 && p.y<=high.y+0.5
  }
  public func distanceSquared(to p:SIMD3<Float>)->Float {
    var distance:Float=0
    for axis in 0..<3 {let d=max(low[axis]-p[axis],0,p[axis]-high[axis]);distance+=d*d}
    return distance
  }
  public func waitingPoint(for position:SIMD3<Float>, index:Int) -> SIMD3<Float> {
    var p=position
    let middle=(low[axis]+high[axis])/2
    p[axis] = position[axis]<middle ? low[axis]-2.5-Float(index)*1.6 : high[axis]+2.5+Float(index)*1.6
    // Stand beside the entrance so a person leaving can clear the doorway.
    let cross=axis == 0 ? 2:0
    p[cross]=(low[cross]+high[cross])/2 + (position[axis]<middle ? -1.65:1.65)
    return p
  }
}
public struct ResidentPassageQueue: Sendable {
  public struct Request: Sendable {
    public let person:UInt64, passage:UInt64
    public let inside:Bool
    public init(person:UInt64,passage:UInt64,inside:Bool) {self.person=person;self.passage=passage;self.inside=inside}
  }
  private struct Ticket: Sendable { let since:Double;var inside:Bool }
  private var tickets:[UInt64:[UInt64:Ticket]] = [:]
  private var owners:[UInt64:UInt64] = [:]
  private var leases:[UInt64:(owner:UInt64,since:Double)] = [:]
  public init() {}
  public mutating func update(_ requests:[Request],time:Double) {
    let active=Set(requests.map(\.passage))
    tickets=tickets.filter { active.contains($0.key) };owners=owners.filter {active.contains($0.key)}
    leases=leases.filter {active.contains($0.key)}
    for key in active {
      let incoming=requests.filter {$0.passage==key}, ids=Set(incoming.map(\.person))
      var queue=(tickets[key] ?? [:]).filter {ids.contains($0.key)}
      for request in incoming {queue[request.person] = .init(since:queue[request.person]?.since ?? time,inside:request.inside)}
      // A walker that never reaches the entrance cannot reserve it forever.
      if queue.count>1,let lease=leases[key],time-lease.since>18,let ticket=queue[lease.owner],!ticket.inside {
        queue[lease.owner] = .init(since:time,inside:false);owners[key]=nil
      }
      // A player or an already-entered walker clears before anyone enters.
      let occupied=queue.filter {$0.value.inside}.keys.sorted()
      if let inside=occupied.first {owners[key]=inside}
      else if let owner=owners[key],queue[owner] != nil {} // retain through approach and crossing
      else { owners[key]=queue.keys.min {queue[$0]!.since == queue[$1]!.since ? $0<$1:queue[$0]!.since<queue[$1]!.since} }
      if let owner=owners[key],leases[key]?.owner != owner {leases[key]=(owner,time)}
      tickets[key]=queue
    }
  }
  public func permits(_ person:UInt64,passage:UInt64) -> Bool { owners[passage] == person }
  public func waitingIndex(_ person:UInt64,passage:UInt64) -> Int {
    let queue=tickets[passage] ?? [:]
    return queue.keys.filter {$0 != owners[passage]}.sorted {queue[$0]!.since == queue[$1]!.since ? $0<$1:queue[$0]!.since<queue[$1]!.since}.firstIndex(of:person) ?? 0
  }
}
