public enum DrawDistance {
  public static let range = 4...128
  public static let standard = 48
  public static let detailedRadius = 10
  public static let detailRange = 6...16
  public static func clamp(_ chunks: Int) -> Int {
    min(range.upperBound, max(range.lowerBound, chunks))
  }
  public static func clampDetail(_ chunks: Int) -> Int {
    min(detailRange.upperBound, max(detailRange.lowerBound, chunks))
  }
}

public enum ChunkDetail: Int, Sendable {
  case full = 1
  case reduced = 2
  case distant = 4
  public var sampleStride: Int { rawValue }
}

/// A circular horizon bounds full-detail memory independently of draw distance.
public struct ChunkStreamingPlan: Sendable {
  public let center: ChunkCoordinate
  public let radius: Int
  public let chunks: [ChunkCoordinate: ChunkDetail]
  public init(center: ChunkCoordinate, radius: Int) {
    self.center = center
    self.radius = DrawDistance.clamp(radius)
    var chunks: [ChunkCoordinate: ChunkDetail] = [:]
    for x in -self.radius...self.radius {
      for z in -self.radius...self.radius {
        let distance = x * x + z * z
        guard distance <= self.radius * self.radius else { continue }
        let detail: ChunkDetail =
          distance <= DrawDistance.detailedRadius * DrawDistance.detailedRadius
          ? .full : (distance <= 12 * 12 ? .reduced : .distant)
        chunks[.init(center.x + x, center.z + z)] = detail
      }
    }
    self.chunks = chunks
  }
}
