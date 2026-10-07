import Foundation

public enum LocomotionInput {
  public static let maximumLookPitch: Float = .pi * 70 / 180
  public static func clampLookPitch(_ pitch: Float) -> Float {
    min(maximumLookPitch, max(-maximumLookPitch, pitch))
  }
  public static func clampSpacePitch(_ pitch: Float) -> Float {
    min(.pi / 2, max(-.pi / 2, pitch))
  }
  public static func lookPitchDelta(axis value: Float, speed: Float, deltaTime: Float) -> Float {
    axis(value) * max(0, deltaTime) * speed * .pi / 180
  }
  public static func axis(_ value: Float, deadzone: Float = 0.14) -> Float {
    let v = min(1, max(-1, value))
    guard abs(v) > deadzone else { return 0 }
    return (v - (v > 0 ? deadzone : -deadzone)) / (1 - deadzone)
  }
  public static func movement(_ value: SIMD2<Float>, deadzone: Float = 0.14) -> SIMD2<Float> {
    let magnitude = sqrt(value.x * value.x + value.y * value.y)
    guard magnitude > deadzone else { return .zero }
    return value / magnitude * min(1, (magnitude - deadzone) / (1 - deadzone))
  }
  public static func worldMovement(_ stick: SIMD2<Float>, heading: Float) -> SIMD3<Float> {
    let c = cos(heading)
    let s = sin(heading)
    return [c * stick.x - s * stick.y, 0, -s * stick.x - c * stick.y]
  }
  /// Local thrusters follow the body's full steering pitch. Head looking can be
  /// composed by the caller, but does not redirect controller steering by default.
  public static func spaceMovement(_ stick: SIMD2<Float>, ascend: Float, heading: Float, pitch: Float) -> SIMD3<Float> {
    let cp = cos(pitch), sp = sin(pitch), c = cos(heading), s = sin(heading)
    let local = SIMD3<Float>(stick.x, ascend * cp + stick.y * sp, ascend * sp - stick.y * cp)
    return [local.x * c + local.z * s, local.y, -local.x * s + local.z * c]
  }
}

/// Direct six-direction movement: releasing input hovers without drift or gravity.
public enum CreativeFlight {
  public static let speed: Float = WorldScale.blocks(10.8)
  public static func velocity(movement: SIMD3<Float>, sprint: Bool) -> SIMD3<Float> {
    let length = sqrt(movement.x * movement.x + movement.y * movement.y + movement.z * movement.z)
    return movement / max(1, length) * speed * (sprint ? 2 : 1)
  }
}

public struct DoubleJumpGesture: Sendable {
  private var lastPress: Double?
  public init() {}
  public mutating func reset() { lastPress = nil }
  public mutating func press(at time: Double) -> Bool {
    if let lastPress, time >= lastPress, time - lastPress <= 0.34 {
      self.lastPress = nil
      return true
    }
    lastPress = time
    return false
  }
}
