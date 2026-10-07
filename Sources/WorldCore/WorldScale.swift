/// Simulation and saves stay on the integer voxel grid. Tracking and RealityKit
/// use metres; convert exactly once at their boundary.
public enum WorldScale {
  public static let metresPerBlock: Float = 0.5
  public static func blocks(_ metres: Float) -> Float { metres / metresPerBlock }
  public static func metres(_ blocks: Float) -> Float { blocks * metresPerBlock }
}
