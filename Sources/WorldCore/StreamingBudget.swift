/// Budget actual publication cost and bytes, rather than mistaking a slow
/// renderer callback for expensive app-side streaming. No 20 Hz timer gate.
public struct StreamingBudget: Sendable {
  public struct Metrics: Sendable, Encodable {
    public let maximumTiles, maximumBytes: Int
    public let reservesCoverage: Bool
    public let coverageReservedAfterTiles: Int
    public let normalMilliseconds, urgentMilliseconds, estimatedTileMilliseconds: Double
    public let estimatedCoverageMilliseconds: Double
    public let frames, processedTiles, peakFrameTiles, peakFrameBytes: Int
    /// A count limit can coincide with the time/byte limits. Ready results may
    /// be too large for the remaining bytes; these counters do not imply fit.
    public let countLimitFrames, countLimitWithReadyFrames: Int
  }
  public let maximumTiles: Int
  public let reservesCoverage: Bool
  private var recoveryFrames = 0
  private var lastPublication = -Double.infinity
  private var estimatedTileSeconds = 0.0007
  private var estimatedCoverageSeconds = 0.0004
  private var frames = 0, processedTiles = 0, peakFrameTiles = 0, peakFrameBytes = 0
  private var countLimitFrames = 0, countLimitWithReadyFrames = 0
  private static let normalFrameSeconds = 0.0022, urgentFrameSeconds = 0.0025
  private static let baselineTileLimit = 4
  public static let maximumFrameBytes = 2 * 1_024 * 1_024
  /// Native preparation holds at most eight results. Cheap ready results may
  /// use that existing capacity; expensive batches still stop at the same
  /// measured time/byte limits instead of consuming a fixed eight-tile quota.
  public init(maximumTiles: Int = 8, reservesCoverage: Bool = true) {
    self.maximumTiles = min(8, max(1, maximumTiles)); self.reservesCoverage = reservesCoverage
  }
  public mutating func reset() { self = .init(maximumTiles: maximumTiles, reservesCoverage: reservesCoverage) }
  public var metrics: Metrics {
    .init(maximumTiles: maximumTiles, maximumBytes: Self.maximumFrameBytes,
      reservesCoverage: reservesCoverage, coverageReservedAfterTiles: Self.baselineTileLimit,
      normalMilliseconds: Self.normalFrameSeconds * 1_000,
      urgentMilliseconds: Self.urgentFrameSeconds * 1_000,
      estimatedTileMilliseconds: estimatedTileSeconds * 1_000,
      estimatedCoverageMilliseconds: reservesCoverage ? estimatedCoverageSeconds * 1_000 : 0,
      frames: frames, processedTiles: processedTiles,
      peakFrameTiles: peakFrameTiles, peakFrameBytes: peakFrameBytes,
      countLimitFrames: countLimitFrames, countLimitWithReadyFrames: countLimitWithReadyFrames)
  }
  /// Account for each streaming callback, including callbacks with no results.
  /// Processed results include failed native-resource/install attempts.
  public mutating func recordFrame(published: Int, bytes: Int, remainingReady: Int) {
    guard published >= 0, bytes >= 0, remainingReady >= 0 else { return }
    frames += 1; processedTiles += published
    peakFrameTiles = max(peakFrameTiles, published); peakFrameBytes = max(peakFrameBytes, bytes)
    if published >= maximumTiles {
      countLimitFrames += 1
      if remainingReady > 0 { countLimitWithReadyFrames += 1 }
    }
  }
  public mutating func beginFrame(interval: Double, time: Double, urgent: Bool) -> Bool {
    let recovered = recoveryFrames == 0
    recoveryFrames = max(0, recoveryFrames - 1)
    return urgent || recovered || time - lastPublication >= 0.035
  }
  public mutating func published(cpuTime: Double, time: Double) {
    lastPublication = time
    recoveryFrames = cpuTime > 0.0025 ? 1 : 0
  }
  public mutating func recordTile(seconds: Double) {
    guard seconds.isFinite, seconds >= 0 else { return }
    estimatedTileSeconds = estimatedTileSeconds * 0.75 + seconds * 0.25
  }
  /// Swapping coverage can retire parents and enable a complete group. Extra
  /// publications beyond the original four-tile limit reserve its measured
  /// cost. The original time/byte checks still govern the first four results;
  /// this headroom check cannot reduce that existing opportunity to make progress.
  public mutating func recordCoverage(seconds: Double) {
    guard seconds.isFinite, seconds >= 0 else { return }
    estimatedCoverageSeconds = max(seconds, estimatedCoverageSeconds * 0.85)
  }
  public func allowsNextTile(elapsed: Double, published: Int, bytes: Int, urgent: Bool) -> Bool {
    if published == 0 { return true } // Even a single large result must progress.
    let coverage = reservesCoverage && published >= Self.baselineTileLimit ? estimatedCoverageSeconds : 0
    return published < maximumTiles && bytes < Self.maximumFrameBytes
      && elapsed + estimatedTileSeconds + coverage
        <= (urgent ? Self.urgentFrameSeconds : Self.normalFrameSeconds)
  }
  public static func allowsSecondTile(elapsed: Double, bytes: Int) -> Bool {
    elapsed < 0.00075 && bytes <= 512 * 1_024
  }
}
