import Foundation

/// Explicit launch-only comparisons. No saved setting, terrain quality or
/// simulation clock is changed. Report these flags with every device capture.
public struct RenderDiagnostics: Sendable, Encodable, Equatable {
  public static let current = RenderDiagnostics(arguments: ProcessInfo.processInfo.arguments)
  public let freezeWaterAnimation, freezeWindAnimation, disableFireParticles: Bool
  public let disableLocalLights, waterPBR, cullRearWaterAnimation: Bool
  public init(arguments: [String] = []) {
    let args = Set(arguments)
    freezeWaterAnimation = args.contains("--freeze-water-animation")
    freezeWindAnimation = args.contains("--freeze-wind-animation")
    disableFireParticles = args.contains("--disable-fire-particles")
    disableLocalLights = args.contains("--disable-local-lights")
    waterPBR = args.contains("--water-pbr")
    // A native fast-turn/stereo comparison is still required before rollout.
    cullRearWaterAnimation = args.contains("--cull-rear-water-animation")
  }
}
