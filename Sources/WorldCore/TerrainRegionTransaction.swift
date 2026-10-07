import Foundation

public struct TerrainRegionTransactionMetrics: Sendable, Encodable {
  public var running = false, ready = false
  public var inputBytes = 0, readyBytes = 0, publicationBytes = 0
  public var admitted = 0, completed = 0, discarded = 0, failed = 0
  public var rejections: [String: Int] = [:]
  public var preparationLatency = DurationTiming().snapshot
  public var nativeLatency = DurationTiming().snapshot
}

/// One bounded CPU → native → ready transaction. Native values never leave
/// MainActor. Cancellation keeps the slot occupied until every await returns;
/// the caller retains visible fallback coverage throughout this operation.
@MainActor public final class TerrainRegionTransaction<Resource> {
  public struct Ready {
    public let candidate: TerrainDryRegion.Candidate
    public let resource: Resource
  }
  public typealias Builder = @Sendable (TerrainDryRegion.Request) async -> TerrainDryRegion.Result
  private let build: Builder
  private let prepare: @MainActor (PreparedTerrainTile) async throws -> Resource
  private let discard: @MainActor (Resource) -> Void
  private let valid: @MainActor (TerrainDryRegion.Candidate) -> Bool
  private var task: Task<Void, Never>?
  private var current: UUID?
  private var value: Ready?
  private var statistics = TerrainRegionTransactionMetrics()
  private var preparationTiming = DurationTiming(), nativeTiming = DurationTiming()
  public init(build: @escaping Builder,
    prepare: @escaping @MainActor (PreparedTerrainTile) async throws -> Resource,
    discard: @escaping @MainActor (Resource) -> Void,
    valid: @escaping @MainActor (TerrainDryRegion.Candidate) -> Bool) {
    self.build = build; self.prepare = prepare; self.discard = discard; self.valid = valid
  }
  public var hasCapacity: Bool { task == nil && value == nil }
  public var metrics: TerrainRegionTransactionMetrics {
    var result = statistics
    result.preparationLatency = preparationTiming.snapshot; result.nativeLatency = nativeTiming.snapshot
    return result
  }
  @discardableResult public func admit(_ request: TerrainDryRegion.Request) -> Bool {
    guard hasCapacity, request.byteCount <= TerrainDryRegion.maximumInputBytes else { return false }
    current = request.token; statistics.admitted += 1; statistics.running = true
    statistics.inputBytes = request.byteCount
    task = Task { [weak self, build] in
      let began = ProcessInfo.processInfo.systemUptime
      let result = await build(request)
      guard let self else { return }
      preparationTiming.record(seconds: ProcessInfo.processInfo.systemUptime-began)
      defer {
        task = nil; statistics.running = false; statistics.inputBytes = 0
        if value == nil { statistics.publicationBytes = 0 }
      }
      guard current == request.token, !Task.isCancelled else { statistics.discarded += 1; return }
      guard result.status == .ready, let candidate = result.candidate else {
        statistics.rejections[result.status.rawValue, default: 0] += 1; return
      }
      guard candidate.token == request.token, candidate.source == request.source,
        candidate.revision == request.revision, candidate.byteCount <= TerrainDryRegion.maximumOutputBytes,
        valid(candidate) else { statistics.discarded += 1; return }
      statistics.publicationBytes = candidate.prepared.publicationByteCount(reuseMeshes: true)
        + candidate.ground.byteCount + candidate.water.byteCount
      let nativeBegan = ProcessInfo.processInfo.systemUptime
      do {
        let resource = try await prepare(candidate.prepared)
        nativeTiming.record(seconds: ProcessInfo.processInfo.systemUptime-nativeBegan)
        guard current == request.token, !Task.isCancelled, valid(candidate) else {
          discard(resource); statistics.discarded += 1; return
        }
        value = .init(candidate: candidate, resource: resource)
        statistics.ready = true; statistics.readyBytes = candidate.byteCount
        statistics.completed += 1
      } catch {
        nativeTiming.record(seconds: ProcessInfo.processInfo.systemUptime-nativeBegan)
        statistics.failed += 1
      }
    }
    return true
  }
  /// No await occurs between this final validation and the caller's scene swap.
  public func takeReady() -> Ready? {
    guard let result = value else { return nil }
    value = nil; statistics.ready = false; statistics.readyBytes = 0; statistics.publicationBytes = 0
    guard current == result.candidate.token, valid(result.candidate) else {
      discard(result.resource); statistics.discarded += 1; return nil
    }
    return result
  }
  public func invalidate() {
    current = nil; task?.cancel()
    if let value { discard(value.resource); statistics.discarded += 1 }
    value = nil; statistics.ready = false; statistics.readyBytes = 0
    if task == nil { statistics.publicationBytes = 0 }
  }
}
