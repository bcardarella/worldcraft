import Foundation
import simd

/// Schedules only analytical, non-shadow-casting water deformation. It never
/// changes draw visibility, authoritative disturbances, physics or game time.
/// Use complete displaced geometry bounds, not a batch origin or tile centre.
public struct WaterAnimationSchedule: Sendable {
  public struct Sample: Equatable, Sendable {
    public let elapsed: Double
    public let disturbances: UInt64
    public init(elapsed: Double, disturbances: UInt64 = 0) { self.elapsed = elapsed; self.disturbances = disturbances }
  }
  public struct View: Sendable {
    public let eye, forward: SIMD3<Float>
    public init?(eye: SIMD3<Float>, forward: SIMD3<Float>) {
      guard Self.finite(eye), Self.finite(forward) else { return nil }
      let length = simd_length(forward)
      guard length.isFinite && length > 0.0001 else { return nil }
      self.eye = eye; self.forward = forward / length
    }
    fileprivate static func finite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }
  }
  public struct Bounds: Sendable {
    public let minimum, maximum: SIMD3<Float>
    public init(minimum: SIMD3<Float>, maximum: SIMD3<Float>) { self.minimum = minimum; self.maximum = maximum }
    public var isValid: Bool {
      View.finite(minimum) && View.finite(maximum)
        && minimum.x <= maximum.x && minimum.y <= maximum.y && minimum.z <= maximum.z
    }
  }
  public struct Candidate: Sendable {
    public let id: UUID
    public let bounds: Bounds
    public let vertices: Int
    public init(id: UUID, bounds: Bounds, vertices: Int) {
      precondition(vertices >= 0)
      self.id = id; self.bounds = bounds; self.vertices = vertices
    }
  }
  public struct Plan: Sendable {
    public let selected: Set<UUID>
    /// Keep retrying these even inside the normal 30 Hz interval until actual
    /// encoding/publication acknowledges them. A busy GPU never consumes one.
    public let urgent: Set<UUID>
    public let sample: Sample
    fileprivate let revisions: [UUID: UInt64]
  }
  public struct Metrics: Sendable, Encodable {
    public fileprivate(set) var enabled = false
    public fileprivate(set) var candidateBatches = 0, candidateVertices = 0
    public fileprivate(set) var eligibleBatches = 0, eligibleVertices = 0
    public fileprivate(set) var skippedBatches = 0, skippedVertices = 0, urgentBatches = 0, trackedBatches = 0
    public fileprivate(set) var catchupBatchesTotal = 0, selectionsTotal = 0
  }
  private struct State: Sendable {
    var lastRequired: Double
    var suspended: Bool
    var skipped: Bool
    var revision: UInt64
    var lastSample: Sample?
  }
  private var states: [UUID: State] = [:]
  private var nextRevision: UInt64 = 0
  private var previousView: View?
  private var previousTime: Double?
  public private(set) var metrics = Metrics()
  /// Blocks: preserve a 32-metre sphere around the viewer. Geometry bounds
  /// already include waves; an extra two metres covers stereo eye separation
  /// and small motion. This is intentionally much wider than a display frustum.
  public static let nearDistance: Float = 64
  public static let padding: Float = 4
  public static let retentionSeconds = 0.5
  public init() {}

  public mutating func reset() { states.removeAll(); previousView = nil; previousTime = nil; metrics = .init() }

  /// False only when the *whole* padded bounding sphere lies more than 120°
  /// away from forward. Invalid/near/intersecting bounds always stay active.
  /// This is not an occlusion test, and must not cull shadow-casting vegetation.
  public static func mayAffectView(_ bounds: Bounds, view: View) -> Bool {
    guard bounds.isValid else { return true }
    let center = bounds.minimum * 0.5 + bounds.maximum * 0.5
    let extent = (bounds.maximum - bounds.minimum) * 0.5 + SIMD3<Float>(repeating: padding)
    let offset = center - view.eye, radius = simd_length(extent), distance = simd_length(offset)
    guard radius.isFinite, distance.isFinite else { return true }
    if distance - radius <= nearDistance { return true }
    // For every point p in the sphere, dot(p,f) <= dot(c,f)+r and |p|<=d+r.
    // This sufficient (not necessary) condition places all of it in the rear cone.
    return simd_dot(offset, view.forward) + radius >= -0.5 * (distance + radius)
  }

  public mutating func select(_ candidates: [Candidate], view: View?, now: Double, enabled: Bool,
    sample: Sample? = nil) -> Plan {
    let sample = sample ?? .init(elapsed: now)
    metrics.enabled = enabled; metrics.selectionsTotal += 1
    metrics.candidateBatches = candidates.count; metrics.candidateVertices = candidates.reduce(0) { $0 + $1.vertices }
    var selected = Set<UUID>(), urgent = Set<UUID>(), vertices = 0
    var revisions: [UUID: UInt64] = [:]
    let live = Set(candidates.map(\.id))
    precondition(live.count == candidates.count, "Duplicate water batch identity")
    if !enabled {
      // Exact baseline policy: no catch-up submissions or retained per-batch state.
      states.removeAll(keepingCapacity: true); previousView = nil; previousTime = nil
      selected = live; vertices = metrics.candidateVertices
    } else {
      states = states.filter { live.contains($0.key) }
      let validTime = now.isFinite
      let discontinuity = !validTime || (previousTime.map { now < $0 || now - $0 > 0.25 } ?? true)
      let jump = previousView.map { old in
        guard let view else { return true }
        return simd_distance_squared(old.eye, view.eye) > 16 * 16
          || simd_dot(old.forward, view.forward) < 0.8660254 // 30° between observations
      } ?? true
      for candidate in candidates {
        if states[candidate.id] == nil {
          nextRevision &+= 1
          states[candidate.id] = .init(lastRequired: validTime ? now : 0, suspended: true, skipped: false, revision: nextRevision, lastSample: nil)
        }
        var state = states[candidate.id]!
        let needed = discontinuity || jump || (view.map { Self.mayAffectView(candidate.bounds, view: $0) } ?? true)
        if needed && validTime { state.lastRequired = now }
        if needed || now - state.lastRequired <= Self.retentionSeconds {
          state.skipped = false
          if state.lastSample == sample { state.suspended = false }
          selected.insert(candidate.id); vertices += candidate.vertices
          if state.suspended { urgent.insert(candidate.id) }
          revisions[candidate.id] = state.revision
        } else {
          if !state.skipped { nextRevision &+= 1; state.revision = nextRevision }
          state.suspended = true; state.skipped = true
        }
        states[candidate.id] = state
      }
      previousView = view; previousTime = validTime ? now : nil
    }
    metrics.eligibleBatches = selected.count; metrics.eligibleVertices = vertices
    metrics.skippedBatches = candidates.count - selected.count; metrics.skippedVertices = metrics.candidateVertices - vertices
    metrics.urgentBatches = urgent.count
    metrics.trackedBatches = states.count
    return .init(selected: selected, urgent: urgent, sample: sample, revisions: revisions)
  }

  public func allowsPublication(_ plan: Plan, id: UUID) -> Bool {
    guard plan.selected.contains(id) else { return false }
    guard let revision = plan.revisions[id] else { return !metrics.enabled }
    return states[id]?.revision == revision && states[id]?.skipped == false
  }

  /// Called only for batches actually encoded (GPU) or installed (CPU fallback).
  public mutating func didSubmit(_ plan: Plan, ids: Set<UUID>) {
    for id in ids where allowsPublication(plan, id: id) {
      if states[id]?.suspended == true { metrics.catchupBatchesTotal += 1 }
      states[id]?.suspended = false; states[id]?.lastSample = plan.sample
    }
  }
}

extension WaterMeshBatch {
  /// Same parts used by native draw ownership, already expanded for waves.
  /// Cache on coverage changes rather than scanning vertices every frame.
  public func animationBounds(for parts: [Part]) -> WaterAnimationSchedule.Bounds? {
    guard let first = parts.first else { return nil }
    var low = first.minimum, high = first.maximum
    for part in parts.dropFirst() {
      low = simd_min(low, part.minimum); high = simd_max(high, part.maximum)
    }
    return .init(minimum: low + key.origin, maximum: high + key.origin)
  }
}
