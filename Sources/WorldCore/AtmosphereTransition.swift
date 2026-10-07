import Foundation

/// Two coordinate charts overlap during flight. Their translation is fixed at
/// the crossing, so native head motion and steering remain continuous.
public struct AtmosphereTransition: Sendable {
  public let surfaceAnchor, spaceAnchor: SIMD3<Float>
  public let arriving: Bool
  public private(set) var elapsed: Float = 0
  public let duration: Float
  public init(surface:SIMD3<Float>,space:SIMD3<Float>,arriving:Bool,duration:Float=5) {
    surfaceAnchor=surface; spaceAnchor=space; self.arriving=arriving; self.duration=max(0.1,duration)
  }
  public var fraction:Float { smoothstep(0,duration,elapsed) }
  public var surfaceOpacity:Float { arriving ? fraction:1-fraction }
  public var finished:Bool { elapsed>=duration }
  public mutating func advance(_ seconds:Float,ready:Bool=true) { if ready { elapsed=min(duration,elapsed+max(0,seconds)) } }
  public func surfacePoint(_ point:SIMD3<Float>) -> SIMD3<Float> { surfaceAnchor+(point-spaceAnchor) }
  public func spacePoint(_ point:SIMD3<Float>) -> SIMD3<Float> { spaceAnchor+(point-surfaceAnchor) }
}
